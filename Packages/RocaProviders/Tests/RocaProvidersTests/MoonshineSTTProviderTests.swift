import Foundation
import RocaCore
import RocaProviders
import Testing

@Test
func moonshineProviderRequiresDownloadedModel() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("MoonshineSTTProviderTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let provider = MoonshineSTTProvider(modelStore: MoonshineModelStore(rootDirectory: root))

    await #expect(throws: RocaError.assetInstallFailed("Moonshine is not installed. Download it in Providers settings.")) {
        try await provider.prepare()
    }
}

@Test
func moonshineManagedAssetsAcceptsBundledManifest() throws {
    let manifest = try MoonshineManagedAssets.manifest()
    try MoonshineManagedAssets.validateManifest(manifest)

    #expect(manifest.providerID == BuiltInProviderIDs.moonshineSTT)
    #expect(manifest.providerKind == .stt)
    #expect(manifest.modelID == MoonshineManagedAssets.modelID)
    #expect(manifest.revision == MoonshineManagedAssets.revision)
    #expect(manifest.moonshineModelArch == MoonshineManagedAssets.modelArch)
    #expect(manifest.files.map(\.path).sorted() == MoonshineManagedAssets.requiredFiles.sorted())
    #expect(manifest.voiceGroups.isEmpty)
    #expect(manifest.files.allSatisfy { $0.bundlePath == nil })
}

@Test
func bundledMoonshineManifestMatchesCheckedInCatalog() throws {
    let bundled = try MoonshineManagedAssets.manifest()
    let checkedIn = try ProviderAssetManifest.load(from: moonshineManifestURL())

    #expect(bundled.providerID == checkedIn.providerID)
    #expect(bundled.modelID == checkedIn.modelID)
    #expect(bundled.revision == checkedIn.revision)
    #expect(bundled.runtime == checkedIn.runtime)
    #expect(bundled.files == checkedIn.files)
    #expect(bundled.voiceGroups == checkedIn.voiceGroups)
}

private func moonshineManifestURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("templates/provider-assets/\(MoonshineManagedAssets.manifestResourceName).json")
}
