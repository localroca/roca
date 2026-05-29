import Foundation
import RocaCore
import RocaProviders
import Testing

@Test
func kokoroManagedAssetsAcceptsGeneratedManifest() throws {
    let manifest = try ProviderAssetManifest.load(from: kokoroManifestURL())
    try KokoroManagedAssets.validateManifest(manifest)

    let installation = ProviderAssetInstallation(
        providerID: manifest.providerID,
        modelID: manifest.modelID,
        revision: manifest.revision,
        directory: URL(fileURLWithPath: "/tmp/Roca/Kokoro"),
        installedAt: nil,
        verifiedAt: Date(),
        installedVoiceGroupIDs: manifest.defaultVoiceGroupIDs
    )

    let defaultVoiceURL = try KokoroManagedAssets.voiceURL(
        for: KokoroManagedAssets.defaultVoiceID,
        in: manifest,
        installation: installation
    )

    #expect(KokoroManagedAssets.modelURL(in: installation).path == "/tmp/Roca/Kokoro/Models/kokoro-v1_0.safetensors")
    #expect(defaultVoiceURL.path == "/tmp/Roca/Kokoro/Voices/af_heart.npy")
}

@Test
func bundledKokoroManifestMatchesCheckedInCatalog() throws {
    let bundled = try KokoroManagedAssets.bundledManifest()
    let checkedIn = try ProviderAssetManifest.load(from: kokoroManifestURL())

    #expect(bundled.providerID == checkedIn.providerID)
    #expect(bundled.modelID == checkedIn.modelID)
    #expect(bundled.revision == checkedIn.revision)
    #expect(bundled.files == checkedIn.files)
    #expect(bundled.voiceGroups == checkedIn.voiceGroups)
}

@Test
func kokoroManagedAssetsRejectsWrongProviderID() throws {
    var manifest = try ProviderAssetManifest.load(from: kokoroManifestURL())
    manifest.providerID = ProviderID(rawValue: "other")

    do {
        try KokoroManagedAssets.validateManifest(manifest)
        Issue.record("Expected Kokoro manifest validation to fail.")
    } catch RocaError.assetManifestInvalid(let message) {
        #expect(message.contains("providerID"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func kokoroManifestURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("templates/provider-assets/kokoro-mlx.json")
}
