import Foundation
import RocaCore

public protocol CodexAgentClient: Sendable {
    func prepare() async throws
    func run(_ request: AgentRunRequest, providerID: ProviderID) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func discoverProjects(matching query: ProjectDiscoveryQuery, providerID: ProviderID) async throws -> [ProjectDiscoveryCandidate]
    func cancel(_ runID: AgentRunID) async
}

public typealias CodexAppServerDiagnosticSink = @Sendable (AssistantDiagnosticEvent) async -> Void

public struct CodexAppServerConfiguration: Sendable {
    public var executableURL: URL?
    public var arguments: [String]
    public var projectDiscoveryTimeoutSeconds: TimeInterval
    public var applicationURL: URL

    public init(
        executableURL: URL? = nil,
        arguments: [String] = ["app-server"],
        projectDiscoveryTimeoutSeconds: TimeInterval = 15,
        applicationURL: URL = URL(fileURLWithPath: "/Applications/Codex.app")
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.projectDiscoveryTimeoutSeconds = projectDiscoveryTimeoutSeconds
        self.applicationURL = applicationURL
    }
}

public struct CodexAppServerClient: CodexAgentClient {
    private let configuration: CodexAppServerConfiguration
    private let isExecutableFile: @Sendable (String) -> Bool
    private let approvalDecisioner: any AgentApprovalDecisioning
    private let diagnosticSink: CodexAppServerDiagnosticSink
    private let sessions = CodexAppServerRunRegistry()

    public init(
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration(),
        approvalDecisioner: any AgentApprovalDecisioning = DenyingAgentApprovalDecisioner(),
        diagnosticSink: @escaping CodexAppServerDiagnosticSink = { _ in },
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.configuration = configuration
        self.approvalDecisioner = approvalDecisioner
        self.diagnosticSink = diagnosticSink
        self.isExecutableFile = isExecutableFile
    }

    public func prepare() async throws {
        let status = setupStatus()
        guard status.isReady else {
            throw RocaError.agentProviderSetupRequired(status)
        }
    }

    public func setupStatus(
        providerID: ProviderID = BuiltInProviderIDs.codexAgent,
        displayName: String = "Codex"
    ) -> AgentProviderSetupStatus {
        if resolvedExecutableURL() != nil {
            return AgentProviderSetupStatus(
                providerID: providerID,
                displayName: displayName,
                state: .ready,
                summary: "Codex is ready.",
                guidance: ""
            )
        }

        let appPath = configuration.applicationURL.path
        let appExists = FileManager.default.fileExists(atPath: appPath)
        if appExists {
            return AgentProviderSetupStatus(
                providerID: providerID,
                displayName: displayName,
                state: .appDetectedNeedsRuntime,
                summary: "Codex app is installed, but Roca could not find the Codex command-line runtime.",
                guidance: "Open Codex once or install the Codex CLI, then refresh provider setup.",
                detectedApplicationPath: appPath
            )
        }

        return AgentProviderSetupStatus(
            providerID: providerID,
            displayName: displayName,
            state: .runtimeMissing,
            summary: "Codex is not installed for Roca.",
            guidance: "Install Codex, then refresh provider setup.",
            installCommand: "Install Codex from OpenAI.",
            detectedApplicationPath: nil
        )
    }

    public func run(_ request: AgentRunRequest, providerID: ProviderID) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard let executableURL = resolvedExecutableURL() else {
            throw RocaError.agentProviderSetupRequired(setupStatus(providerID: providerID, displayName: "Codex"))
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let session = CodexAppServerSession(executableURL: executableURL, arguments: configuration.arguments)
                do {
                    try session.start()
                    await sessions.insert(session, for: request.runID)
                    continuation.yield(.started(runID: request.runID, providerID: providerID))
                    try session.send(.request(id: 1, method: "initialize", params: CodexAppServerRequestBuilder.initializeParams()))

                    var accumulatedText = ""
                    var threadID: String?
                    var didComplete = false

                    for try await line in session.outputLines() {
                        try Task.checkCancellation()
                        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }

                        let message = try CodexRPCMessage.decode(line)
                        if let error = message.error {
                            throw RocaError.providerUnavailable(
                                ProviderID(rawValue: "\(providerID.rawValue): \(error.message)")
                            )
                        }

                        if let id = message.id?.intValue {
                            switch id {
                            case 1:
                                try session.send(.notification(method: "initialized"))
                                try session.send(
                                    .request(
                                        id: 2,
                                        method: "thread/start",
                                        params: CodexAppServerRequestBuilder.threadStartParams(for: request)
                                    )
                                )
                            case 2:
                                let resolvedThreadID = try Self.threadID(from: message)
                                threadID = resolvedThreadID
                                try session.send(
                                    .request(
                                        id: 3,
                                        method: "turn/start",
                                        params: CodexAppServerRequestBuilder.turnStartParams(for: request, threadID: resolvedThreadID)
                                    )
                                )
                            case 3:
                                continuation.yield(.status("Codex turn started."))
                            default:
                                break
                            }
                        }

                        if let method = message.method {
                            try await Self.handle(
                                message,
                                method: method,
                                request: request,
                                providerID: providerID,
                                session: session,
                                approvalDecisioner: approvalDecisioner,
                                threadID: threadID,
                                accumulatedText: &accumulatedText,
                                didComplete: &didComplete,
                                continuation: continuation
                            )
                            if didComplete {
                                break
                            }
                        }
                    }

                    guard didComplete else {
                        throw RocaError.providerUnavailable(
                            ProviderID(rawValue: "\(providerID.rawValue): app-server exited before completion")
                        )
                    }
                    session.terminate()
                    await sessions.remove(request.runID)
                } catch is CancellationError {
                    session.terminate()
                    await sessions.remove(request.runID)
                    continuation.yield(.cancelled(runID: request.runID))
                    continuation.finish(throwing: RocaError.cancelled)
                } catch {
                    session.terminate()
                    await sessions.remove(request.runID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func cancel(_ runID: AgentRunID) async {
        await sessions.cancel(runID)
    }

    public func discoverProjects(
        matching query: ProjectDiscoveryQuery,
        providerID: ProviderID
    ) async throws -> [ProjectDiscoveryCandidate] {
        guard let executableURL = resolvedExecutableURL() else {
            throw RocaError.agentProviderSetupRequired(setupStatus(providerID: providerID, displayName: "Codex"))
        }

        let session = CodexAppServerSession(executableURL: executableURL, arguments: configuration.arguments)
        let discoveryID = UUID().uuidString
        let startedAt = Date()
        emitDiscoveryDiagnostic(
            "started",
            providerID: providerID,
            discoveryID: discoveryID,
            startedAt: startedAt,
            metadata: [
                "executable": Self.redactedPath(executableURL.path),
                "timeoutMs": String(Int(max(0.1, configuration.projectDiscoveryTimeoutSeconds) * 1_000)),
                "projectNamePresent": String(!query.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                "promptLength": String(query.prompt.count)
            ]
        )
        try session.start()
        let timeoutSeconds = max(0.1, configuration.projectDiscoveryTimeoutSeconds)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let timeoutTask = Task { [session] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            session.terminate()
        }
        defer {
            timeoutTask.cancel()
            session.terminate()
        }

        try session.send(.request(id: 1, method: "initialize", params: CodexAppServerRequestBuilder.initializeParams()))
        var pending = Set<Int>()
        var requestsByID: [Int: CodexProjectDiscoveryRequest] = [:]
        var requestStartedAt: [Int: Date] = [:]
        var discoveredThreads: [CodexDiscoveredThread] = []
        var didQueueRequests = false

        do {
            for try await line in session.outputLines() {
                try Task.checkCancellation()
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                emitDiscoveryDiagnostic(
                    "lineReceived",
                    providerID: providerID,
                    discoveryID: discoveryID,
                    startedAt: startedAt,
                    metadata: ["lineBytes": String(line.utf8.count)]
                )
                let message = try CodexRPCMessage.decode(line)
                if let error = message.error {
                    throw RocaError.providerUnavailable(
                        ProviderID(rawValue: "\(providerID.rawValue): \(error.message)")
                    )
                }

                if message.id?.intValue == 1, !didQueueRequests {
                    didQueueRequests = true
                    try session.send(.notification(method: "initialized"))
                    emitDiscoveryDiagnostic(
                        "initialized",
                        providerID: providerID,
                        discoveryID: discoveryID,
                        startedAt: startedAt
                    )
                    for request in CodexProjectDiscoveryRequest.requests(for: query) {
                        pending.insert(request.id)
                        requestsByID[request.id] = request
                        requestStartedAt[request.id] = Date()
                        try session.send(.request(id: request.id, method: request.method, params: request.params))
                        emitDiscoveryDiagnostic(
                            "requestQueued",
                            providerID: providerID,
                            discoveryID: discoveryID,
                            startedAt: startedAt,
                            metadata: request.diagnosticMetadata.merging([
                                "pendingIDs": Self.joinedIDs(pending)
                            ]) { current, _ in current }
                        )
                    }
                    if pending.isEmpty {
                        break
                    }
                    continue
                }

                guard let id = message.id?.intValue, pending.remove(id) != nil else {
                    continue
                }
                let responseThreads = CodexProjectDiscoveryRequest.threads(from: message.result)
                discoveredThreads.append(contentsOf: responseThreads)
                let candidates = CodexProjectDiscoveryRanker.candidates(
                    from: discoveredThreads,
                    query: query,
                    providerID: providerID
                )
                var metadata = requestsByID[id]?.diagnosticMetadata ?? ["requestID": String(id)]
                metadata["elapsedMs"] = String(Self.elapsedMilliseconds(since: requestStartedAt[id] ?? startedAt))
                metadata["responseThreadCount"] = String(responseThreads.count)
                metadata["totalThreadCount"] = String(discoveredThreads.count)
                metadata["candidateCount"] = String(candidates.count)
                metadata["pendingIDs"] = Self.joinedIDs(pending)
                metadata.merge(Self.candidateDiagnosticMetadata(candidates)) { current, _ in current }
                emitDiscoveryDiagnostic(
                    "responseReceived",
                    providerID: providerID,
                    discoveryID: discoveryID,
                    startedAt: startedAt,
                    metadata: metadata
                )
                if Self.shouldReturnEarly(candidates) {
                    emitDiscoveryDiagnostic(
                        "resolvedEarly",
                        providerID: providerID,
                        discoveryID: discoveryID,
                        startedAt: startedAt,
                        metadata: Self.candidateDiagnosticMetadata(candidates).merging([
                            "pendingIDs": Self.joinedIDs(pending)
                        ]) { current, _ in current }
                    )
                    return candidates
                }
                if pending.isEmpty {
                    break
                }
            }
        } catch {
            if Date() >= deadline {
                await emitDiscoveryTimeoutDiagnostic(
                    providerID: providerID,
                    discoveryID: discoveryID,
                    startedAt: startedAt,
                    pending: pending,
                    discoveredThreads: discoveredThreads,
                    query: query,
                    session: session
                )
                throw Self.projectDiscoveryTimedOut(providerID: providerID)
            }
            emitDiscoveryDiagnostic(
                "failed",
                providerID: providerID,
                discoveryID: discoveryID,
                startedAt: startedAt,
                metadata: [
                    "errorType": String(describing: type(of: error)),
                    "pendingIDs": Self.joinedIDs(pending)
                ]
            )
            throw error
        }

        guard didQueueRequests, pending.isEmpty else {
            if Date() >= deadline {
                await emitDiscoveryTimeoutDiagnostic(
                    providerID: providerID,
                    discoveryID: discoveryID,
                    startedAt: startedAt,
                    pending: pending,
                    discoveredThreads: discoveredThreads,
                    query: query,
                    session: session
                )
                throw Self.projectDiscoveryTimedOut(providerID: providerID)
            }
            emitDiscoveryDiagnostic(
                "exitedBeforeCompletion",
                providerID: providerID,
                discoveryID: discoveryID,
                startedAt: startedAt,
                metadata: ["pendingIDs": Self.joinedIDs(pending)]
            )
            throw RocaError.providerUnavailable(ProviderID(rawValue: "\(providerID.rawValue): project discovery exited before completion"))
        }

        let candidates = CodexProjectDiscoveryRanker.candidates(
            from: discoveredThreads,
            query: query,
            providerID: providerID
        )
        emitDiscoveryDiagnostic(
            "completed",
            providerID: providerID,
            discoveryID: discoveryID,
            startedAt: startedAt,
            metadata: Self.candidateDiagnosticMetadata(candidates).merging([
                "totalThreadCount": String(discoveredThreads.count)
            ]) { current, _ in current }
        )
        return candidates
    }

    private static func projectDiscoveryTimedOut(providerID: ProviderID) -> RocaError {
        .providerTimedOut(providerID: providerID, modelID: "Codex project discovery")
    }

    private func emitDiscoveryTimeoutDiagnostic(
        providerID: ProviderID,
        discoveryID: String,
        startedAt: Date,
        pending: Set<Int>,
        discoveredThreads: [CodexDiscoveredThread],
        query: ProjectDiscoveryQuery,
        session: CodexAppServerSession
    ) async {
        let candidates = CodexProjectDiscoveryRanker.candidates(
            from: discoveredThreads,
            query: query,
            providerID: providerID
        )
        var metadata = Self.candidateDiagnosticMetadata(candidates)
        metadata["pendingIDs"] = Self.joinedIDs(pending)
        metadata["totalThreadCount"] = String(discoveredThreads.count)
        let stderrTail = await session.stderrTailText(maxCharacters: 1_000)
        if !stderrTail.isEmpty {
            metadata["stderrTail"] = stderrTail
        }
        emitDiscoveryDiagnostic(
            "timedOut",
            providerID: providerID,
            discoveryID: discoveryID,
            startedAt: startedAt,
            metadata: metadata
        )
    }

    private func emitDiscoveryDiagnostic(
        _ event: String,
        providerID: ProviderID,
        discoveryID: String,
        startedAt: Date,
        metadata: [String: String] = [:]
    ) {
        var metadata = metadata
        metadata["event"] = event
        metadata["discoveryID"] = discoveryID
        metadata["elapsedMs"] = String(Self.elapsedMilliseconds(since: startedAt))
        let event = AssistantDiagnosticEvent(
            kind: .agentProviderDiagnostic,
            phase: "codexProjectDiscovery",
            providerID: providerID,
            metadata: metadata
        )
        Task {
            await diagnosticSink(event)
        }
    }

    static func shouldReturnEarly(_ candidates: [ProjectDiscoveryCandidate]) -> Bool {
        guard let best = candidates.first, best.confidence == .high, best.score >= 100 else {
            return false
        }
        guard let runnerUp = candidates.dropFirst().first else {
            return true
        }
        return best.score - runnerUp.score >= 25
    }

    private static func candidateDiagnosticMetadata(_ candidates: [ProjectDiscoveryCandidate]) -> [String: String] {
        guard let best = candidates.first else {
            return ["candidateCount": String(candidates.count)]
        }
        return [
            "candidateCount": String(candidates.count),
            "topScore": String(best.score),
            "topConfidence": best.confidence.rawValue,
            "topFolderName": best.project.localFolderName
        ]
    }

    private static func joinedIDs(_ ids: Set<Int>) -> String {
        ids.sorted().map(String.init).joined(separator: ",")
    }

    private static func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }

    private static func redactedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }

    private func resolvedExecutableURL() -> URL? {
        if let executableURL = configuration.executableURL {
            return isExecutableFile(executableURL.path) ? executableURL : nil
        }

        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { isExecutableFile($0.path) }
    }

    private static func threadID(from message: CodexRPCMessage) throws -> String {
        if let threadID = message.result?["thread"]?["id"]?.stringValue {
            return threadID
        }
        throw RocaError.providerUnavailable(ProviderID(rawValue: "codex-agent: missing thread id"))
    }

    private static func handle(
        _ message: CodexRPCMessage,
        method: String,
        request: AgentRunRequest,
        providerID: ProviderID,
        session: CodexAppServerSession,
        approvalDecisioner: any AgentApprovalDecisioning,
        threadID: String?,
        accumulatedText: inout String,
        didComplete: inout Bool,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        switch method {
        case "item/agentMessage/delta":
            guard let delta = message.params?["delta"]?.stringValue else {
                return
            }
            accumulatedText += delta
            continuation.yield(.textDelta(delta))
        case "item/started":
            if let activity = toolActivity(from: message.params?["item"], fallbackStatus: "started") {
                continuation.yield(.toolActivity(activity))
            }
        case "item/completed":
            if let item = message.params?["item"] {
                if item["type"]?.stringValue == "agentMessage", let text = item["text"]?.stringValue, accumulatedText.isEmpty {
                    accumulatedText = text
                }
                if let activity = toolActivity(from: item, fallbackStatus: "completed") {
                    continuation.yield(.toolActivity(activity))
                }
            }
        case "item/commandExecution/outputDelta":
            if let delta = message.params?["delta"]?.stringValue, !delta.isEmpty {
                continuation.yield(
                    .toolActivity(
                        AgentToolActivity(
                            itemID: message.params?["itemId"]?.stringValue,
                            kind: .command,
                            title: "Command output",
                            status: delta
                        )
                    )
                )
            }
        case "item/fileChange/outputDelta", "item/fileChange/patchUpdated":
            continuation.yield(
                .toolActivity(
                    AgentToolActivity(
                        itemID: message.params?["itemId"]?.stringValue,
                        kind: .fileChange,
                        title: "File changes",
                        status: "updated"
                    )
                )
            )
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            let prompt = approvalPrompt(for: message, method: method, request: request, providerID: providerID)
            continuation.yield(.approvalRequired(prompt.requirement))
            let decision = try await approvalDecisioner.decision(for: prompt)
            guard try respondToApprovalRequest(message, decision: decision, session: session) else {
                throw decision == .deny
                    ? RocaError.approvalDenied(prompt.detail)
                    : RocaError.approvalRequired(prompt.detail)
            }
        case "turn/completed":
            var metadata = ["source": "codex-app-server"]
            if let threadID {
                metadata["threadID"] = threadID
            }
            continuation.yield(
                .final(
                    AgentResponse(
                        text: accumulatedText,
                        usedProvider: providerID,
                        metadata: metadata
                    )
                )
            )
            continuation.finish()
            didComplete = true
        case "error", "thread/realtime/error":
            throw RocaError.providerUnavailable(
                ProviderID(rawValue: "\(providerID.rawValue): \(message.params?["error"]?.stringValue ?? "app-server error")")
            )
        default:
            break
        }
    }

    private static func toolActivity(from item: CodexJSONValue?, fallbackStatus: String) -> AgentToolActivity? {
        guard let item, let type = item["type"]?.stringValue else {
            return nil
        }

        switch type {
        case "commandExecution":
            return AgentToolActivity(
                itemID: item["id"]?.stringValue,
                kind: .command,
                title: item["command"]?.stringValue ?? "Command",
                status: item["status"]?.stringValue ?? fallbackStatus
            )
        case "fileChange":
            return AgentToolActivity(
                itemID: item["id"]?.stringValue,
                kind: .fileChange,
                title: "File changes",
                status: item["status"]?.stringValue ?? fallbackStatus
            )
        default:
            return nil
        }
    }

    private static func approvalPrompt(
        for message: CodexRPCMessage,
        method: String,
        request: AgentRunRequest,
        providerID: ProviderID
    ) -> AgentApprovalPrompt {
        var scopedRequest = CodexAgentPolicy.approvalScopedRequest(request)
        var actionScopes = scopedRequest.actionScopes
        let params = message.params
        let toolActivity: AgentToolActivity?
        let title: String

        switch method {
        case "item/commandExecution/requestApproval":
            actionScopes.append(.runCommands)
            if params?["networkApprovalContext"] != nil {
                actionScopes.append(.useNetwork)
            }
            title = "Codex Command"
            toolActivity = AgentToolActivity(
                itemID: params?["itemId"]?.stringValue,
                kind: .command,
                title: params?["command"]?.stringValue ?? "Command",
                status: params?["reason"]?.stringValue
            )
        case "item/fileChange/requestApproval":
            actionScopes.append(.editWorkspace)
            title = "Codex File Change"
            toolActivity = AgentToolActivity(
                itemID: params?["itemId"]?.stringValue,
                kind: .fileChange,
                title: "File changes",
                status: params?["reason"]?.stringValue
            )
        default:
            title = "Codex Permissions"
            toolActivity = AgentToolActivity(
                itemID: params?["itemId"]?.stringValue,
                kind: .other,
                title: "Additional permissions",
                status: params?["reason"]?.stringValue
            )
        }

        scopedRequest.actionScopes = AgentRunRequest.normalized(actionScopes)
        let requirement = CodexAgentPolicy.approvalRequirement(providerID: providerID, request: scopedRequest)
        let detail = params?["reason"]?.stringValue
            ?? params?["command"]?.stringValue
            ?? requirement.detailText
        return AgentApprovalPrompt(
            requirement: requirement,
            title: title,
            detail: detail,
            toolActivity: toolActivity
        )
    }

    private static func respondToApprovalRequest(
        _ message: CodexRPCMessage,
        decision: AgentApprovalDecision,
        session: CodexAppServerSession
    ) throws -> Bool {
        guard let id = message.id, let response = approvalResponse(for: message, decision: decision) else {
            return false
        }
        try session.send(.response(id: id, result: response))
        return decision == .approve || decision == .approveForSession
    }

    static func approvalResponse(for message: CodexRPCMessage, decision: AgentApprovalDecision) -> CodexJSONValue? {
        switch message.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            .object(["decision": .string(codexDecision(for: decision))])
        case "item/permissions/requestApproval":
            .object([
                "permissions": permissionsGrant(for: message, decision: decision),
                "scope": .string(decision == .approveForSession ? "session" : "turn")
            ])
        default:
            nil
        }
    }

    private static func permissionsGrant(
        for message: CodexRPCMessage,
        decision: AgentApprovalDecision
    ) -> CodexJSONValue {
        guard decision == .approve || decision == .approveForSession else {
            return .object([:])
        }
        return message.params?["permissions"] ?? .object([:])
    }

    private static func codexDecision(for decision: AgentApprovalDecision) -> String {
        switch decision {
        case .approve:
            "accept"
        case .approveForSession:
            "acceptForSession"
        case .deny:
            "decline"
        case .cancel:
            "cancel"
        }
    }
}

enum CodexAppServerRequestBuilder {
    static func initializeParams() -> CodexJSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("roca"),
                "title": .string("Roca"),
                "version": .string("0.1.0")
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true)
            ])
        ])
    }

    static func threadStartParams(for request: AgentRunRequest) -> CodexJSONValue {
        let scopedRequest = CodexAgentPolicy.approvalScopedRequest(request)
        return .compactObject([
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "cwd": scopedRequest.workspacePath.map(CodexJSONValue.string),
            "ephemeral": .bool(true),
            "model": scopedRequest.modelID.map(CodexJSONValue.string),
            "sandbox": .string(CodexAgentPolicy.threadSandboxMode(for: scopedRequest)),
            "serviceName": .string("Roca")
        ])
    }

    static func turnStartParams(for request: AgentRunRequest, threadID: String) -> CodexJSONValue {
        let scopedRequest = CodexAgentPolicy.approvalScopedRequest(request)
        return .compactObject([
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "cwd": scopedRequest.workspacePath.map(CodexJSONValue.string),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(scopedRequest.prompt)
                ])
            ]),
            "model": scopedRequest.modelID.map(CodexJSONValue.string),
            "sandboxPolicy": CodexAgentPolicy.turnSandboxPolicy(for: scopedRequest),
            "threadId": .string(threadID)
        ])
    }
}

struct CodexRPCError: Codable, Equatable, Sendable {
    var code: Int
    var message: String
    var data: CodexJSONValue?
}

struct CodexRPCMessage: Codable, Equatable, Sendable {
    var id: CodexJSONValue?
    var method: String?
    var params: CodexJSONValue?
    var result: CodexJSONValue?
    var error: CodexRPCError?

    static func request(id: Int, method: String, params: CodexJSONValue) -> CodexRPCMessage {
        CodexRPCMessage(id: .int(id), method: method, params: params, result: nil, error: nil)
    }

    static func notification(method: String, params: CodexJSONValue? = nil) -> CodexRPCMessage {
        CodexRPCMessage(id: nil, method: method, params: params, result: nil, error: nil)
    }

    static func response(id: CodexJSONValue, result: CodexJSONValue) -> CodexRPCMessage {
        CodexRPCMessage(id: id, method: nil, params: nil, result: result, error: nil)
    }

    static func decode(_ line: String) throws -> CodexRPCMessage {
        try JSONDecoder().decode(CodexRPCMessage.self, from: Data(line.utf8))
    }
}

final class CodexAppServerSession: @unchecked Sendable {
    let output = Pipe()

    private let process = Process()
    private let input = Pipe()
    private let error = Pipe()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
    private let stderrTail = CodexAppServerStderrTail(maxLines: 20)
    private var outputLineBuffer: CodexAppServerLineBuffer?
    private var errorLineBuffer: CodexAppServerLineBuffer?
    private var stderrDrainTask: Task<Void, Never>?

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
    }

    func start() throws {
        try process.run()
        let stderrLines = lines(from: error.fileHandleForReading, storeIn: \.errorLineBuffer)
        stderrDrainTask = Task { [stderrLines, stderrTail] in
            do {
                for try await line in stderrLines {
                    await stderrTail.append(Self.redacted(line))
                }
            } catch {}
        }
    }

    func send(_ message: CodexRPCMessage) throws {
        var data = try encoder.encode(message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        stderrDrainTask?.cancel()
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        outputLineBuffer?.finish()
        errorLineBuffer?.finish()
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
        }
    }

    func stderrTailText(maxCharacters: Int) async -> String {
        await stderrTail.text(maxCharacters: maxCharacters)
    }

    func outputLines() -> AsyncThrowingStream<String, Error> {
        lines(from: output.fileHandleForReading, storeIn: \.outputLineBuffer)
    }

    private func lines(
        from fileHandle: FileHandle,
        storeIn keyPath: ReferenceWritableKeyPath<CodexAppServerSession, CodexAppServerLineBuffer?>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let buffer = CodexAppServerLineBuffer(continuation: continuation)
            self[keyPath: keyPath] = buffer
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    buffer.finish()
                    return
                }
                buffer.append(data)
            }
            continuation.onTermination = { _ in
                fileHandle.readabilityHandler = nil
            }
        }
    }

    private static func redacted(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return text.replacingOccurrences(of: home, with: "~")
    }
}

private actor CodexAppServerStderrTail {
    private let maxLines: Int
    private var lines: [String] = []

    init(maxLines: Int) {
        self.maxLines = max(1, maxLines)
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func text(maxCharacters: Int) -> String {
        let text = lines.joined(separator: "\n")
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.suffix(maxCharacters))
    }
}

private final class CodexAppServerLineBuffer: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var didFinish = false

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
        self.buffer.reserveCapacity(64 * 1024)
    }

    func append(_ data: Data) {
        lock.withLock {
            guard !didFinish else {
                return
            }
            for byte in data {
                if byte == 0x0A {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    buffer.append(byte)
                }
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !didFinish else {
                return
            }
            didFinish = true
            if !buffer.isEmpty {
                continuation.yield(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            }
            continuation.finish()
        }
    }
}

private actor CodexAppServerRunRegistry {
    private var sessions: [AgentRunID: CodexAppServerSession] = [:]

    func insert(_ session: CodexAppServerSession, for runID: AgentRunID) {
        sessions[runID] = session
    }

    func remove(_ runID: AgentRunID) {
        sessions.removeValue(forKey: runID)
    }

    func cancel(_ runID: AgentRunID) {
        sessions.removeValue(forKey: runID)?.terminate()
    }
}

private struct CodexProjectDiscoveryRequest {
    var id: Int
    var method: String
    var params: CodexJSONValue

    var diagnosticMetadata: [String: String] {
        var metadata: [String: String] = [
            "requestID": String(id),
            "method": method
        ]
        if let limit = params["limit"]?.intValue {
            metadata["limit"] = String(limit)
        }
        if let archived = params["archived"]?.boolValue {
            metadata["archived"] = String(archived)
        }
        if let searchTerm = params["searchTerm"]?.stringValue {
            metadata["searchTermPresent"] = String(!searchTerm.isEmpty)
            metadata["searchTermLength"] = String(searchTerm.count)
        }
        return metadata
    }

    static func requests(for query: ProjectDiscoveryQuery) -> [CodexProjectDiscoveryRequest] {
        var nextID = 2
        var requests: [CodexProjectDiscoveryRequest] = []
        for term in searchTerms(for: query) {
            requests.append(
                CodexProjectDiscoveryRequest(
                    id: nextID,
                    method: "thread/search",
                    params: .compactObject([
                        "limit": .int(20),
                        "searchTerm": .string(term),
                        "sourceKinds": sourceKinds
                    ])
                )
            )
            nextID += 1
        }

        for archived in [false, true] {
            requests.append(
                CodexProjectDiscoveryRequest(
                    id: nextID,
                    method: "thread/list",
                    params: .compactObject([
                        "limit": .int(250),
                        "sortKey": .string("updated_at"),
                        "sortDirection": .string("desc"),
                        "sourceKinds": sourceKinds,
                        "archived": .bool(archived)
                    ])
                )
            )
            nextID += 1
        }
        return requests
    }

    static func threads(from result: CodexJSONValue?) -> [CodexDiscoveredThread] {
        guard let data = result?["data"]?.arrayValue else {
            return []
        }
        return data.compactMap { item in
            if let thread = item["thread"] {
                return CodexDiscoveredThread(thread, snippet: item["snippet"]?.stringValue)
            }
            return CodexDiscoveredThread(item, snippet: nil)
        }
    }

    private static var sourceKinds: CodexJSONValue {
        .array([
            .string("cli"),
            .string("vscode"),
            .string("exec"),
            .string("appServer"),
            .string("subAgent"),
            .string("subAgentReview"),
            .string("subAgentCompact"),
            .string("subAgentThreadSpawn"),
            .string("subAgentOther"),
            .string("unknown")
        ])
    }

    private static func searchTerms(for query: ProjectDiscoveryQuery) -> [String] {
        let projectName = query.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        var terms = projectName.isEmpty ? [] : [projectName]
        let stopWords: Set<String> = [
            "about", "agent", "ask", "codex", "could", "does", "find", "from",
            "have", "into", "look", "please", "project", "tell", "that", "there",
            "this", "what", "when", "where", "with"
        ]
        let promptTerms = ProjectIdentityResolver.normalizedKey(query.prompt)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }

        for term in promptTerms where !terms.contains(where: { ProjectIdentityResolver.normalizedKey($0) == term }) {
            terms.append(term)
            if terms.count >= 4 {
                break
            }
        }
        return terms
    }
}

private struct CodexDiscoveredThread: Sendable {
    var id: String
    var cwd: String
    var name: String?
    var preview: String?
    var gitOriginURL: String?
    var updatedAt: Date?
    var snippet: String?

    init?(_ value: CodexJSONValue, snippet: String?) {
        guard let id = value["id"]?.stringValue,
              let cwd = value["cwd"]?.stringValue,
              !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        self.id = id
        self.cwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
        self.name = value["name"]?.stringValue
        self.preview = value["preview"]?.stringValue
        self.gitOriginURL = value["gitInfo"]?["originUrl"]?.stringValue
        if let updatedAt = value["updatedAt"]?.intValue {
            self.updatedAt = Date(timeIntervalSince1970: TimeInterval(updatedAt))
        }
        self.snippet = snippet
    }

    mutating func merge(_ other: CodexDiscoveredThread) {
        name = name ?? other.name
        preview = preview ?? other.preview
        gitOriginURL = gitOriginURL ?? other.gitOriginURL
        updatedAt = [updatedAt, other.updatedAt].compactMap { $0 }.max()
        snippet = snippet ?? other.snippet
    }
}

private enum CodexProjectDiscoveryRanker {
    static func candidates(
        from threads: [CodexDiscoveredThread],
        query: ProjectDiscoveryQuery,
        providerID: ProviderID
    ) -> [ProjectDiscoveryCandidate] {
        let mergedThreads = mergeThreads(threads)
        let grouped = Dictionary(grouping: mergedThreads, by: \.cwd)
        let queryKey = ProjectIdentityResolver.normalizedKey(query.projectName)
        let promptKeys = promptTerms(from: query.prompt)

        return grouped.compactMap { cwd, threads in
            let bestScore = threads
                .map { score($0, queryKey: queryKey, promptKeys: promptKeys) }
                .max() ?? 0
            let candidateScore = bestScore + min(30, max(0, threads.count - 1) * 3)
            guard candidateScore >= 45 else {
                return nil
            }

            let folderName = URL(fileURLWithPath: cwd).lastPathComponent
            let gitOriginURL = mostCommon(threads.compactMap(\.gitOriginURL))
            let project = ProjectIdentity(
                id: ProjectID(rawValue: "discovered-\(ProjectIdentityResolver.normalizedKey(cwd).replacingOccurrences(of: " ", with: "-"))"),
                displayName: displayName(for: folderName),
                aliases: aliases(
                    query: query.projectName,
                    folderName: folderName,
                    gitOriginURL: gitOriginURL
                ),
                localPath: cwd,
                gitRemoteURL: gitOriginURL,
                agentThreads: threadReferences(from: threads, providerID: providerID)
            )
            return ProjectDiscoveryCandidate(
                project: project,
                confidence: confidence(for: candidateScore),
                score: candidateScore,
                evidence: evidence(for: cwd, gitOriginURL: gitOriginURL)
            )
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.project.displayName.localizedCaseInsensitiveCompare($1.project.displayName) == .orderedAscending
        }
    }

    private static func mergeThreads(_ threads: [CodexDiscoveredThread]) -> [CodexDiscoveredThread] {
        var merged: [String: CodexDiscoveredThread] = [:]
        for thread in threads {
            if var existing = merged[thread.id] {
                existing.merge(thread)
                merged[thread.id] = existing
            } else {
                merged[thread.id] = thread
            }
        }
        return Array(merged.values)
    }

    private static func score(
        _ thread: CodexDiscoveredThread,
        queryKey: String,
        promptKeys: [String]
    ) -> Int {
        guard !queryKey.isEmpty else {
            return 0
        }

        let folderName = URL(fileURLWithPath: thread.cwd).lastPathComponent
        let searchableNames = [
            folderName,
            remoteName(from: thread.gitOriginURL),
            thread.name
        ].compactMap { $0 }
        var score = searchableNames.reduce(0) { partial, name in
            max(partial, nameScore(name, queryKey: queryKey))
        }

        let pathKey = ProjectIdentityResolver.normalizedKey(thread.cwd)
        if pathKey.contains(queryKey) {
            score = max(score, 60)
        }

        let searchableText = ProjectIdentityResolver.normalizedKey(
            ([thread.name, thread.preview, thread.snippet].compactMap { $0 }).joined(separator: " ")
        )
        let promptScore = promptKeys
            .filter { searchableText.contains($0) }
            .prefix(4)
            .count * 8
        if thread.snippet != nil {
            score += 8
        }
        return score + promptScore
    }

    private static func nameScore(_ name: String, queryKey: String) -> Int {
        let nameKey = ProjectIdentityResolver.normalizedKey(name)
        if nameKey == queryKey {
            return 100
        }
        if tokenPrefixMatch(queryKey: queryKey, nameKey: nameKey) {
            return 75
        }
        if nameKey.contains(queryKey) {
            return 55
        }
        return 0
    }

    private static func tokenPrefixMatch(queryKey: String, nameKey: String) -> Bool {
        let queryTokens = queryKey.split(separator: " ")
        let nameTokens = nameKey.split(separator: " ")
        return !queryTokens.isEmpty && queryTokens.allSatisfy { queryToken in
            nameTokens.contains { $0.hasPrefix(queryToken) }
        }
    }

    private static func promptTerms(from prompt: String) -> [String] {
        let stopWords: Set<String> = ["about", "codex", "does", "have", "please", "project", "that", "this", "what", "with"]
        return ProjectIdentityResolver.normalizedKey(prompt)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    private static func displayName(for folderName: String) -> String {
        let words = folderName
            .split { !$0.isLetter && !$0.isNumber }
            .map { word in
                let text = String(word)
                return text.count <= 3 ? text.uppercased() : text.prefix(1).uppercased() + String(text.dropFirst())
            }
        return words.isEmpty ? folderName : words.joined(separator: " ")
    }

    private static func aliases(
        query: String,
        folderName: String,
        gitOriginURL: String?
    ) -> [String] {
        var aliases = [query, folderName]
        if let remoteName = remoteName(from: gitOriginURL) {
            aliases.append(remoteName)
        }
        return aliases
    }

    private static func threadReferences(
        from threads: [CodexDiscoveredThread],
        providerID: ProviderID
    ) -> [ProjectAgentThreadReference] {
        threads
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(5)
            .map {
                ProjectAgentThreadReference(
                    providerID: providerID,
                    threadID: $0.id,
                    title: $0.name,
                    updatedAt: $0.updatedAt
                )
            }
    }

    private static func evidence(for cwd: String, gitOriginURL: String?) -> [ProjectDiscoveryEvidence] {
        var evidence = [ProjectDiscoveryEvidence(source: "codex-thread-list", detail: "cwd: \(cwd)")]
        if let gitOriginURL {
            evidence.append(ProjectDiscoveryEvidence(source: "codex-thread-list", detail: "git remote: \(gitOriginURL)"))
        }
        return evidence
    }

    private static func confidence(for score: Int) -> ProjectDiscoveryConfidence {
        if score >= 90 {
            return .high
        }
        if score >= 60 {
            return .medium
        }
        return .low
    }

    private static func mostCommon(_ values: [String]) -> String? {
        values.reduce(into: [String: Int]()) { counts, value in
            counts[value, default: 0] += 1
        }
        .max {
            if $0.value != $1.value {
                return $0.value < $1.value
            }
            return $0.key > $1.key
        }?
        .key
    }

    private static func remoteName(from url: String?) -> String? {
        guard var value = url, !value.isEmpty else {
            return nil
        }
        if let lastSlash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: lastSlash)...])
        }
        if let colon = value.lastIndex(of: ":") {
            value = String(value[value.index(after: colon)...])
        }
        return value.replacingOccurrences(of: ".git", with: "")
    }
}
