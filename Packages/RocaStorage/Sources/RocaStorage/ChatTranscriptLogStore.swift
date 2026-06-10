import Foundation
import RocaCore

public struct ChatTranscriptLogEntry: Codable, Equatable, Sendable {
    public var loggedAt: Date
    public var message: ChatMessage

    public init(loggedAt: Date = Date(), message: ChatMessage) {
        self.loggedAt = loggedAt
        self.message = message
    }
}

public struct ChatTranscriptLogFileInfo: Equatable, Sendable {
    public var exists: Bool
    public var byteCount: Int64
    public var rowCount: Int
    public var modifiedAt: Date?

    public init(exists: Bool, byteCount: Int64, rowCount: Int, modifiedAt: Date?) {
        self.exists = exists
        self.byteCount = byteCount
        self.rowCount = rowCount
        self.modifiedAt = modifiedAt
    }

    public static let missing = ChatTranscriptLogFileInfo(
        exists: false,
        byteCount: 0,
        rowCount: 0,
        modifiedAt: nil
    )
}

public actor ChatTranscriptLogStore {
    public nonisolated let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(logsDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = logsDirectory.appendingPathComponent("assistant_chat_transcript.jsonl")
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ message: ChatMessage) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = try encoder.encode(ChatTranscriptLogEntry(message: message))
        data.append(0x0A)

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func recent(limit: Int) throws -> [ChatTranscriptLogEntry] {
        guard limit > 0,
              fileManager.fileExists(atPath: fileURL.path)
        else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            return []
        }

        return contents
            .split(separator: "\n")
            .reversed()
            .prefix(limit)
            .compactMap { line in
                try? decoder.decode(ChatTranscriptLogEntry.self, from: Data(line.utf8))
            }
    }

    public func fileInfo() throws -> ChatTranscriptLogFileInfo {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date
        return ChatTranscriptLogFileInfo(
            exists: true,
            byteCount: byteCount,
            rowCount: try rowCount(),
            modifiedAt: modifiedAt
        )
    }

    public func export(to destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw RocaError.storageFailed("Chat transcript log does not exist.")
        }

        let source = fileURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source.path != destination.path else {
            return
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    public func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func rowCount() throws -> Int {
        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            return 0
        }
        return contents.split(separator: "\n").count
    }
}
