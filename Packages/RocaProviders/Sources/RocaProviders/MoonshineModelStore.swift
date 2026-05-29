import Foundation
import RocaCore

public enum MoonshineModelInstallState: Equatable, Sendable {
    case missing
    case installed(MoonshineManagedModel)
    case invalid(String)

    public var isInstalled: Bool {
        guard case .installed = self else {
            return false
        }
        return true
    }
}

public struct MoonshineManagedModel: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var modelArch: MoonshineManagedModelArch
    public var directory: URL
    public var installedAt: Date?
    public var verifiedAt: Date

    public init(
        id: String,
        displayName: String,
        modelArch: MoonshineManagedModelArch,
        directory: URL,
        installedAt: Date?,
        verifiedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.modelArch = modelArch
        self.directory = directory
        self.installedAt = installedAt
        self.verifiedAt = verifiedAt
    }
}

public actor MoonshineModelStore {
    private let assetStore: ProviderAssetStore

    public init(rootDirectory: URL) {
        self.assetStore = ProviderAssetStore(rootDirectory: rootDirectory)
    }

    public var modelID: String {
        MoonshineManagedAssets.modelID
    }

    public var modelDisplayName: String {
        MoonshineManagedAssets.displayName
    }

    public func status() async -> MoonshineModelInstallState {
        do {
            let manifest = try MoonshineManagedAssets.manifest()
            switch await assetStore.status(for: manifest) {
            case .missing:
                return .missing
            case .installed(let installation):
                return .installed(model(from: installation, manifest: manifest))
            case .invalid(let message):
                return .invalid(message)
            }
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    public func prepareModel(
        progress: (@Sendable (ManagedDownloadProgress) -> Void)? = nil
    ) async throws -> MoonshineManagedModel {
        let manifest = try MoonshineManagedAssets.manifest()
        let installation = try await assetStore.prepareAssets(for: manifest, progress: progress)
        return model(from: installation, manifest: manifest)
    }

    public func record(for model: MoonshineManagedModel) -> STTModelRecord {
        STTModelRecord(
            modelID: model.id,
            displayName: model.displayName,
            localPath: model.directory.path,
            installedAt: model.installedAt ?? model.verifiedAt,
            verifiedAt: model.verifiedAt
        )
    }

    public func installedModel() async throws -> MoonshineManagedModel {
        let manifest = try MoonshineManagedAssets.manifest()
        let installation = try await assetStore.verifyInstallation(for: manifest)
        return model(from: installation, manifest: manifest)
    }

    private func model(from installation: ProviderAssetInstallation, manifest: ProviderAssetManifest) -> MoonshineManagedModel {
        return MoonshineManagedModel(
            id: manifest.modelID,
            displayName: manifest.displayName,
            modelArch: manifest.moonshineModelArch ?? MoonshineManagedAssets.modelArch,
            directory: installation.directory,
            installedAt: installation.installedAt,
            verifiedAt: installation.verifiedAt
        )
    }
}
