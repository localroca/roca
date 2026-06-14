import Foundation
import RocaCore

public actor JSONProjectIdentityStore: ProjectIdentityCatalog, ProjectIdentityWriting {
    public let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func phaseOneDefault(paths: ApplicationSupportPaths) -> JSONProjectIdentityStore {
        JSONProjectIdentityStore(fileURL: paths.projectsDirectory.appendingPathComponent("projects.json"))
    }

    public func projects() async throws -> [ProjectIdentity] {
        try await load()
    }

    public func load() async throws -> [ProjectIdentity] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let disk = try decoder.decode(ProjectIdentityStoreDisk.self, from: data)
            return Self.sorted(disk.projects)
        } catch {
            throw RocaError.storageFailed(error.localizedDescription)
        }
    }

    public func save(_ projects: [ProjectIdentity]) async throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(ProjectIdentityStoreDisk(projects: Self.sorted(projects)))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw RocaError.storageFailed(error.localizedDescription)
        }
    }

    public func upsert(_ project: ProjectIdentity) async throws {
        var projects = try await load()
        projects.removeAll { existing in
            existing.id == project.id
                || ProjectIdentityResolver.normalizedKey(existing.localPath)
                    == ProjectIdentityResolver.normalizedKey(project.localPath)
        }
        projects.append(project)
        try await save(projects)
    }

    private static func sorted(_ projects: [ProjectIdentity]) -> [ProjectIdentity] {
        projects.sorted {
            if $0.displayName != $1.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.localPath < $1.localPath
        }
    }
}

private struct ProjectIdentityStoreDisk: Codable {
    var projects: [ProjectIdentity]
}
