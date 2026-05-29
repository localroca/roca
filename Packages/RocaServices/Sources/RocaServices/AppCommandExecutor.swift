import AppKit
import Foundation
import RocaCore

public enum ApplicationCommand: Equatable, Sendable {
    case open(ApplicationCommandTarget)
    case quit(ApplicationCommandTarget)
}

public enum ApplicationCommandExecutionResult: Equatable, Sendable {
    case opened(ApplicationMatch)
    case quit(ApplicationMatch)
    case notRunning(ApplicationCommandTarget)
    case notFound(ApplicationCommandTarget)
    case ambiguous([ApplicationMatch])
    case failed(String)

    public var spokenSummary: String {
        switch self {
        case .opened(let match):
            "Opened \(match.displayName)."
        case .quit(let match):
            "Quit \(match.displayName)."
        case .notRunning(let target):
            "\(target.displayName) is not running."
        case .notFound(let target):
            "I could not find \(target.displayName)."
        case .ambiguous(let matches):
            "I found multiple matches: \(matches.map(\.displayName).joined(separator: ", ")). Which one did you mean?"
        case .failed(let message):
            message
        }
    }
}

public struct ApplicationMatch: Equatable, Identifiable, Sendable {
    public var id: String { bundleID ?? url.path }
    public var displayName: String
    public var bundleID: String?
    public var url: URL

    public init(displayName: String, bundleID: String?, url: URL) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.url = url
    }
}

public protocol ApplicationCommandExecuting: Sendable {
    func execute(_ command: ApplicationCommand) async -> ApplicationCommandExecutionResult
}

public final class DefaultApplicationCommandExecutor: ApplicationCommandExecuting, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func execute(_ command: ApplicationCommand) async -> ApplicationCommandExecutionResult {
        switch command {
        case .open(let target):
            await open(target)
        case .quit(let target):
            await quit(target)
        }
    }

    @MainActor
    private func open(_ target: ApplicationCommandTarget) async -> ApplicationCommandExecutionResult {
        let matches = resolveInstalledApplications(target)
        guard !matches.isEmpty else {
            return .notFound(target)
        }
        guard matches.count == 1, let match = matches.first else {
            return .ambiguous(matches)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: match.url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(
                        returning: .failed("I could not open \(match.displayName): \(error.localizedDescription)")
                    )
                    return
                }
                continuation.resume(returning: .opened(match))
            }
        }
    }

    @MainActor
    private func quit(_ target: ApplicationCommandTarget) -> ApplicationCommandExecutionResult {
        let runningMatches = resolveRunningApplications(target)
        guard !runningMatches.isEmpty else {
            return .notRunning(target)
        }
        guard runningMatches.count == 1, let app = runningMatches.first else {
            let matches = appMatches(from: runningMatches)
            return .ambiguous(matches)
        }

        let match = appMatch(from: app)
        if app.terminate() {
            return .quit(match)
        }
        return .failed("I could not quit \(match.displayName).")
    }

    @MainActor
    private func resolveRunningApplications(_ target: ApplicationCommandTarget) -> [NSRunningApplication] {
        if let bundleID = normalized(target.bundleID) {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }

        guard let requestedName = normalized(target.appName) else {
            return []
        }
        let exact = NSWorkspace.shared.runningApplications.filter { app in
            normalized(app.localizedName) == requestedName
        }
        if !exact.isEmpty {
            return exact
        }
        return NSWorkspace.shared.runningApplications.filter { app in
            normalized(app.localizedName)?.contains(requestedName) == true
        }
    }

    @MainActor
    private func resolveInstalledApplications(_ target: ApplicationCommandTarget) -> [ApplicationMatch] {
        if let bundleID = target.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return [applicationMatch(url: url)]
        }

        guard let requestedName = normalized(target.appName) else {
            return []
        }
        let applications = applicationURLs()
        let exact = applications.filter { normalized(displayName(for: $0)) == requestedName }
        let matches = exact.isEmpty
            ? applications.filter { normalized(displayName(for: $0))?.contains(requestedName) == true }
            : exact
        return matches.map(applicationMatch(url:))
    }

    private func applicationURLs() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var urls: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                urls.append(url)
            }
        }
        return urls
    }

    private func applicationMatch(url: URL) -> ApplicationMatch {
        let bundle = Bundle(url: url)
        return ApplicationMatch(
            displayName: displayName(for: url),
            bundleID: bundle?.bundleIdentifier,
            url: url
        )
    }

    private func appMatches(from apps: [NSRunningApplication]) -> [ApplicationMatch] {
        apps.map(appMatch(from:))
    }

    private func appMatch(from app: NSRunningApplication) -> ApplicationMatch {
        ApplicationMatch(
            displayName: app.localizedName ?? app.bundleIdentifier ?? "App",
            bundleID: app.bundleIdentifier,
            url: app.bundleURL ?? URL(fileURLWithPath: "/")
        )
    }

    private func displayName(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
