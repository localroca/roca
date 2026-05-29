import CryptoKit
import Foundation
import RocaCore

public enum ProviderAssetInstallState: Equatable, Sendable {
    case missing
    case installed(ProviderAssetInstallation)
    case invalid(String)
}

public struct ProviderAssetInstallation: Equatable, Sendable {
    public var providerID: ProviderID
    public var modelID: String
    public var revision: String
    public var directory: URL
    public var installedAt: Date?
    public var verifiedAt: Date
    public var installedVoiceGroupIDs: [String]

    public init(
        providerID: ProviderID,
        modelID: String,
        revision: String,
        directory: URL,
        installedAt: Date?,
        verifiedAt: Date,
        installedVoiceGroupIDs: [String]
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.revision = revision
        self.directory = directory
        self.installedAt = installedAt
        self.verifiedAt = verifiedAt
        self.installedVoiceGroupIDs = installedVoiceGroupIDs
    }
}

public actor ProviderAssetStore {
    private let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    public func status(
        for manifest: ProviderAssetManifest,
        voiceGroupIDs: Set<String>? = nil
    ) -> ProviderAssetInstallState {
        do {
            return .installed(try verifyInstallation(for: manifest, voiceGroupIDs: voiceGroupIDs))
        } catch ProviderAssetStoreError.missing {
            return .missing
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    public func prepareAssets(
        for manifest: ProviderAssetManifest,
        voiceGroupIDs: Set<String>? = nil,
        progress: (@Sendable (ManagedDownloadProgress) -> Void)? = nil
    ) async throws -> ProviderAssetInstallation {
        if case .installed(let installation) = status(for: manifest, voiceGroupIDs: voiceGroupIDs) {
            return installation
        }
        return try await installAssets(for: manifest, voiceGroupIDs: voiceGroupIDs, progress: progress)
    }

    public func installAssets(
        for manifest: ProviderAssetManifest,
        voiceGroupIDs: Set<String>? = nil,
        progress: (@Sendable (ManagedDownloadProgress) -> Void)? = nil
    ) async throws -> ProviderAssetInstallation {
        try manifest.validate()
        let entries = try installEntries(for: manifest, voiceGroupIDs: voiceGroupIDs)
        let targetDirectory = installDirectory(for: manifest)
        var existingSources: [String: URL] = [:]
        var entriesToFetch: [ProviderAssetStoreEntry] = []

        for entry in entries {
            let destinationURL = try resolvedURL(for: entry.path, in: targetDirectory)
            if fileManager.fileExists(atPath: destinationURL.path),
               (try? verify(entry: entry, at: destinationURL)) != nil
            {
                existingSources[entry.path] = destinationURL
            } else {
                entriesToFetch.append(entry)
            }
        }

        let totalBytes = entriesToFetch.allSatisfy { $0.byteCount != nil }
            ? entriesToFetch.reduce(Int64(0)) { $0 + Int64($1.byteCount ?? 0) }
            : nil
        let progressTracker = ManagedDownloadProgressTracker(
            totalItems: entriesToFetch.count,
            totalBytes: totalBytes,
            progress: progress
        )
        let temporaryDirectory = rootDirectory
            .appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        for entry in entries {
            let temporaryURL = try resolvedURL(for: entry.path, in: temporaryDirectory)
            try fileManager.createDirectory(at: temporaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sourceURL: URL
            if let existingSource = existingSources[entry.path] {
                sourceURL = existingSource
            } else {
                progressTracker.startItem(entry.id, expectedBytes: entry.byteCount.map(Int64.init))
                sourceURL = try await fetchedAssetURL(for: entry, progressTracker: progressTracker)
                let finalBytes = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                progressTracker.finishCurrentItem(finalBytes: finalBytes)
            }
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try fileManager.removeItem(at: temporaryURL)
            }
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            try verify(entry: entry, at: temporaryURL)
        }

        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        for entry in entries {
            let temporaryURL = try resolvedURL(for: entry.path, in: temporaryDirectory)
            let destinationURL = try resolvedURL(for: entry.path, in: targetDirectory)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: temporaryURL, to: destinationURL)
        }

        try writeInstallMarker(for: manifest, voiceGroupIDs: requestedVoiceGroupIDs(for: manifest, voiceGroupIDs: voiceGroupIDs))
        return try verifyInstallation(for: manifest, voiceGroupIDs: voiceGroupIDs)
    }

    public func verifyInstallation(
        for manifest: ProviderAssetManifest,
        voiceGroupIDs: Set<String>? = nil
    ) throws -> ProviderAssetInstallation {
        try manifest.validate()
        let entries = try installEntries(for: manifest, voiceGroupIDs: voiceGroupIDs)
        let directory = installDirectory(for: manifest)
        for entry in entries {
            let fileURL = try resolvedURL(for: entry.path, in: directory)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw ProviderAssetStoreError.missing
            }
            try verify(entry: entry, at: fileURL)
        }

        let marker = try readInstallMarker(for: manifest)
        let requestedGroups = requestedVoiceGroupIDs(for: manifest, voiceGroupIDs: voiceGroupIDs)
        let installedGroups = Array(Set((marker?.installedVoiceGroupIDs ?? []) + requestedGroups)).sorted()
        return ProviderAssetInstallation(
            providerID: manifest.providerID,
            modelID: manifest.modelID,
            revision: manifest.revision,
            directory: directory,
            installedAt: marker?.installedAt,
            verifiedAt: Date(),
            installedVoiceGroupIDs: installedGroups
        )
    }

    private func fetchedAssetURL(
        for entry: ProviderAssetStoreEntry,
        progressTracker: ManagedDownloadProgressTracker
    ) async throws -> URL {
        if let bundlePath = entry.bundlePath,
           let bundledURL = bundledAssetURL(for: bundlePath),
           fileManager.fileExists(atPath: bundledURL.path)
        {
            return bundledURL
        }

        if entry.url.isFileURL {
            guard fileManager.fileExists(atPath: entry.url.path) else {
                throw ProviderAssetStoreError.missing
            }
            return entry.url
        }

        let (downloadedURL, response) = try await downloadRemoteFile(from: entry.url) { writtenBytes, expectedBytes in
            progressTracker.updateCurrentItem(completedBytes: writtenBytes, expectedBytes: expectedBytes)
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw RocaError.assetInstallFailed("Download status \(http.statusCode) for \(entry.id).")
        }
        return downloadedURL
    }

    private func bundledAssetURL(for bundlePath: String) -> URL? {
        Bundle.module.resourceURL?.appendingPathComponent(bundlePath)
    }

    private func installEntries(
        for manifest: ProviderAssetManifest,
        voiceGroupIDs: Set<String>?
    ) throws -> [ProviderAssetStoreEntry] {
        let requiredFiles = manifest.files
            .filter(\.required)
            .map(ProviderAssetStoreEntry.init(asset:))

        let groupIDs = requestedVoiceGroupIDs(for: manifest, voiceGroupIDs: voiceGroupIDs)
        let voiceFiles = try groupIDs.flatMap { groupID -> [ProviderAssetStoreEntry] in
            guard let group = manifest.voiceGroup(id: groupID) else {
                throw RocaError.assetManifestInvalid("Unknown voice group \(groupID).")
            }
            return group.voices.map { ProviderAssetStoreEntry(asset: $0.asset) }
        }

        return requiredFiles + voiceFiles
    }

    private func requestedVoiceGroupIDs(for manifest: ProviderAssetManifest, voiceGroupIDs: Set<String>?) -> [String] {
        let groupIDs = voiceGroupIDs ?? Set(manifest.defaultVoiceGroupIDs)
        return groupIDs.sorted()
    }

    private func verify(entry: ProviderAssetStoreEntry, at fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > 0 else {
            throw ProviderAssetStoreError.invalid("\(entry.id) is empty.")
        }
        if let byteCount = entry.byteCount, values.fileSize != byteCount {
            throw ProviderAssetStoreError.invalid(
                "\(entry.id) byte count mismatch: expected \(byteCount), got \(values.fileSize ?? 0)."
            )
        }
        let actualHash = try sha256Hex(for: fileURL)
        guard actualHash == entry.sha256 else {
            throw ProviderAssetStoreError.invalid("\(entry.id) SHA256 mismatch.")
        }
    }

    private func sha256Hex(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func resolvedURL(for relativePath: String, in directory: URL) throws -> URL {
        try ProviderAssetFile.validateRelativePath(relativePath, label: relativePath)
        return directory.appendingPathComponent(relativePath)
    }

    private func installDirectory(for manifest: ProviderAssetManifest) -> URL {
        rootDirectory
            .appendingPathComponent(safePathComponent(manifest.providerID.rawValue), isDirectory: true)
            .appendingPathComponent(safePathComponent(manifest.modelID), isDirectory: true)
            .appendingPathComponent(safePathComponent(manifest.revision), isDirectory: true)
    }

    private func safePathComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func writeInstallMarker(for manifest: ProviderAssetManifest, voiceGroupIDs: [String]) throws {
        let existing = (try? readInstallMarker(for: manifest))?.installedVoiceGroupIDs ?? []
        let marker = ProviderAssetInstallMarker(
            schemaVersion: ProviderAssetManifest.supportedSchemaVersion,
            providerID: manifest.providerID.rawValue,
            modelID: manifest.modelID,
            revision: manifest.revision,
            installedAt: Date(),
            installedVoiceGroupIDs: Array(Set(existing + voiceGroupIDs)).sorted()
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: installDirectory(for: manifest).appendingPathComponent(".roca-assets.json"), options: [.atomic])
    }

    private func readInstallMarker(for manifest: ProviderAssetManifest) throws -> ProviderAssetInstallMarker? {
        let markerURL = installDirectory(for: manifest).appendingPathComponent(".roca-assets.json")
        guard fileManager.fileExists(atPath: markerURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: markerURL)
        return try JSONDecoder().decode(ProviderAssetInstallMarker.self, from: data)
    }
}

private struct ProviderAssetStoreEntry: Sendable {
    var id: String
    var path: String
    var url: URL
    var bundlePath: String?
    var sha256: String
    var byteCount: Int?

    init(asset: ProviderAssetFile) {
        self.id = asset.id
        self.path = asset.path
        self.url = asset.url
        self.bundlePath = asset.bundlePath
        self.sha256 = asset.sha256
        self.byteCount = asset.byteCount
    }
}

private struct ProviderAssetInstallMarker: Codable, Sendable {
    var schemaVersion: String
    var providerID: String
    var modelID: String
    var revision: String
    var installedAt: Date
    var installedVoiceGroupIDs: [String]
}

private enum ProviderAssetStoreError: LocalizedError {
    case missing
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            "Provider assets are not installed."
        case .invalid(let message):
            "Provider assets invalid: \(message)"
        }
    }
}
