import Foundation
import RocaCore

public actor AssistantTurnMetricsLogStore {
    public nonisolated let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(logsDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = logsDirectory.appendingPathComponent("assistant_turn_metrics.jsonl")
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ metrics: AssistantTurnMetrics) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = try encoder.encode(metrics)
        data.append(0x0A)

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func recent(limit: Int) throws -> [AssistantTurnMetrics] {
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
                try? decoder.decode(AssistantTurnMetrics.self, from: Data(line.utf8))
            }
    }
}
