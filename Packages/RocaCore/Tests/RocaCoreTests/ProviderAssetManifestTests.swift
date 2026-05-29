import Foundation
import RocaCore
import Testing

@Test
func providerAssetManifestDecodesAndFindsDefaultVoiceGroups() throws {
    let manifest = try JSONDecoder().decode(ProviderAssetManifest.self, from: Data(assetManifestJSON.utf8))
    try manifest.validate()

    #expect(manifest.schemaVersion == ProviderAssetManifest.supportedSchemaVersion)
    #expect(manifest.providerID == ProviderID(rawValue: "kokoro"))
    #expect(manifest.providerKind == .tts)
    #expect(manifest.runtime?.engine == "kokoro-swift")
    #expect(manifest.runtime?.modelArch == "mlx")
    #expect(manifest.defaultVoiceGroupIDs == ["american-english"])
    #expect(manifest.voiceGroup(id: "british-english")?.engineSupport == .planned)
}

@Test
func kokoroMLXTemplateDecodesGeneratedAssetCatalog() throws {
    let manifestURL = repositoryRoot()
        .appendingPathComponent("templates/provider-assets/kokoro-mlx.json")
    let manifest = try ProviderAssetManifest.load(from: manifestURL)

    #expect(manifest.providerID == ProviderID(rawValue: "kokoro"))
    #expect(manifest.providerKind == .tts)
    #expect(manifest.modelID == "kokoro-v1.0-mlx")
    #expect(manifest.revision == "98623f832fc74ac3e2eaf2074171af7ac364b183")
    #expect(manifest.files.count == 1)
    #expect(manifest.voiceGroups.count == 9)
    #expect(manifest.voiceGroups.flatMap(\.voices).count == 54)
    #expect(manifest.defaultVoiceGroupIDs == ["american-english"])
    #expect(manifest.voiceGroup(id: "american-english")?.voices.count == 20)
}

@Test
func providerAssetManifestRejectsPathTraversal() throws {
    var manifest = try JSONDecoder().decode(ProviderAssetManifest.self, from: Data(assetManifestJSON.utf8))
    manifest.files[0].path = "../Models/kokoro.safetensors"

    do {
        try manifest.validate()
        Issue.record("Expected path traversal manifest to fail validation.")
    } catch RocaError.assetManifestInvalid(let message) {
        #expect(message.contains("path must not contain"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private let assetManifestJSON = """
{
  "schemaVersion": "0.1.0",
  "providerID": "kokoro",
  "providerKind": "tts",
  "displayName": "Kokoro",
  "modelID": "kokoro-v1.0-mlx",
  "revision": "test-revision",
  "runtime": {
    "engine": "kokoro-swift",
    "modelArch": "mlx"
  },
  "files": [
    {
      "id": "model",
      "role": "model",
      "path": "Models/kokoro-v1_0.safetensors",
      "url": "https://example.com/kokoro-v1_0.safetensors",
      "bundlePath": "Bundled/Models/kokoro-v1_0.safetensors",
      "sha256": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4",
      "byteCount": 5,
      "required": true
    }
  ],
  "voiceGroups": [
    {
      "id": "american-english",
      "displayName": "American English",
      "locale": "en-US",
      "defaultInstalled": true,
      "engineSupport": "supported",
      "voices": [
        {
          "id": "af_heart",
          "displayName": "Heart",
          "asset": {
            "id": "voice-af-heart",
            "role": "voice",
            "path": "Voices/af_heart.npy",
            "url": "https://example.com/voices/af_heart.npy",
            "sha256": "c57d7e92019708b614c90fa3685cd644f543a60153fb99ec9b67c381a245fb2a",
            "byteCount": 5,
            "required": true
          }
        }
      ]
    },
    {
      "id": "british-english",
      "displayName": "British English",
      "locale": "en-GB",
      "defaultInstalled": false,
      "engineSupport": "planned",
      "voices": [
        {
          "id": "bf_alice",
          "displayName": "Alice",
          "asset": {
            "id": "voice-bf-alice",
            "role": "voice",
            "path": "Voices/bf_alice.npy",
            "url": "https://example.com/voices/bf_alice.npy",
            "sha256": "c57d7e92019708b614c90fa3685cd644f543a60153fb99ec9b67c381a245fb2a",
            "byteCount": 5,
            "required": true
          }
        }
      ]
    }
  ]
}
"""
