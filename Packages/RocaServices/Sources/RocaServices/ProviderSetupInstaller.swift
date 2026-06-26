import Foundation
import RocaCore

public struct ProviderSetupInstallRequest: Equatable, Sendable {
    public var providerID: ProviderID
    public var displayName: String
    public var installCommand: String

    public init(providerID: ProviderID, displayName: String, installCommand: String) {
        self.providerID = providerID
        self.displayName = displayName
        self.installCommand = installCommand
    }
}

public struct ProviderSetupInstallResult: Equatable, Sendable {
    public var exitCode: Int32
    public var output: String
    public var postInstallNotes: [String]

    public init(exitCode: Int32, output: String, postInstallNotes: [String] = []) {
        self.exitCode = exitCode
        self.output = output
        self.postInstallNotes = postInstallNotes
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public protocol ProviderSetupInstalling: Sendable {
    func install(_ request: ProviderSetupInstallRequest) async throws -> ProviderSetupInstallResult
}

public struct DefaultProviderSetupInstaller: ProviderSetupInstalling {
    private static let claudeCodeInstallCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 300) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func install(_ request: ProviderSetupInstallRequest) async throws -> ProviderSetupInstallResult {
        guard request.providerID.rawValue == "claude-code",
              request.installCommand == Self.claudeCodeInstallCommand else {
            throw RocaError.approvalDenied("Unsupported provider setup command.")
        }

        var result = try await ShellProviderSetupProcess(command: request.installCommand).run(timeoutSeconds: timeoutSeconds)
        if result.succeeded {
            result.postInstallNotes.append(contentsOf: ClaudeCodePathConfigurator().ensurePathIfNeeded())
        }
        return result
    }
}

struct ClaudeCodePathConfigurator {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let shellPath: String?
    private let environmentPath: String

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        shellPath: String? = Self.defaultShellPath(),
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.shellPath = shellPath
        self.environmentPath = environmentPath
    }

    func ensurePathIfNeeded() -> [String] {
        let binURL = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        let claudeURL = binURL.appendingPathComponent("claude")
        let displayBinPath = "~/.local/bin"

        guard fileManager.fileExists(atPath: claudeURL.path) else {
            return ["Claude Code installed, but Roca could not find \(displayBinPath)/claude yet."]
        }
        if pathListContains(binURL.path, in: environmentPath) {
            return ["Claude Code is available at \(displayBinPath)/claude."]
        }
        guard let profile = shellProfile(for: shellPath) else {
            return ["Claude Code installed at \(displayBinPath)/claude. Add \(displayBinPath) to your shell PATH if Terminal cannot find `claude`."]
        }

        do {
            try appendPathBlockIfNeeded(to: profile, shellName: profile.shellName)
            return ["Added \(displayBinPath) to PATH in \(profile.displayPath). Open a new Terminal and run `claude --version`."]
        } catch {
            return ["Claude Code installed at \(displayBinPath)/claude, but Roca could not update \(profile.displayPath): \(error.localizedDescription)"]
        }
    }

    private static func defaultShellPath() -> String? {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        #if os(macOS)
        guard let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell else {
            return nil
        }
        return String(cString: shell)
        #else
        return nil
        #endif
    }

    private func pathListContains(_ path: String, in pathList: String) -> Bool {
        pathList.split(separator: ":").contains { String($0) == path }
    }

    private func shellProfile(for shellPath: String?) -> ShellProfile? {
        let shellName = shellPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        switch shellName {
        case "zsh":
            return ShellProfile(
                shellName: shellName,
                url: homeDirectory.appendingPathComponent(".zshrc"),
                displayPath: "~/.zshrc"
            )
        case "bash":
            return ShellProfile(
                shellName: shellName,
                url: homeDirectory.appendingPathComponent(".bash_profile"),
                displayPath: "~/.bash_profile"
            )
        case "fish":
            return ShellProfile(
                shellName: shellName,
                url: homeDirectory.appendingPathComponent(".config/fish/config.fish"),
                displayPath: "~/.config/fish/config.fish"
            )
        case "sh":
            return ShellProfile(
                shellName: shellName,
                url: homeDirectory.appendingPathComponent(".profile"),
                displayPath: "~/.profile"
            )
        default:
            return nil
        }
    }

    private func appendPathBlockIfNeeded(to profile: ShellProfile, shellName: String) throws {
        try fileManager.createDirectory(at: profile.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: profile.url, encoding: .utf8)) ?? ""
        if existing.contains("# >>> Roca Claude Code PATH >>>") || existing.contains(".local/bin") {
            return
        }

        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let block = pathBlock(for: shellName)
        let updated = existing + separator + block
        try updated.write(to: profile.url, atomically: true, encoding: .utf8)
    }

    private func pathBlock(for shellName: String) -> String {
        if shellName == "fish" {
            return """
            # >>> Roca Claude Code PATH >>>
            if test -d "$HOME/.local/bin"
                fish_add_path -g "$HOME/.local/bin"
            end
            # <<< Roca Claude Code PATH <<<
            """
        }

        return """
        # >>> Roca Claude Code PATH >>>
        if [ -d "$HOME/.local/bin" ]; then
          export PATH="$HOME/.local/bin:$PATH"
        fi
        # <<< Roca Claude Code PATH <<<
        """
    }

    private struct ShellProfile {
        var shellName: String
        var url: URL
        var displayPath: String
    }
}

private final class ShellProviderSetupProcess: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutBuffer = ProviderSetupOutputBuffer()
    private let stderrBuffer = ProviderSetupOutputBuffer()

    init(command: String) {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
    }

    func run(timeoutSeconds: TimeInterval) async throws -> ProviderSetupInstallResult {
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
                let output = [stdoutBuffer.stringValue, stderrBuffer.stringValue]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return ProviderSetupInstallResult(exitCode: exitCode, output: String(output.prefix(2_000)))
            } catch {
                terminate()
                throw error
            }
        } onCancel: {
            terminate()
        }
    }

    private func terminate() {
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
                try await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds) * 1_000_000_000))
                return .timedOut
            }

            let result = try await group.next()!
            group.cancelAll()
            switch result {
            case .exited(let exitCode):
                return exitCode
            case .timedOut:
                terminate()
                throw RocaError.providerTimedOut(providerID: ProviderID(rawValue: "claude-code"), modelID: "Claude Code installer")
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

private final class ProviderSetupOutputBuffer: @unchecked Sendable {
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
