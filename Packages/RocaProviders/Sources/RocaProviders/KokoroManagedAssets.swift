import Foundation
import RocaCore

public enum KokoroManagedAssets {
    public static let providerID = BuiltInProviderIDs.kokoroNative
    public static let displayName = "Kokoro"
    public static let modelID = "kokoro-v1.0-mlx"
    public static let revision = "98623f832fc74ac3e2eaf2074171af7ac364b183"
    public static let defaultVoiceID = VoiceID(rawValue: "af_heart")
    public static let modelRelativePath = "Models/kokoro-v1_0.safetensors"

    public static func bundledManifest() throws -> ProviderAssetManifest {
        guard let url = Bundle.module.url(forResource: "kokoro-mlx", withExtension: "json") else {
            throw RocaError.assetManifestInvalid("Bundled Kokoro asset manifest is missing.")
        }
        let manifest = try ProviderAssetManifest.load(from: url)
        try validateManifest(manifest)
        return manifest
    }

    public static func validateManifest(_ manifest: ProviderAssetManifest) throws {
        try manifest.validate()

        guard manifest.providerID == providerID else {
            throw RocaError.assetManifestInvalid(
                "Kokoro asset manifest providerID must be \(providerID.rawValue)."
            )
        }
        guard manifest.providerKind == .tts else {
            throw RocaError.assetManifestInvalid("Kokoro asset manifest must describe a TTS provider.")
        }
        guard manifest.modelID == modelID else {
            throw RocaError.assetManifestInvalid("Kokoro asset manifest modelID must be \(modelID).")
        }
        guard manifest.revision == revision else {
            throw RocaError.assetManifestInvalid("Kokoro asset manifest revision must be \(revision).")
        }
        guard manifest.files.contains(where: { $0.role == .model && $0.path == modelRelativePath }) else {
            throw RocaError.assetManifestInvalid("Kokoro asset manifest is missing \(modelRelativePath).")
        }
        _ = try defaultVoice(in: manifest)
    }

    public static func modelURL(in installation: ProviderAssetInstallation) -> URL {
        installation.directory.appendingPathComponent(modelRelativePath)
    }

    public static func voiceURL(
        for voiceID: VoiceID,
        in manifest: ProviderAssetManifest,
        installation: ProviderAssetInstallation
    ) throws -> URL {
        guard let voice = voice(in: manifest, voiceID: voiceID) else {
            throw RocaError.assetManifestInvalid("Unknown Kokoro voice \(voiceID.rawValue).")
        }
        return installation.directory.appendingPathComponent(voice.asset.path)
    }

    public static func defaultVoice(in manifest: ProviderAssetManifest) throws -> ProviderAssetVoice {
        guard let voice = voice(in: manifest, voiceID: defaultVoiceID) else {
            throw RocaError.assetManifestInvalid("Kokoro asset manifest is missing default voice \(defaultVoiceID.rawValue).")
        }
        return voice
    }

    public static func voice(in manifest: ProviderAssetManifest, voiceID: VoiceID) -> ProviderAssetVoice? {
        manifest.voiceGroups.lazy
            .flatMap(\.voices)
            .first { $0.id == voiceID }
    }

    public static func voiceGroup(containing voiceID: VoiceID, in manifest: ProviderAssetManifest) -> ProviderAssetVoiceGroup? {
        manifest.voiceGroups.first { group in
            group.voices.contains { $0.id == voiceID }
        }
    }
}
