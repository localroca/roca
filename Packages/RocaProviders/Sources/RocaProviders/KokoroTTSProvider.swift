import Foundation
import RocaCore

public final class KokoroTTSProvider: TTSProvider, @unchecked Sendable {
    public let id = BuiltInProviderIDs.kokoroNative
    public let displayName = KokoroManagedAssets.displayName

    private let assets: KokoroProviderAssetSession
    private let engine = KokoroNativeEngine()

    public init(assetStore: ProviderAssetStore) {
        self.assets = KokoroProviderAssetSession(assetStore: assetStore)
    }

    public var capabilities: TTSCapabilities {
        TTSCapabilities(
            supportsStreaming: false,
            supportedFormats: [.wav24Mono],
            locality: .local,
            recommendedChunkCharacterLimit: 420
        )
    }

    public func prepare() async throws {
        let resolvedAssets = try await assets.prepared()
        try await engine.prepare(manifest: resolvedAssets.manifest, installation: resolvedAssets.installation)
    }

    public func noteVerifiedInstallation(
        _ installation: ProviderAssetInstallation,
        manifest: ProviderAssetManifest,
        verifiedVoiceGroupIDs: Set<String>
    ) async {
        await assets.cache(
            manifest: manifest,
            installation: installation,
            verifiedVoiceGroupIDs: verifiedVoiceGroupIDs
        )
    }

    public func listVoices() async throws -> [TTSVoice] {
        let resolvedAssets = try await assets.refreshForListing()
        return resolvedAssets.manifest.voiceGroups
            .filter { resolvedAssets.installation.installedVoiceGroupIDs.contains($0.id) }
            .flatMap { group in
                group.voices.map { voice in
                    TTSVoice(
                        id: voice.id,
                        displayName: voice.displayName,
                        locale: group.locale,
                        traits: [group.displayName]
                    )
                }
            }
    }

    public func synthesize(_ request: TTSRequest) async throws -> AsyncThrowingStream<TTSEvent, Error> {
        let resolvedAssets = try await assets.prepared(for: request.voice ?? KokoroManagedAssets.defaultVoiceID)
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(utteranceID: request.utteranceID))
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let wavData = try await engine.synthesize(
                        request,
                        manifest: resolvedAssets.manifest,
                        installation: resolvedAssets.installation
                    )
                    try Task.checkCancellation()
                    continuation.yield(
                        .audioChunk(
                            AudioChunk(
                                utteranceID: request.utteranceID,
                                data: wavData,
                                format: .wav24Mono,
                                sequenceNumber: 0
                            )
                        )
                    )
                    continuation.yield(.finished(utteranceID: request.utteranceID))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.cancelled(utteranceID: request.utteranceID))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func cancel(_ utteranceID: UtteranceID) async {
    }
}

private struct KokoroProviderAssets: Sendable {
    var manifest: ProviderAssetManifest
    var installation: ProviderAssetInstallation
}

private actor KokoroProviderAssetSession {
    private let assetStore: ProviderAssetStore
    private var cachedManifest: ProviderAssetManifest?
    private var cachedInstallation: ProviderAssetInstallation?
    private var verifiedVoiceGroupIDs = Set<String>()

    init(assetStore: ProviderAssetStore) {
        self.assetStore = assetStore
    }

    func prepared(for voiceID: VoiceID? = nil) async throws -> KokoroProviderAssets {
        let manifest = try manifest()
        let requestedGroupIDs = try requestedVoiceGroupIDs(for: voiceID, in: manifest)
        if let cachedInstallation,
           requestedGroupIDs.isSubset(of: verifiedVoiceGroupIDs)
        {
            return KokoroProviderAssets(manifest: manifest, installation: cachedInstallation)
        }

        let installation = try await assetStore.verifyInstallation(for: manifest, voiceGroupIDs: requestedGroupIDs)
        cachedInstallation = installation
        verifiedVoiceGroupIDs.formUnion(requestedGroupIDs)
        return KokoroProviderAssets(manifest: manifest, installation: installation)
    }

    func refreshForListing() async throws -> KokoroProviderAssets {
        let manifest = try manifest()
        let defaultGroupIDs = Set(manifest.defaultVoiceGroupIDs)
        let installation = try await assetStore.verifyInstallation(for: manifest, voiceGroupIDs: defaultGroupIDs)
        cachedInstallation = installation
        verifiedVoiceGroupIDs.formUnion(defaultGroupIDs)
        return KokoroProviderAssets(manifest: manifest, installation: installation)
    }

    func cache(
        manifest: ProviderAssetManifest,
        installation: ProviderAssetInstallation,
        verifiedVoiceGroupIDs: Set<String>
    ) {
        cachedManifest = manifest
        cachedInstallation = installation
        self.verifiedVoiceGroupIDs.formUnion(verifiedVoiceGroupIDs)
    }

    private func manifest() throws -> ProviderAssetManifest {
        if let cachedManifest {
            return cachedManifest
        }
        let manifest = try KokoroManagedAssets.bundledManifest()
        cachedManifest = manifest
        return manifest
    }

    private func requestedVoiceGroupIDs(for voiceID: VoiceID?, in manifest: ProviderAssetManifest) throws -> Set<String> {
        var groupIDs = Set(manifest.defaultVoiceGroupIDs)
        if let voiceID {
            guard let group = KokoroManagedAssets.voiceGroup(containing: voiceID, in: manifest) else {
                throw RocaError.synthesisFailed("Unknown Kokoro voice \(voiceID.rawValue).")
            }
            groupIDs.insert(group.id)
        }
        return groupIDs
    }
}
