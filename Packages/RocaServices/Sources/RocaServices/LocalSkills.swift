import Dispatch
import Foundation
import RocaCore

public struct LocalSkillRunRequest: Equatable, Sendable {
    public var runID: SkillRunID
    public var skillID: SkillID
    public var prompt: String
    public var mode: AgentMode
    public var project: ProjectIdentity
    public var userInput: String
    public var metadata: [String: String]

    public init(
        runID: SkillRunID = .make(),
        skillID: SkillID,
        prompt: String,
        mode: AgentMode,
        project: ProjectIdentity,
        userInput: String,
        metadata: [String: String] = [:]
    ) {
        self.runID = runID
        self.skillID = skillID
        self.prompt = prompt
        self.mode = mode
        self.project = project
        self.userInput = userInput
        self.metadata = metadata
    }
}

public struct LocalSkillRunResult: Equatable, Sendable {
    public var runID: SkillRunID
    public var skillID: SkillID
    public var evidenceMarkdown: String
    public var evidenceSummary: AssistantEvidenceSummary
    public var metadata: [String: String]

    public init(
        runID: SkillRunID,
        skillID: SkillID,
        evidenceMarkdown: String,
        evidenceSummary: AssistantEvidenceSummary? = nil,
        metadata: [String: String] = [:]
    ) {
        self.runID = runID
        self.skillID = skillID
        self.evidenceMarkdown = evidenceMarkdown
        self.evidenceSummary = evidenceSummary ?? AssistantEvidenceSummary(
            sourceKind: .localSkill,
            sourceID: skillID.rawValue,
            sourceName: SkillDirectiveRequest.skillDisplayName(for: skillID) ?? skillID.rawValue,
            grade: .partial
        )
        self.metadata = metadata
    }
}

public protocol LocalSkillWorking: Sendable {
    var skillID: SkillID { get }
    var displayName: String { get }

    func run(_ request: LocalSkillRunRequest) async throws -> LocalSkillRunResult
}

public struct CodebaseSkillWorker: LocalSkillWorking {
    public let skillID = SkillID(rawValue: "codebase")
    public let displayName = "Codebase Skill"

    public init() {}

    public func run(_ request: LocalSkillRunRequest) async throws -> LocalSkillRunResult {
        let workspacePath = URL(fileURLWithPath: request.project.localPath).standardizedFileURL.path
        let taskProfile = CodebaseTaskProfile(prompt: request.prompt, userInput: request.userInput, metadata: request.metadata)
        let repoMap = try CodebaseRepositoryMap.build(workspacePath: workspacePath, taskProfile: taskProfile)
        let targetedEvidence = try CodebaseTargetedEvidence.collect(
            workspacePath: workspacePath,
            repoMap: repoMap,
            taskProfile: taskProfile,
            request: request
        )
        var sections: [String] = [
            """
            # Codebase Skill Evidence

            ## Workspace
            - Project: \(request.project.displayName)
            - Path: `\(workspacePath)`
            - Mode: \(request.mode.rawValue)
            - Task Profile: \(taskProfile.displayName)
            """
        ]
        var toolCount = 0

        sections.append(repoMap.languageInventoryMarkdown)

        if let status = runProcess("/usr/bin/env", ["git", "-C", workspacePath, "status", "--short", "--branch"], limit: 4_000) {
            toolCount += 1
            sections.append(markdownSection("Workspace Status", status))
        }

        toolCount += 1
        sections.append(repoMap.summaryMarkdown)
        sections.append(markdownSection("Top-Level Files", repoMap.topLevelEntries.map { "- \($0)" }.joined(separator: "\n")))

        if !repoMap.relevantPaths.isEmpty {
            sections.append(markdownSection("Relevant Paths", repoMap.relevantPaths.map { "- \($0)" }.joined(separator: "\n")))
        }

        if !targetedEvidence.snippets.isEmpty {
            toolCount += targetedEvidence.snippets.count
            sections.append(rawMarkdownSection("Targeted File Evidence", targetedEvidence.snippets.joined(separator: "\n\n")))
        }

        if request.metadata["workflowKind"] == "diffReview"
            || ProjectIdentityResolver.normalizedKey(request.prompt).contains("diff")
            || ProjectIdentityResolver.normalizedKey(request.userInput).contains("diff") {
            if let diffSummary = runProcess("/usr/bin/env", ["git", "-C", workspacePath, "diff", "--stat"], limit: 4_000),
               !diffSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                toolCount += 1
                sections.append(markdownSection("Diff Summary", diffSummary))
            }
            if let diff = runProcess("/usr/bin/env", ["git", "-C", workspacePath, "diff", "--", "."], limit: 12_000),
               !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                toolCount += 1
                sections.append(markdownSection("Bounded Diff", diff))
            }
        }

        let searchTerms = searchTerms(
            from: [request.prompt, request.userInput].joined(separator: " "),
            taskProfile: taskProfile
        )
        if !searchTerms.isEmpty {
            if let search = runSearch(searchTerms: searchTerms, workspacePath: workspacePath),
               !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                toolCount += 1
                sections.append(markdownSection("Search Results", search))
            }
        }

        sections.append(markdownSection("Evidence Contract", targetedEvidence.evidenceContract))
        let evidenceMarkdown = sections.joined(separator: "\n\n")
        let evidenceGrade: AssistantEvidenceGrade = repoMap.scannedFileCount > 0 ? .verified : .insufficient
        let evidenceSummary = AssistantEvidenceSummary(
            sourceKind: .localSkill,
            sourceID: skillID.rawValue,
            sourceName: displayName,
            grade: evidenceGrade,
            projectID: request.project.id.rawValue,
            projectName: request.project.displayName,
            workspacePath: workspacePath,
            scannedFileCount: repoMap.scannedFileCount,
            manifestCount: repoMap.manifests.count,
            inspectedPaths: targetedEvidence.inspectedPaths,
            searchTerms: searchTerms,
            omittedPathCount: targetedEvidence.omittedPathCount,
            originalCharacterCount: evidenceMarkdown.count,
            budgetedCharacterCount: evidenceMarkdown.count,
            isTruncated: false,
            coverageNotes: [
                "Scanned non-generated files and excluded common dependency/build output directories.",
                "Read targeted snippets selected from manifests, relevant paths, and task terms."
            ],
            limitations: targetedEvidence.omittedPathCount > 0
                ? ["Some candidate files were omitted from targeted snippets to keep evidence bounded."]
                : []
        )

        return LocalSkillRunResult(
            runID: request.runID,
            skillID: request.skillID,
            evidenceMarkdown: evidenceMarkdown,
            evidenceSummary: evidenceSummary,
            metadata: [
                "toolCount": String(toolCount),
                "filesScanned": String(repoMap.scannedFileCount),
                "manifestCount": String(repoMap.manifests.count),
                "targetedPathCount": String(repoMap.relevantPaths.count),
                "evidenceGrade": evidenceSummary.grade.rawValue,
                "evidenceCharacters": String(evidenceMarkdown.count),
                "omittedPathCount": String(evidenceSummary.omittedPathCount),
                "taskProfile": taskProfile.rawValue,
                "workspacePath": workspacePath
            ]
        )
    }

    private func markdownSection(_ title: String, _ body: String) -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return """
            ## \(title)
            No evidence gathered.
            """
        }
        return """
        ## \(title)
        ```text
        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        ```
        """
    }

    private func rawMarkdownSection(_ title: String, _ body: String) -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return """
            ## \(title)
            No evidence gathered.
            """
        }
        return """
        ## \(title)
        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private func searchTerms(from text: String, taskProfile: CodebaseTaskProfile) -> [String] {
        let stopWords = Set([
            "a", "about", "and", "architecture", "are", "codebase", "does", "draft", "entry",
            "for", "how", "implementation", "in", "important", "is", "it", "live", "plan",
            "project", "repo", "repository", "summarize", "the", "this", "to", "tradeoffs",
            "where", "with"
        ])
        var seen = Set<String>()
        let terms = ProjectIdentityResolver.normalizedKey(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
        let boosted = taskProfile.boostedSearchTerms.filter { seen.insert($0).inserted }
        return Array((terms + boosted).prefix(8))
    }

    private func runSearch(searchTerms: [String], workspacePath: String) -> String? {
        let excludeArgs = CodebaseRepositoryMap.excludedDirectoryNames.flatMap { ["--glob", "!\($0)/**"] }
        var outputs: [String] = []
        for term in searchTerms.prefix(6) {
            let args = [
                "rg",
                "--fixed-strings",
                "--ignore-case",
                "--line-number",
                "--no-heading",
                "--max-count",
                "8"
            ] + excludeArgs + [term, workspacePath]
            guard let output = runProcess("/usr/bin/env", args, limit: 4_000),
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            outputs.append("### Search term: \(term)\n\(output)")
        }
        guard !outputs.isEmpty else {
            return nil
        }
        return outputs.joined(separator: "\n\n")
    }

    private func runProcess(
        _ executablePath: String,
        _ arguments: [String],
        limit: Int,
        timeout: TimeInterval = 5
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        let output = BoundedProcessOutput(limit: limit)
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            output.appendStdout(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            output.appendStderr(handle.availableData)
        }

        do {
            try process.run()
            let timeoutMilliseconds = Int((timeout * 1_000).rounded())
            guard finished.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .success else {
                process.terminate()
                _ = finished.wait(timeout: .now() + .milliseconds(200))
                process.terminationHandler = nil
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                return nil
            }
            process.terminationHandler = nil
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            output.appendStdout(stdout.fileHandleForReading.availableData)
            output.appendStderr(stderr.fileHandleForReading.availableData)
            return output.stdoutString()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return nil
        }
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutTruncated = false
    private var stderrTruncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func appendStdout(_ data: Data) {
        append(data, stream: .stdout)
    }

    func appendStderr(_ data: Data) {
        append(data, stream: .stderr)
    }

    func stdoutString() -> String? {
        lock.lock()
        let data = stdout
        let truncated = stdoutTruncated
        lock.unlock()
        guard !data.isEmpty else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        return truncated ? "\(text)\n[truncated]" : text
    }

    private enum OutputStream {
        case stdout
        case stderr
    }

    private func append(_ data: Data, stream: OutputStream) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        switch stream {
        case .stdout:
            appendLocked(data, to: &stdout, truncated: &stdoutTruncated)
        case .stderr:
            appendLocked(data, to: &stderr, truncated: &stderrTruncated)
        }
    }

    private func appendLocked(_ data: Data, to target: inout Data, truncated: inout Bool) {
        guard target.count < limit else {
            truncated = true
            return
        }
        let remaining = limit - target.count
        if data.count <= remaining {
            target.append(data)
        } else {
            target.append(data.prefix(remaining))
            truncated = true
        }
    }
}

private enum CodebaseTaskProfile: String, Sendable {
    case languageInventory
    case infrastructure
    case architecture
    case behaviorLocation
    case implementationPlan
    case diffReview
    case general

    init(prompt: String, userInput: String, metadata: [String: String]) {
        if metadata["workflowKind"] == "diffReview" {
            self = .diffReview
            return
        }
        if metadata["workflowKind"] == "implementationPlan" {
            self = .implementationPlan
            return
        }
        if metadata["workflowKind"] == "architectureSummary" {
            self = .architecture
            return
        }
        if metadata["workflowKind"] == "behaviorLocation" {
            self = .behaviorLocation
            return
        }

        let text = ProjectIdentityResolver.normalizedKey([prompt, userInput].joined(separator: " "))
        if text.contains("infra")
            || text.contains("infrastructure")
            || text.contains("deployment")
            || text.contains("deploy")
            || text.contains("cdk")
            || text.contains("terraform")
            || text.contains("cloudformation")
            || text.contains("stack") {
            self = .infrastructure
        } else if text.contains("what language")
            || text.contains("which language")
            || text.contains("written in")
            || text.contains("languages") {
            self = .languageInventory
        } else if text.contains("implementation plan")
            || text.contains("tradeoff")
            || text.contains("trade off")
            || text.contains("draft a plan") {
            self = .implementationPlan
        } else if text.contains("where does")
            || text.contains("where is")
            || text.contains("where are")
            || text.contains("find") {
            self = .behaviorLocation
        } else if text.contains("architecture")
            || text.contains("entry point")
            || text.contains("overview") {
            self = .architecture
        } else if text.contains("diff")
            || text.contains("changes") {
            self = .diffReview
        } else {
            self = .general
        }
    }

    var displayName: String {
        switch self {
        case .languageInventory:
            "language inventory"
        case .infrastructure:
            "infrastructure/deployment"
        case .architecture:
            "architecture overview"
        case .behaviorLocation:
            "behavior lookup"
        case .implementationPlan:
            "implementation planning"
        case .diffReview:
            "diff review"
        case .general:
            "general codebase inspection"
        }
    }

    var boostedSearchTerms: [String] {
        switch self {
        case .infrastructure:
            ["infra", "infrastructure", "deployment", "deploy", "cdk", "aws-cdk-lib", "terraform", "cloudformation", "stack"]
        case .languageInventory:
            ["package.json", "go.mod", "Package.swift", "pyproject.toml", "Cargo.toml", "cdk.json"]
        case .architecture:
            ["main", "app", "server", "service", "router", "entry"]
        case .behaviorLocation:
            ["route", "router", "handler", "service", "controller"]
        case .implementationPlan:
            ["route", "handler", "service", "test", "model"]
        case .diffReview:
            ["TODO", "FIXME", "test", "error"]
        case .general:
            []
        }
    }
}

private struct CodebaseRepositoryMap: Sendable {
    static let excludedDirectoryNames: [String] = [
        ".build",
        ".cache",
        ".git",
        ".next",
        ".swiftpm",
        ".terraform",
        "DerivedData",
        "Pods",
        "build",
        "cdk.out",
        "coverage",
        "dist",
        "node_modules",
        "out",
        "target",
        "vendor"
    ]

    var topLevelEntries: [String]
    var manifests: [CodebaseManifest]
    var languageCounts: [String: Int]
    var supportFileCounts: [String: Int]
    var frameworkSignals: [String]
    var importantFolders: [String]
    var relevantPaths: [String]
    var scannedFileCount: Int
    var skippedDirectories: [String]

    var languageInventoryMarkdown: String {
        var sections: [String] = []

        let languageLines = languageCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(12)
            .map { "- \($0.key): \($0.value) files" }
        if !languageLines.isEmpty {
            sections.append("""
            ### Languages
            \(languageLines.joined(separator: "\n"))
            """)
        }

        let frameworkLines = frameworkSignals.prefix(12).map { "- \($0)" }
        if !frameworkLines.isEmpty {
            sections.append("""
            ### Framework Signals
            \(frameworkLines.joined(separator: "\n"))
            """)
        }

        let supportLines = supportFileCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(10)
            .map { "- \($0.key): \($0.value) files" }
        if !supportLines.isEmpty {
            sections.append("""
            ### Support And Config Files
            \(supportLines.joined(separator: "\n"))
            """)
        }

        let manifestLines = manifests
            .filter { manifest in
                let path = manifest.relativePath.lowercased()
                return path == "go.mod"
                    || path == "package.json"
                    || path.hasSuffix("/package.json")
                    || path == "cdk.json"
                    || path.hasSuffix("/cdk.json")
                    || path == "package.swift"
                    || path == "pyproject.toml"
                    || path == "cargo.toml"
                    || path.hasSuffix(".tf")
                    || path.hasSuffix(".hcl")
            }
            .prefix(20)
            .map { "- `\($0.relativePath)`: \($0.kind)" }
        if !manifestLines.isEmpty {
            sections.append("""
            ### Manifests
            \(manifestLines.joined(separator: "\n"))
            """)
        }

        guard !sections.isEmpty else {
            return "## Language And Manifest Inventory\nNo language or manifest signals found."
        }
        return """
        ## Language And Manifest Inventory
        \(sections.joined(separator: "\n\n"))
        """
    }

    var summaryMarkdown: String {
        var lines: [String] = [
            "- Files scanned: \(scannedFileCount)",
            "- Skipped directories: \(skippedDirectories.sorted().joined(separator: ", "))"
        ]

        let languages = languageCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(10)
            .map { "- \($0.key): \($0.value) files" }
            .joined(separator: "\n")
        if !languages.isEmpty {
            lines.append("\nPrimary Languages:\n\(languages)")
        }

        let supportFiles = supportFileCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(10)
            .map { "- \($0.key): \($0.value) files" }
            .joined(separator: "\n")
        if !supportFiles.isEmpty {
            lines.append("\nSupport And Config Files:\n\(supportFiles)")
        }

        if !frameworkSignals.isEmpty {
            lines.append("\nFramework Signals:\n\(frameworkSignals.prefix(12).map { "- \($0)" }.joined(separator: "\n"))")
        }

        if !importantFolders.isEmpty {
            lines.append("\nImportant Folders:\n\(importantFolders.map { "- \($0)" }.joined(separator: "\n"))")
        }

        if !manifests.isEmpty {
            let manifestLines = manifests
                .prefix(30)
                .map { "- \($0.relativePath) (\($0.kind))" }
                .joined(separator: "\n")
            lines.append("\nDetected Manifests:\n\(manifestLines)")
        }

        return """
        ## Repository Map
        ```text
        \(lines.joined(separator: "\n"))
        ```
        """
    }

    static func build(workspacePath: String, taskProfile: CodebaseTaskProfile) throws -> CodebaseRepositoryMap {
        let workspaceURL = URL(fileURLWithPath: workspacePath).standardizedFileURL
        let fm = FileManager.default
        let topLevelEntries = try fm.contentsOfDirectory(atPath: workspacePath)
            .filter { !Self.excludedDirectoryNames.contains($0) && $0 != ".DS_Store" }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        guard let enumerator = fm.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return CodebaseRepositoryMap(
                topLevelEntries: topLevelEntries,
                manifests: [],
                languageCounts: [:],
                supportFileCounts: [:],
                frameworkSignals: [],
                importantFolders: [],
                relevantPaths: [],
                scannedFileCount: 0,
                skippedDirectories: Self.excludedDirectoryNames
            )
        }

        var manifests: [CodebaseManifest] = []
        var languageCounts: [String: Int] = [:]
        var supportFileCounts: [String: Int] = [:]
        var frameworkSignals = Set<String>()
        var importantFolders = Set<String>()
        var relevantPaths = Set<String>()
        var scannedFileCount = 0

        while case let fileURL as URL = enumerator.nextObject() {
            let name = fileURL.lastPathComponent
            let relativePath = relativePath(for: fileURL, workspaceURL: workspaceURL)
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])

            if resourceValues?.isDirectory == true {
                if Self.excludedDirectoryNames.contains(name) || generatedPath(relativePath) {
                    enumerator.skipDescendants()
                    continue
                }
                if importantDirectoryNames.contains(name) {
                    importantFolders.insert(relativePath)
                }
                if taskProfile == .infrastructure && infrastructurePath(relativePath) {
                    relevantPaths.insert(relativePath)
                }
                continue
            }

            guard resourceValues?.isRegularFile == true,
                  !generatedPath(relativePath)
            else {
                continue
            }

            scannedFileCount += 1
            switch fileSignal(for: fileURL, relativePath: relativePath) {
            case .implementation(let language):
                languageCounts[language, default: 0] += 1
            case .support(let kind):
                supportFileCounts[kind, default: 0] += 1
            case nil:
                break
            }
            if let manifest = CodebaseManifest(relativePath: relativePath, fileName: name) {
                manifests.append(manifest)
                frameworkSignals.formUnion(Self.frameworkSignals(in: fileURL, manifest: manifest))
                if taskProfile == .languageInventory || taskProfile == .architecture || taskProfile == .infrastructure {
                    relevantPaths.insert(relativePath)
                }
            }
            if taskProfile == .languageInventory && representativeLanguageEvidencePath(relativePath) {
                relevantPaths.insert(relativePath)
            }
            if taskProfile == .infrastructure && infrastructurePath(relativePath) {
                relevantPaths.insert(relativePath)
            }
            if taskProfile == .architecture && architecturePath(relativePath) {
                relevantPaths.insert(relativePath)
            }
        }

        return CodebaseRepositoryMap(
            topLevelEntries: topLevelEntries,
            manifests: manifests.sortedByPath(),
            languageCounts: languageCounts,
            supportFileCounts: supportFileCounts,
            frameworkSignals: frameworkSignals.sorted(),
            importantFolders: importantFolders.sorted(),
            relevantPaths: relevantPaths.sortedByPath().prefixArray(40),
            scannedFileCount: scannedFileCount,
            skippedDirectories: Self.excludedDirectoryNames
        )
    }

    private static let importantDirectoryNames = Set([
        ".github",
        "app",
        "bin",
        "cmd",
        "docs",
        "infra",
        "infrastructure",
        "internal",
        "lib",
        "packages",
        "scripts",
        "src",
        "test",
        "tests",
        "tools"
    ])

    private static func relativePath(for fileURL: URL, workspaceURL: URL) -> String {
        let path = fileURL.standardizedFileURL.path
        let root = workspaceURL.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            return fileURL.lastPathComponent
        }
        return String(path.dropFirst(root.count + 1))
    }

    private static func generatedPath(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        return parts.contains { excludedDirectoryNames.contains($0) }
            || relativePath.hasSuffix(".generated.swift")
            || relativePath.hasSuffix(".generated.ts")
            || relativePath.hasSuffix(".min.js")
            || relativePath.hasSuffix(".lock")
    }

    private static func infrastructurePath(_ relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return normalized == "infra"
            || normalized.hasPrefix("infra/")
            || normalized == "infrastructure"
            || normalized.hasPrefix("infrastructure/")
            || normalized.contains("/infra/")
            || normalized.contains("/infrastructure/")
            || normalized.hasPrefix(".github/workflows/")
            || normalized.contains("cdk")
            || normalized.contains("terraform")
            || normalized.contains("cloudformation")
            || normalized.contains("stack")
    }

    private static func architecturePath(_ relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return normalized == "package.swift"
            || normalized == "package.json"
            || normalized == "go.mod"
            || normalized.hasPrefix("app/")
            || normalized.hasPrefix("src/")
            || normalized.hasPrefix("cmd/")
            || normalized.hasPrefix("internal/")
            || normalized.hasPrefix("packages/")
    }

    private static func representativeLanguageEvidencePath(_ relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        guard readableImplementationPath(normalized) else {
            return false
        }
        return normalized == "app.vue"
            || normalized == "main.swift"
            || normalized == "main.go"
            || normalized == "main.py"
            || normalized.hasPrefix("app/")
            || normalized.hasPrefix("pages/")
            || normalized.hasPrefix("components/")
            || normalized.hasPrefix("src/")
            || normalized.hasPrefix("cmd/")
            || normalized.hasPrefix("internal/")
            || normalized.hasPrefix("packages/")
    }

    private static func readableImplementationPath(_ relativePath: String) -> Bool {
        implementationLanguageName(forExtension: (relativePath as NSString).pathExtension.lowercased()) != nil
            || relativePath.hasSuffix("/Dockerfile")
            || relativePath == "Dockerfile"
    }

    private static func fileSignal(for fileURL: URL, relativePath: String) -> CodebaseFileSignal? {
        if let language = implementationLanguageName(forExtension: fileURL.pathExtension.lowercased()) {
            return .implementation(language)
        }
        if let support = supportFileKind(forExtension: fileURL.pathExtension.lowercased()) {
            return .support(support)
        }
        if fileURL.lastPathComponent == "Dockerfile" || relativePath.contains("/Dockerfile") {
            return .support("Dockerfile")
        }
        return nil
    }

    private static func implementationLanguageName(forExtension fileExtension: String) -> String? {
        switch fileExtension {
        case "swift":
            return "Swift"
        case "go":
            return "Go"
        case "js", "mjs", "cjs", "jsx":
            return "JavaScript"
        case "ts", "tsx":
            return "TypeScript"
        case "vue":
            return "Vue"
        case "svelte":
            return "Svelte"
        case "astro":
            return "Astro"
        case "py":
            return "Python"
        case "rs":
            return "Rust"
        case "java":
            return "Java"
        case "kt", "kts":
            return "Kotlin"
        case "rb":
            return "Ruby"
        case "php":
            return "PHP"
        case "tf", "hcl":
            return "HCL/Terraform"
        case "sh", "bash", "zsh":
            return "Shell"
        case "sql":
            return "SQL"
        default:
            return nil
        }
    }

    private static func supportFileKind(forExtension fileExtension: String) -> String? {
        switch fileExtension {
        case "yaml", "yml":
            return "YAML"
        case "json":
            return "JSON"
        case "md":
            return "Markdown"
        case "toml":
            return "TOML"
        case "xml":
            return "XML"
        case "css", "scss", "sass", "less":
            return "Stylesheet"
        default:
            return nil
        }
    }

    private static func frameworkSignals(in fileURL: URL, manifest: CodebaseManifest) -> [String] {
        guard manifest.relativePath.hasSuffix("package.json"),
              let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = resourceValues.fileSize,
              fileSize <= 220_000,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return []
        }
        let normalized = contents.lowercased()
        var signals: [String] = []
        let checks = [
            ("nuxt", "Nuxt"),
            ("vue", "Vue"),
            ("next", "Next.js"),
            ("react", "React"),
            ("svelte", "Svelte"),
            ("astro", "Astro"),
            ("vite", "Vite"),
            ("aws-cdk-lib", "AWS CDK")
        ]
        for (needle, label) in checks where normalized.contains("\"\(needle)\"") || normalized.contains("@\(needle)/") {
            signals.append("\(label) via `\(manifest.relativePath)`")
        }
        return signals
    }
}

private enum CodebaseFileSignal: Sendable {
    case implementation(String)
    case support(String)
}

private struct CodebaseManifest: Sendable {
    var relativePath: String
    var kind: String

    init?(relativePath: String, fileName: String) {
        let lowerPath = relativePath.lowercased()
        switch fileName {
        case "Package.swift":
            self.kind = "Swift package"
        case "package.json":
            self.kind = "Node package"
        case "go.mod":
            self.kind = "Go module"
        case "pyproject.toml":
            self.kind = "Python project"
        case "Cargo.toml":
            self.kind = "Rust package"
        case "cdk.json":
            self.kind = "AWS CDK app"
        case "tsconfig.json":
            self.kind = "TypeScript config"
        case "Dockerfile":
            self.kind = "Docker build"
        case "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml":
            self.kind = "Docker Compose"
        case "atlas.hcl":
            self.kind = "Atlas/HCL config"
        default:
            if lowerPath.hasPrefix(".github/workflows/") && (lowerPath.hasSuffix(".yml") || lowerPath.hasSuffix(".yaml")) {
                self.kind = "GitHub Actions workflow"
            } else if lowerPath.hasSuffix(".tf") {
                self.kind = "Terraform"
            } else if lowerPath.hasSuffix(".hcl") {
                self.kind = "HCL config"
            } else {
                return nil
            }
        }
        self.relativePath = relativePath
    }
}

private struct CodebaseTargetedEvidence: Sendable {
    var snippets: [String]
    var inspectedPaths: [String]
    var omittedPathCount: Int
    var evidenceContract: String

    static func collect(
        workspacePath: String,
        repoMap: CodebaseRepositoryMap,
        taskProfile: CodebaseTaskProfile,
        request: LocalSkillRunRequest
    ) throws -> CodebaseTargetedEvidence {
        let candidates = snippetCandidates(repoMap: repoMap, taskProfile: taskProfile, request: request)
        var snippets: [String] = []
        var inspected: [String] = []
        for relativePath in candidates {
            guard snippets.count < 14 else {
                break
            }
            let fileURL = URL(fileURLWithPath: workspacePath).appendingPathComponent(relativePath)
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize,
                  fileSize <= 220_000,
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                continue
            }
            inspected.append(relativePath)
            snippets.append(snippetMarkdown(path: relativePath, contents: contents, maxLines: maxLines(for: relativePath, taskProfile: taskProfile)))
        }

        let contract = """
        Roca inspected \(repoMap.scannedFileCount) non-generated files and read targeted snippets from \(inspected.count) files.
        Inspected snippet paths:
        \(inspected.map { "- \($0)" }.joined(separator: "\n"))

        Answer only from the repository map, search results, diff, and snippets above.
        If the evidence does not prove something, say what was inspected and what remains uncertain.
        Do not claim a language, framework, folder, or file type is absent unless the repository map or search evidence establishes that.
        """
        return CodebaseTargetedEvidence(
            snippets: snippets,
            inspectedPaths: inspected,
            omittedPathCount: max(0, candidates.count - inspected.count),
            evidenceContract: contract
        )
    }

    private static func snippetCandidates(
        repoMap: CodebaseRepositoryMap,
        taskProfile: CodebaseTaskProfile,
        request: LocalSkillRunRequest
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            guard seen.insert(path).inserted else {
                return
            }
            candidates.append(path)
        }

        for path in ["README.md", "AGENTS.md", "CLAUDE.md"] {
            add(path)
        }

        for manifest in repoMap.manifests {
            if manifest.relativePath.split(separator: "/").count == 1 {
                add(manifest.relativePath)
            }
        }

        switch taskProfile {
        case .infrastructure:
            for manifest in repoMap.manifests where CodebaseRepositoryMap.infrastructurePathForEvidence(manifest.relativePath) {
                add(manifest.relativePath)
            }
            for path in repoMap.relevantPaths where CodebaseRepositoryMap.infrastructurePathForEvidence(path) && isReadableSource(path) {
                add(path)
            }
        case .languageInventory:
            for manifest in repoMap.manifests {
                add(manifest.relativePath)
            }
            var sourceCount = 0
            for path in repoMap.relevantPaths where isReadableImplementationSource(path) {
                guard sourceCount < 8 else {
                    break
                }
                add(path)
                sourceCount += 1
            }
        case .architecture:
            for path in repoMap.relevantPaths where isReadableSource(path) {
                add(path)
            }
        case .behaviorLocation, .implementationPlan, .diffReview, .general:
            for manifest in repoMap.manifests.prefix(10) {
                add(manifest.relativePath)
            }
        }

        let normalizedText = ProjectIdentityResolver.normalizedKey([request.prompt, request.userInput].joined(separator: " "))
        for path in repoMap.relevantPaths where normalizedText.contains(ProjectIdentityResolver.normalizedKey((path as NSString).lastPathComponent)) {
            add(path)
        }

        return candidates
    }

    private static func maxLines(for relativePath: String, taskProfile: CodebaseTaskProfile) -> Int {
        if relativePath.hasSuffix("package.json") || relativePath.hasSuffix("cdk.json") {
            return 120
        }
        if taskProfile == .infrastructure && CodebaseRepositoryMap.infrastructurePathForEvidence(relativePath) {
            return 140
        }
        return 90
    }

    private static func isReadableSource(_ relativePath: String) -> Bool {
        let lower = relativePath.lowercased()
        return isReadableImplementationSource(lower)
            || lower.hasSuffix(".json")
            || lower.hasSuffix(".yml")
            || lower.hasSuffix(".yaml")
            || lower.hasSuffix(".tf")
            || lower.hasSuffix(".hcl")
            || lower.hasSuffix(".md")
    }

    private static func isReadableImplementationSource(_ relativePath: String) -> Bool {
        let lower = relativePath.lowercased()
        return lower.hasSuffix(".swift")
            || lower.hasSuffix(".go")
            || lower.hasSuffix(".js")
            || lower.hasSuffix(".mjs")
            || lower.hasSuffix(".cjs")
            || lower.hasSuffix(".jsx")
            || lower.hasSuffix(".ts")
            || lower.hasSuffix(".tsx")
            || lower.hasSuffix(".vue")
            || lower.hasSuffix(".svelte")
            || lower.hasSuffix(".astro")
            || lower.hasSuffix(".py")
            || lower.hasSuffix(".rs")
            || lower.hasSuffix(".tf")
            || lower.hasSuffix(".hcl")
            || lower.hasSuffix(".sh")
            || lower.hasSuffix(".bash")
            || lower.hasSuffix(".zsh")
            || lower.hasSuffix(".sql")
    }

    private static func snippetMarkdown(path: String, contents: String, maxLines: Int) -> String {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maxLines)
            .enumerated()
            .map { index, line in "\(index + 1): \(line)" }
            .joined(separator: "\n")
        return """
        ### `\(path)`
        ```text
        \(lines)
        ```
        """
    }
}

private extension CodebaseRepositoryMap {
    static func infrastructurePathForEvidence(_ relativePath: String) -> Bool {
        infrastructurePath(relativePath)
    }
}

private extension Array where Element == CodebaseManifest {
    func sortedByPath() -> [CodebaseManifest] {
        sorted { lhs, rhs in
            lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }
}

private extension Set where Element == String {
    func sortedByPath() -> [String] {
        sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private extension Array where Element == String {
    func prefixArray(_ maxLength: Int) -> [String] {
        Array(prefix(maxLength))
    }
}
