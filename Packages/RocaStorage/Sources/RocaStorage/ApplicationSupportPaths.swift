import Foundation
import RocaCore

public struct ApplicationSupportPaths: Sendable {
    public var root: URL
    public var settingsDirectory: URL
    public var approvalsDirectory: URL
    public var logsDirectory: URL
    public var modelsDirectory: URL
    public var projectsDirectory: URL

    public init(root: URL) {
        self.root = root
        self.settingsDirectory = root.appendingPathComponent("Settings", isDirectory: true)
        self.approvalsDirectory = root.appendingPathComponent("Approvals", isDirectory: true)
        self.logsDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        self.modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
        self.projectsDirectory = root.appendingPathComponent("Projects", isDirectory: true)
    }

    public static func roca(fileManager: FileManager = .default) throws -> ApplicationSupportPaths {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RocaError.storageFailed("Application Support directory is unavailable.")
        }
        return ApplicationSupportPaths(root: base.appendingPathComponent("Roca", isDirectory: true))
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: approvalsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }
}
