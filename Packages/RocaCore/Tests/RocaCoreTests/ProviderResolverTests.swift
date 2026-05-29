import Testing
import RocaCore
import RocaTestingSupport

@Test
func resolverUsesRequestedProviderWhenAvailable() async throws {
    let requested = ProviderID(rawValue: "requested")
    let fallback = ProviderID(rawValue: "fallback")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            ProviderDescriptor(
                id: requested,
                kind: .tts,
                displayName: "Requested",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: fallback,
                kind: .tts,
                displayName: "Fallback",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            )
        ]
    )
    let provider = FakeTTSProvider(id: requested, displayName: "Requested")
    let fallbackProvider = FakeTTSProvider(id: fallback, displayName: "Fallback")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [provider, fallbackProvider],
        ttsFallbackOrder: [fallback]
    )

    let resolved = try await resolver.ttsProvider(
        TTSResolutionRequest(requestedProviderID: requested, source: .selectedText, allowFallback: true)
    )

    #expect(resolved.id == requested)
}

@Test
func automaticProviderUsesKokoroWhenHealthy() async throws {
    let kokoro = ProviderID(rawValue: "kokoro")
    let macOS = ProviderID(rawValue: "macos")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: kokoro, displayName: "Kokoro"),
            providerDescriptor(id: macOS, displayName: "macOS")
        ]
    )
    let kokoroProvider = FakeTTSProvider(id: kokoro, displayName: "Kokoro")
    let macOSProvider = FakeTTSProvider(id: macOS, displayName: "macOS")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [kokoroProvider, macOSProvider],
        ttsFallbackOrder: [kokoro, macOS]
    )

    let resolved = try await resolver.ttsProvider(
        TTSResolutionRequest(requestedProviderID: nil, source: .selectedText, allowFallback: true)
    )

    #expect(resolved.id == kokoro)
}

@Test
func automaticProviderFallsBackToMacOSWhenKokoroUnavailable() async throws {
    let kokoro = ProviderID(rawValue: "kokoro")
    let macOS = ProviderID(rawValue: "macos")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: kokoro, displayName: "Kokoro"),
            providerDescriptor(id: macOS, displayName: "macOS")
        ]
    )
    let kokoroProvider = FakeTTSProvider(
        id: kokoro,
        displayName: "Kokoro",
        prepareError: RocaError.providerUnavailable(kokoro)
    )
    let macOSProvider = FakeTTSProvider(id: macOS, displayName: "macOS")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [kokoroProvider, macOSProvider],
        ttsFallbackOrder: [kokoro, macOS]
    )

    let resolved = try await resolver.ttsProvider(
        TTSResolutionRequest(requestedProviderID: nil, source: .selectedText, allowFallback: true)
    )

    #expect(resolved.id == macOS)
}

@Test
func explicitKokoroDoesNotFallBackWhenUnavailable() async throws {
    let kokoro = ProviderID(rawValue: "kokoro")
    let macOS = ProviderID(rawValue: "macos")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: kokoro, displayName: "Kokoro"),
            providerDescriptor(id: macOS, displayName: "macOS")
        ]
    )
    let kokoroProvider = FakeTTSProvider(
        id: kokoro,
        displayName: "Kokoro",
        prepareError: RocaError.providerUnavailable(kokoro)
    )
    let macOSProvider = FakeTTSProvider(id: macOS, displayName: "macOS")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [kokoroProvider, macOSProvider],
        ttsFallbackOrder: [kokoro, macOS]
    )

    await #expect(throws: RocaError.providerUnavailable(kokoro)) {
        _ = try await resolver.ttsProvider(
            TTSResolutionRequest(requestedProviderID: kokoro, source: .selectedText, allowFallback: false)
        )
    }
}

@Test
func previewDoesNotFallbackWhenProviderUnavailable() async throws {
    let kokoro = ProviderID(rawValue: "kokoro")
    let macOS = ProviderID(rawValue: "macos")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: kokoro, displayName: "Kokoro"),
            providerDescriptor(id: macOS, displayName: "macOS")
        ]
    )
    let kokoroProvider = FakeTTSProvider(
        id: kokoro,
        displayName: "Kokoro",
        prepareError: RocaError.providerUnavailable(kokoro)
    )
    let macOSProvider = FakeTTSProvider(id: macOS, displayName: "macOS")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [kokoroProvider, macOSProvider],
        ttsFallbackOrder: [kokoro, macOS]
    )

    await #expect(throws: RocaError.providerUnavailable(kokoro)) {
        _ = try await resolver.ttsProvider(
            TTSResolutionRequest(requestedProviderID: kokoro, source: .voicePreview, allowFallback: false)
        )
    }
}

@Test
func voicePreviewDoesNotUseSelectedProvider() async throws {
    let selected = ProviderID(rawValue: "selected")
    let fallback = ProviderID(rawValue: "fallback")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            ProviderDescriptor(
                id: selected,
                kind: .tts,
                displayName: "Selected",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: fallback,
                kind: .tts,
                displayName: "Fallback",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            )
        ]
    )
    let selectedProvider = FakeTTSProvider(id: selected, displayName: "Selected")
    let fallbackProvider = FakeTTSProvider(id: fallback, displayName: "Fallback")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [selectedProvider, fallbackProvider],
        selectedTTSProvider: { selected },
        ttsFallbackOrder: [fallback]
    )

    await #expect(throws: RocaError.providerUnavailable(ProviderID(rawValue: "tts.default"))) {
        _ = try await resolver.ttsProvider(
            TTSResolutionRequest(requestedProviderID: nil, source: .voicePreview, allowFallback: false)
        )
    }
}

@Test
func automaticSTTProviderUsesAppleSpeechFirst() async throws {
    let appleSpeech = ProviderID(rawValue: "apple-speech")
    let moonshine = ProviderID(rawValue: "moonshine")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: appleSpeech, kind: .stt, displayName: "Apple Speech"),
            providerDescriptor(id: moonshine, kind: .stt, displayName: "Moonshine")
        ]
    )
    let appleProvider = FakeSTTProvider(id: appleSpeech, displayName: "Apple Speech")
    let moonshineProvider = FakeSTTProvider(id: moonshine, displayName: "Moonshine")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [],
        sttProviders: [appleProvider, moonshineProvider],
        ttsFallbackOrder: [],
        sttFallbackOrder: [appleSpeech, moonshine]
    )

    let resolved = try await resolver.sttProvider(
        STTResolutionRequest(
            requestedProviderID: nil,
            locale: "en-US",
            intent: .dictation,
            allowFallback: true,
            requireLocal: true
        )
    )

    #expect(resolved.id == appleSpeech)
}

@Test
func automaticSTTProviderFallsBackToMoonshineWhenAppleSpeechUnavailable() async throws {
    let appleSpeech = ProviderID(rawValue: "apple-speech")
    let moonshine = ProviderID(rawValue: "moonshine")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: appleSpeech, kind: .stt, displayName: "Apple Speech"),
            providerDescriptor(id: moonshine, kind: .stt, displayName: "Moonshine")
        ]
    )
    let appleProvider = FakeSTTProvider(
        id: appleSpeech,
        displayName: "Apple Speech",
        prepareError: RocaError.providerUnavailable(appleSpeech)
    )
    let moonshineProvider = FakeSTTProvider(id: moonshine, displayName: "Moonshine")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [],
        sttProviders: [appleProvider, moonshineProvider],
        ttsFallbackOrder: [],
        sttFallbackOrder: [appleSpeech, moonshine]
    )

    let resolved = try await resolver.sttProvider(
        STTResolutionRequest(
            requestedProviderID: nil,
            locale: "en-US",
            intent: .dictation,
            allowFallback: true,
            requireLocal: true
        )
    )

    #expect(resolved.id == moonshine)
}

@Test
func automaticSTTProviderSurfacesOnlyCandidatePreparationError() async throws {
    let appleSpeech = ProviderID(rawValue: "apple-speech")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: appleSpeech, kind: .stt, displayName: "Apple Speech")
        ]
    )
    let provider = FakeSTTProvider(
        id: appleSpeech,
        displayName: "Apple Speech",
        prepareError: RocaError.permission(.speechRecognition)
    )
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [],
        sttProviders: [provider],
        ttsFallbackOrder: [],
        sttFallbackOrder: [appleSpeech]
    )

    await #expect(throws: RocaError.permission(.speechRecognition)) {
        _ = try await resolver.sttProvider(
            STTResolutionRequest(
                requestedProviderID: nil,
                locale: "en-US",
                intent: .dictation,
                allowFallback: true,
                requireLocal: true
            )
        )
    }
}

@Test
func automaticSTTProviderSurfacesAppleSpeechPreparationErrorWhenAppleSpeechAndMoonshineFail() async throws {
    let appleSpeech = ProviderID(rawValue: "apple-speech")
    let moonshine = ProviderID(rawValue: "moonshine")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: appleSpeech, kind: .stt, displayName: "Apple Speech"),
            providerDescriptor(id: moonshine, kind: .stt, displayName: "Moonshine")
        ]
    )
    let appleProvider = FakeSTTProvider(
        id: appleSpeech,
        displayName: "Apple Speech",
        prepareError: RocaError.providerUnavailable(appleSpeech)
    )
    let moonshineProvider = FakeSTTProvider(
        id: moonshine,
        displayName: "Moonshine",
        prepareError: RocaError.assetInstallFailed("Moonshine model is not installed.")
    )
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [],
        sttProviders: [appleProvider, moonshineProvider],
        ttsFallbackOrder: [],
        sttFallbackOrder: [appleSpeech, moonshine]
    )

    await #expect(throws: RocaError.providerUnavailable(appleSpeech)) {
        _ = try await resolver.sttProvider(
            STTResolutionRequest(
                requestedProviderID: nil,
                locale: "en-US",
                intent: .dictation,
                allowFallback: true,
                requireLocal: true
            )
        )
    }
}

@Test
func explicitSTTProviderDoesNotFallBackWhenUnavailable() async throws {
    let moonshine = ProviderID(rawValue: "moonshine")
    let fallback = ProviderID(rawValue: "fallback")
    let registry = InMemoryProviderRegistry(
        descriptors: [
            providerDescriptor(id: moonshine, kind: .stt, displayName: "Moonshine"),
            providerDescriptor(id: fallback, kind: .stt, displayName: "Fallback")
        ]
    )
    let provider = FakeSTTProvider(
        id: moonshine,
        displayName: "Moonshine",
        prepareError: RocaError.providerUnavailable(moonshine)
    )
    let fallbackProvider = FakeSTTProvider(id: fallback, displayName: "Fallback")
    let resolver = DefaultProviderResolver(
        registry: registry,
        ttsProviders: [],
        sttProviders: [provider, fallbackProvider],
        ttsFallbackOrder: [],
        sttFallbackOrder: [fallback]
    )

    await #expect(throws: RocaError.providerUnavailable(moonshine)) {
        _ = try await resolver.sttProvider(
            STTResolutionRequest(
                requestedProviderID: moonshine,
                locale: "en-US",
                intent: .dictation,
                allowFallback: false,
                requireLocal: true
            )
        )
    }
}

private func providerDescriptor(id: ProviderID, displayName: String) -> ProviderDescriptor {
    providerDescriptor(id: id, kind: .tts, displayName: displayName)
}

private func providerDescriptor(id: ProviderID, kind: ProviderKind, displayName: String) -> ProviderDescriptor {
    ProviderDescriptor(
        id: id,
        kind: kind,
        displayName: displayName,
        isEnabled: true,
        isBuiltIn: true,
        locality: .local
    )
}
