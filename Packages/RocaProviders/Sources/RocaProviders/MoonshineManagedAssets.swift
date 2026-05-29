import Foundation
import RocaCore

public enum MoonshineManagedAssets {
    public static let providerID = BuiltInProviderIDs.moonshineSTT
    public static let modelID = "medium-streaming-en"
    public static let displayName = "Moonshine"
    public static let modelArch = MoonshineManagedModelArch.mediumStreaming
    public static let revision = "moonshine-voice-0.0.60-medium-streaming-en-quantized"
    public static let manifestResourceName = "moonshine-medium-streaming-en"

    public static let requiredFiles = [
        "frontend.ort",
        "encoder.ort",
        "adapter.ort",
        "decoder_kv.ort",
        "decoder_kv_with_attention.ort",
        "cross_kv.ort",
        "streaming_config.json",
        "tokenizer.bin"
    ]

    public static func manifest() throws -> ProviderAssetManifest {
        guard let url = Bundle.module.url(forResource: manifestResourceName, withExtension: "json") else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest \(manifestResourceName).json is missing.")
        }
        let manifest = try ProviderAssetManifest.load(from: url)
        try validateManifest(manifest)
        return manifest
    }

    public static func validateManifest(_ manifest: ProviderAssetManifest) throws {
        try manifest.validate()

        guard manifest.providerID == providerID else {
            throw RocaError.assetManifestInvalid(
                "Moonshine asset manifest providerID must be \(providerID.rawValue)."
            )
        }
        guard manifest.providerKind == .stt else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest must describe an STT provider.")
        }
        guard manifest.modelID == modelID else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest modelID must be \(modelID).")
        }
        guard manifest.revision == revision else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest revision must be \(revision).")
        }
        guard manifest.moonshineModelArch == modelArch else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest modelArch must be \(modelArch.rawValue).")
        }

        let manifestPaths = Set(manifest.files.map(\.path))
        let requiredPaths = Set(requiredFiles)
        guard manifestPaths == requiredPaths else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest file set is incomplete.")
        }
        guard manifest.files.allSatisfy({ $0.required }) else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest files must all be required.")
        }
        guard manifest.voiceGroups.isEmpty else {
            throw RocaError.assetManifestInvalid("Moonshine asset manifest must not include voice groups.")
        }
    }
}

public enum MoonshineManagedModelArch: String, Codable, Equatable, Sendable {
    case tiny
    case base
    case tinyStreaming
    case baseStreaming
    case smallStreaming
    case mediumStreaming
}

extension ProviderAssetManifest {
    public var moonshineModelArch: MoonshineManagedModelArch? {
        runtime?.modelArch.flatMap(MoonshineManagedModelArch.init(rawValue:))
    }
}
