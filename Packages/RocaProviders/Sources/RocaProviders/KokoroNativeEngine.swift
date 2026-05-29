import Foundation
import KokoroSwift
import Metal
import MLX
import MLXUtilsLibrary
import RocaCore

actor KokoroNativeEngine {
    private var tts: KokoroTTS?
    private var loadedModelPath: String?
    private var warmedModelPath: String?
    private var voiceCache: [VoiceID: MLXArray] = [:]

    func prepare(manifest: ProviderAssetManifest, installation: ProviderAssetInstallation) throws {
        let modelURL = KokoroManagedAssets.modelURL(in: installation)
        guard loadedModelPath != modelURL.path || tts == nil else {
            try warmupIfNeeded(manifest: manifest, installation: installation)
            return
        }

        guard MTLCreateSystemDefaultDevice() != nil else {
            throw RocaError.synthesisFailed("Kokoro requires an available Metal device.")
        }

        try KokoroModelPreflight.validateModel(at: modelURL)
        tts = KokoroTTS(modelPath: modelURL, g2p: .misaki)
        loadedModelPath = modelURL.path
        warmedModelPath = nil
        voiceCache.removeAll(keepingCapacity: true)
        try warmupIfNeeded(manifest: manifest, installation: installation)
    }

    func synthesize(
        _ request: TTSRequest,
        manifest: ProviderAssetManifest,
        installation: ProviderAssetInstallation
    ) throws -> Data {
        try prepare(manifest: manifest, installation: installation)

        guard request.format.encoding == .wav else {
            throw RocaError.synthesisFailed("Kokoro only supports WAV output.")
        }
        guard request.speed >= 0.25, request.speed <= 4.0 else {
            throw RocaError.synthesisFailed("Kokoro speed must be between 0.25x and 4.0x.")
        }
        guard let tts else {
            throw RocaError.synthesisFailed("Kokoro engine did not initialize.")
        }

        let voiceID = request.voice ?? KokoroManagedAssets.defaultVoiceID
        let loadedVoice = try voice(voiceID, manifest: manifest, installation: installation)

        do {
            let (samples, _) = try tts.generateAudio(
                voice: loadedVoice,
                language: Self.language(for: voiceID),
                text: request.text,
                speed: Float(request.speed)
            )
            return KokoroWAVWriter.encode(samples: samples)
        } catch KokoroTTS.KokoroTTSError.tooManyTokens {
            throw RocaError.synthesisFailed("Selected text is too long for Kokoro. Try a shorter selection.")
        } catch {
            throw RocaError.synthesisFailed("Kokoro synthesis failed: \(error.localizedDescription)")
        }
    }

    private func voice(
        _ voiceID: VoiceID,
        manifest: ProviderAssetManifest,
        installation: ProviderAssetInstallation
    ) throws -> MLXArray {
        if let cachedVoice = voiceCache[voiceID] {
            return cachedVoice
        }

        guard let group = KokoroManagedAssets.voiceGroup(containing: voiceID, in: manifest) else {
            throw RocaError.synthesisFailed("Unknown Kokoro voice \(voiceID.rawValue).")
        }
        guard installation.installedVoiceGroupIDs.contains(group.id) else {
            throw RocaError.synthesisFailed("\(group.displayName) is not downloaded.")
        }

        let voiceURL = try KokoroManagedAssets.voiceURL(for: voiceID, in: manifest, installation: installation)
        guard let loadedVoice = NpyzReader.read(fileFromPath: voiceURL, isPacked: false)?.values.first else {
            throw RocaError.synthesisFailed("Unable to load Kokoro voice \(voiceID.rawValue).")
        }

        voiceCache[voiceID] = loadedVoice
        return loadedVoice
    }

    private func warmupIfNeeded(
        manifest: ProviderAssetManifest,
        installation: ProviderAssetInstallation
    ) throws {
        guard warmedModelPath != loadedModelPath else {
            return
        }
        guard let tts else {
            throw RocaError.synthesisFailed("Kokoro engine did not initialize.")
        }

        let defaultVoiceID = KokoroManagedAssets.defaultVoiceID
        let defaultVoice = try voice(defaultVoiceID, manifest: manifest, installation: installation)
        do {
            _ = try tts.generateAudio(
                voice: defaultVoice,
                language: Self.language(for: defaultVoiceID),
                text: "Warmup.",
                speed: 1.0
            )
            warmedModelPath = loadedModelPath
        } catch {
            throw RocaError.synthesisFailed("Kokoro warmup failed: \(error.localizedDescription)")
        }
    }

    private static func language(for voiceID: VoiceID) -> Language {
        voiceID.rawValue.hasPrefix("b") ? .enGB : .enUS
    }
}
