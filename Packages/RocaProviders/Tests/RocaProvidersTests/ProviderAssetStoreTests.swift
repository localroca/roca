import Foundation
import RocaCore
import RocaProviders
import Testing

@Test
func providerAssetStoreInstallsAndVerifiesDefaultVoiceGroup() async throws {
    let fixture = try AssetFixture()
    defer {
        fixture.cleanup()
    }

    let manifest = fixture.manifest()
    let store = ProviderAssetStore(rootDirectory: fixture.installRoot)

    #expect(await store.status(for: manifest) == .missing)

    let installation = try await store.prepareAssets(for: manifest)

    #expect(installation.providerID == ProviderID(rawValue: "kokoro"))
    #expect(installation.modelID == "kokoro-v1.0-mlx")
    #expect(installation.installedVoiceGroupIDs == ["american-english"])
    #expect(FileManager.default.fileExists(atPath: installation.directory.appendingPathComponent("Models/kokoro-v1_0.safetensors").path))
    #expect(FileManager.default.fileExists(atPath: installation.directory.appendingPathComponent("Voices/af_heart.npy").path))

    guard case .installed(let verified) = await store.status(for: manifest) else {
        Issue.record("Expected installed asset state.")
        return
    }
    #expect(verified.directory == installation.directory)
}

@Test
func providerAssetStoreCanInstallAdditionalVoiceGroup() async throws {
    let fixture = try AssetFixture()
    defer {
        fixture.cleanup()
    }

    let manifest = fixture.manifest()
    let store = ProviderAssetStore(rootDirectory: fixture.installRoot)
    _ = try await store.prepareAssets(for: manifest)
    let installation = try await store.prepareAssets(for: manifest, voiceGroupIDs: ["british-english"])

    #expect(installation.installedVoiceGroupIDs == ["american-english", "british-english"])
    #expect(FileManager.default.fileExists(atPath: installation.directory.appendingPathComponent("Voices/bf_alice.npy").path))
}

@Test
func providerAssetStoreRejectsChecksumMismatch() async throws {
    let fixture = try AssetFixture(voiceData: Data("wrong".utf8))
    defer {
        fixture.cleanup()
    }

    let store = ProviderAssetStore(rootDirectory: fixture.installRoot)
    do {
        _ = try await store.prepareAssets(for: fixture.manifest())
        Issue.record("Expected checksum mismatch to fail install.")
    } catch {
        #expect(error.localizedDescription.contains("SHA256 mismatch"))
    }
}

private struct AssetFixture {
    let root: URL
    let sourceRoot: URL
    let installRoot: URL
    let modelURL: URL
    let americanVoiceURL: URL
    let britishVoiceURL: URL

    init(voiceData: Data = Data("voice".utf8)) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ProviderAssetStoreTests-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        installRoot = root.appendingPathComponent("install", isDirectory: true)
        modelURL = sourceRoot.appendingPathComponent("kokoro-v1_0.safetensors")
        americanVoiceURL = sourceRoot.appendingPathComponent("af_heart.npy")
        britishVoiceURL = sourceRoot.appendingPathComponent("bf_alice.npy")

        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: modelURL)
        try voiceData.write(to: americanVoiceURL)
        try Data("voice".utf8).write(to: britishVoiceURL)
    }

    func manifest() -> ProviderAssetManifest {
        ProviderAssetManifest(
            schemaVersion: ProviderAssetManifest.supportedSchemaVersion,
            providerID: ProviderID(rawValue: "kokoro"),
            providerKind: .tts,
            displayName: "Kokoro",
            modelID: "kokoro-v1.0-mlx",
            revision: "test-revision",
            files: [
                ProviderAssetFile(
                    id: "model",
                    role: .model,
                    path: "Models/kokoro-v1_0.safetensors",
                    url: modelURL,
                    sha256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4",
                    byteCount: 5,
                    required: true
                )
            ],
            voiceGroups: [
                ProviderAssetVoiceGroup(
                    id: "american-english",
                    displayName: "American English",
                    locale: "en-US",
                    defaultInstalled: true,
                    engineSupport: .supported,
                    voices: [
                        ProviderAssetVoice(
                            id: VoiceID(rawValue: "af_heart"),
                            displayName: "Heart",
                            asset: ProviderAssetFile(
                                id: "voice-af-heart",
                                role: .voice,
                                path: "Voices/af_heart.npy",
                                url: americanVoiceURL,
                                sha256: "c57d7e92019708b614c90fa3685cd644f543a60153fb99ec9b67c381a245fb2a",
                                byteCount: 5,
                                required: true
                            )
                        )
                    ]
                ),
                ProviderAssetVoiceGroup(
                    id: "british-english",
                    displayName: "British English",
                    locale: "en-GB",
                    defaultInstalled: false,
                    engineSupport: .planned,
                    voices: [
                        ProviderAssetVoice(
                            id: VoiceID(rawValue: "bf_alice"),
                            displayName: "Alice",
                            asset: ProviderAssetFile(
                                id: "voice-bf-alice",
                                role: .voice,
                                path: "Voices/bf_alice.npy",
                                url: britishVoiceURL,
                                sha256: "c57d7e92019708b614c90fa3685cd644f543a60153fb99ec9b67c381a245fb2a",
                                byteCount: 5,
                                required: true
                            )
                        )
                    ]
                )
            ]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
