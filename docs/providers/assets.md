# Provider Assets

Roca-managed provider assets are the path for first-party local models. Roca downloads, verifies, installs, repairs, and later updates these assets under Application Support.

For the first version, supported voice models are first-party only. Roca should not ask normal users to configure separate apps, ports, local services, or custom side processes.

## Storage

Required model assets live under:

```text
~/Library/Application Support/Roca/Models/
```

Do not store required models in system caches. macOS may purge caches, and a missing model should be an explicit install/repair state rather than a surprise runtime failure.

## Manifest

The first asset manifest schema is:

```text
schemas/provider-assets/0.1.0/schema.json
```

It includes:

- provider and model identifiers;
- pinned revision;
- required files with relative install paths;
- download URLs;
- SHA256 checksums;
- optional byte counts;
- optional bundled resource paths for assets shipped with Roca;
- optional runtime metadata such as provider-specific model architecture;
- voice groups for TTS providers.

Voice groups let Roca install a calm default set first and make other voice/style groups available on demand. For Kokoro, the default is model plus all American English voices. Other groups are optional downloads. The current native Kokoro path processes text as English, so non-English voice groups should be presented as voice/style options until multilingual text processing is wired. STT manifests can omit voice groups.

## Kokoro MLX Direction

Kokoro is a native first-party `TTSProvider` backed by Roca-managed assets. The default product model is “download the voice model in Roca,” not “connect Roca to another app.”

Initial Kokoro asset shape:

```text
Models/kokoro-v1_0.safetensors
Voices/<voice-id>.npy
```

The default install includes the pinned model and the American English voice group. Generated manifests include exact SHA256s for every voice file; Roca should not hardcode voice hashes in Swift.

Roca's native Kokoro integration boundary lives in `KokoroManagedAssets`: it validates the bundled catalog identity and resolves installed model/voice file URLs for `KokoroTTSProvider`. The same catalog is kept under `templates/provider-assets` for external review and tested against the bundled resource to prevent drift.

## Moonshine Direction

Apple Speech is the default built-in `STTProvider`, so dictation can work before the user downloads any model. Moonshine is a native first-party optional `STTProvider` backed by the same manifest and `ProviderAssetStore` path used by Kokoro. Roca exposes Moonshine as one downloadable provider and currently installs the pinned English Streaming model described by `moonshine-medium-streaming-en.json`.

Initial Moonshine asset shape:

```text
frontend.ort
encoder.ort
adapter.ort
decoder_kv.ort
decoder_kv_with_attention.ort
cross_kv.ort
streaming_config.json
tokenizer.bin
```

Roca verifies these files as one required model install under Application Support. The runtime integration boundary lives in `MoonshineManagedAssets`, which validates the manifest identity and maps `runtime.modelArch` into Moonshine Swift's `ModelArch`.

## MLX Runtime

Roca should keep a shared MLX runtime preflight that can be reused by Kokoro and future MLX-backed providers:

- Metal device availability;
- bundled `metallib` availability;
- SwiftPM/Xcode resource bundle availability;
- clear user-facing errors for missing runtime assets.

Native providers may start in-process, but the architecture must allow an invisible Roca-managed helper process if MLX/model crashes or memory pressure threaten app stability.
