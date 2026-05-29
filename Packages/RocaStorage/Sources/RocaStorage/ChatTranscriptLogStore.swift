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
}
