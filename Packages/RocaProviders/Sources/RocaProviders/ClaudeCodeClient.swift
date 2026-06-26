import Foundation
import RocaCore

public protocol ClaudeCodeClient: Sendable {
    func setupStatus(providerID: ProviderID, displayName: String) async -> AgentProviderSetupStatus
    func prepare(providerID: ProviderID, displayName: String) async throws
    func run(_ request: AgentRunRequest, providerID: ProviderID) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(_ runID: AgentRunID) async
}

public struct ClaudeCodeConfiguration: Sendable {
    public var executableURL: URL?
    public var setupTimeoutSeconds: TimeInterval
    public var runTimeoutSeconds: TimeInterval

    public init(
        executableURL: URL? = nil,
        setupTimeoutSeconds: TimeInterval = 5,
        runTimeoutSeconds: TimeInterval = 300
    ) {
        self.executableURL = executableURL
        self.setupTimeoutSeconds = setupTimeoutSeconds
        self.runTimeoutSeconds = runTimeoutSeconds
    }
}

public struct ClaudeCodeCLIClient: ClaudeCodeClient {
    private let configuration: ClaudeCodeConfiguration
    private let isExecutableFile: @Sendable (String) -> Bool
    private let fileExists: @Sendable (String) -> Bool
    private let sessions = ClaudeCodeRunRegistry()

    public init(
        configuration: ClaudeCodeConfiguration = ClaudeCodeConfiguration(),
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.configuration = configuration
        self.isExecutableFile = isExecutableFile
        self.fileExists = fileExists
    }

    public func setupStatus(providerID: ProviderID, displayName: String) async -> AgentProviderSetupStatus {
        guard let executableURL = resolvedExecutableURL() else {
            return AgentProviderSetupStatus(
                providerID: providerID,
                displayName: displayName,
                state: .runtimeMissing,
                summary: "Claude Code CLI is not installed.",
                guidance: ClaudeCodePolicy.setupGuidance,
                installCommand: ClaudeCodePolicy.setupInstallCommand
            )
        }

        do {
            let result = try await runCommand(
                executableURL: executableURL,
                arguments: ["auth", "status"],
                currentDirectoryURL: nil,
                timeoutSeconds: configuration.setupTimeoutSeconds
            )
            guard result.exitCode == 0 else {
                return authMissingStatus(
                    providerID: providerID,
                    displayName: displayName,
                    detail: result.combinedOutput
                )
            }
            return AgentProviderSetupStatus(
                providerID: providerID,
                displayName: displayName,
                state: .ready,
                summary: "Claude Code CLI is ready.",
                guidance: ""
            )
        } catch RocaError.providerTimedOut {
            return AgentProviderSetupStatus(
                providerID: providerID,
                displayName: displayName,
                state: .unknown,
                summary: "Claude Code setup check timed out.",
                guidance: "Try `claude auth status` in Terminal, then recheck Claude Code."
            )
        } catch {
            return AgentProviderSetupStatus(
                providerID: providerID,
                displayName: displayName,
                state: .unknown,
                summary: "Claude Code setup could not be checked.",
                guidance: error.localizedDescription
            )
        }
    }

    public func prepare(providerID: ProviderID, displayName: String) async throws {
        let status = await setupStatus(providerID: providerID, displayName: displayName)
        guard status.isReady else {
            throw RocaError.agentProviderSetupRequired(status)
        }
    }

    public func run(_ request: AgentRunRequest, providerID: ProviderID) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard let executableURL = resolvedExecutableURL() else {
            throw RocaError.agentProviderSetupRequired(
                AgentProviderSetupStatus(
                    providerID: providerID,
                    displayName: "Claude Code",
                    state: .runtimeMissing,
                    summary: "Claude Code CLI is not installed.",
                    guidance: ClaudeCodePolicy.setupGuidance,
                    installCommand: ClaudeCodePolicy.setupInstallCommand
                )
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let session = ClaudeCodeProcessSession(
                    executableURL: executableURL,
                    arguments: ClaudeCodePolicy.arguments(for: request),
                    currentDirectoryURL: request.workspacePath.map(URL.init(fileURLWithPath:))
                )
                await sessions.insert(session, for: request.runID)
                do {
                    continuation.yield(.started(runID: request.runID, providerID: providerID))
                    let result = try await session.run(timeoutSeconds: configuration.runTimeoutSeconds)
                    await sessions.remove(request.runID)

                    guard result.exitCode == 0 else {
                        throw RocaError.providerUnavailable(
                            ProviderID(rawValue: "\(providerID.rawValue): \(Self.failureSummary(result))")
                        )
                    }

                    continuation.yield(
                        .final(
                            AgentResponse(
                                text: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                usedProvider: providerID,
                                metadata: ["source": "claude-code-cli"]
                            )
                        )
                    )
                    continuation.finish()
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

    private func resolvedExecutableURL() -> URL? {
        if let executableURL = configuration.executableURL {
            return isExecutableFile(executableURL.path) ? executableURL : nil
        }

        let pathCandidates = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map { "\($0)/claude" }
        let candidates = pathCandidates + [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/claude"
        ]

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { fileExists($0.path) && isExecutableFile($0.path) }
    }

    private func authMissingStatus(providerID: ProviderID, displayName: String, detail: String) -> AgentProviderSetupStatus {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance = trimmed.isEmpty
            ? "Run `claude auth status` in Terminal, sign in with Claude Code if needed, then recheck Claude Code."
            : trimmed
        return AgentProviderSetupStatus(
            providerID: providerID,
            displayName: displayName,
            state: .authMissing,
            summary: "Claude Code CLI is installed, but not signed in.",
            guidance: guidance
        )
    }

    private func runCommand(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeoutSeconds: TimeInterval
    ) async throws -> ClaudeCodeProcessResult {
        let session = ClaudeCodeProcessSession(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        )
        do {
            return try await session.run(timeoutSeconds: timeoutSeconds)
        } catch {
            session.terminate()
            throw error
        }
    }

    private static func failureSummary(_ result: ClaudeCodeProcessResult) -> String {
        let text = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "Claude Code exited with code \(result.exitCode)"
        }
        return String(text.prefix(300))
    }
}

private struct ClaudeCodeProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private final class ClaudeCodeProcessSession: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutBuffer = ClaudeCodeOutputBuffer()
    private let stderrBuffer = ClaudeCodeOutputBuffer()

    init(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
    }

    func run(timeoutSeconds: TimeInterval) async throws -> ClaudeCodeProcessResult {
        startReading()
        do {
            try process.run()
        } catch {
            stopReading()
            throw error
        }

        return try await withTaskCancellationHandler {
            do {
                let exitCode = try await waitUntilExit(timeoutSeconds: timeoutSeconds)
                stopReading()
                return ClaudeCodeProcessResult(
                    exitCode: exitCode,
                    stdout: stdoutBuffer.stringValue,
                    stderr: stderrBuffer.stringValue
                )
            } catch {
                terminate()
                throw error
            }
        } onCancel: {
            terminate()
        }
    }

    func terminate() {
        stopReading()
        if process.isRunning {
            process.terminate()
        }
    }

    private func waitUntilExit(timeoutSeconds: TimeInterval) async throws -> Int32 {
        enum WaitResult {
            case exited(Int32)
            case timedOut
        }

        return try await withThrowingTaskGroup(of: WaitResult.self) { group in
            group.addTask {
                self.process.waitUntilExit()
                return .exited(self.process.terminationStatus)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, timeoutSeconds) * 1_000_000_000))
                return .timedOut
            }

            let result = try await group.next()!
            group.cancelAll()
            switch result {
            case .exited(let exitCode):
                return exitCode
            case .timedOut:
                terminate()
                throw RocaError.providerTimedOut(providerID: BuiltInProviderIDs.claudeCode, modelID: "Claude Code CLI")
            }
        }
    }

    private func startReading() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutBuffer] handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrBuffer] handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }
    }

    private func stopReading() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }
}

private final class ClaudeCodeOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }

    var stringValue: String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}

private actor ClaudeCodeRunRegistry {
    private var sessions: [AgentRunID: ClaudeCodeProcessSession] = [:]

    func insert(_ session: ClaudeCodeProcessSession, for runID: AgentRunID) {
        sessions[runID] = session
    }

    func remove(_ runID: AgentRunID) {
        sessions.removeValue(forKey: runID)
    }

    func cancel(_ runID: AgentRunID) {
        sessions.removeValue(forKey: runID)?.terminate()
    }
}
