import Foundation
import RocaCore

public actor JSONApprovalStore: ApprovalStoring {
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

    public static func phaseOneDefault(paths: ApplicationSupportPaths) -> JSONApprovalStore {
        JSONApprovalStore(fileURL: paths.approvalsDirectory.appendingPathComponent("approvals.json"))
    }

    public func load() async throws -> [ApprovalRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let disk = try decoder.decode(ApprovalStoreDisk.self, from: data)
            return disk.approvals
        } catch {
            throw RocaError.storageFailed(error.localizedDescription)
        }
    }

    public func save(_ approvals: [ApprovalRecord]) async throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(ApprovalStoreDisk(approvals: Self.sortedApprovals(approvals)))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw RocaError.storageFailed(error.localizedDescription)
        }
    }

    public func revoke(_ approvalID: ApprovalID) async throws {
        let approvals = try await load()
        let keptApprovals = approvals.filter { $0.id != approvalID }
        try await save(keptApprovals)
    }

    public func revokeAll() async throws {
        try await save([])
    }

    private static func sortedApprovals(_ approvals: [ApprovalRecord]) -> [ApprovalRecord] {
        approvals.sorted {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            if $0.title != $1.title {
                return $0.title < $1.title
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }
}

private struct ApprovalStoreDisk: Codable {
    var approvals: [ApprovalRecord]
}
