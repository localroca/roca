# Provider Asset Templates

These manifests are checked-in first-party Roca-managed provider asset catalogs.

- `kokoro-mlx.json`: pinned Kokoro MLX model plus all 54 non-legacy voice assets, grouped by language/accent. American English is the default-installed voice group.
- `moonshine-medium-streaming-en.json`: pinned Moonshine English Streaming STT model assets, used as Roca's optional Moonshine download.

Provider-specific tooling should regenerate these catalogs when upstream pinned revisions change. Roca consumes the checked-in manifests instead of hardcoding model or voice file hashes in Swift. The runtime manifests bundled with `RocaProviders` are tested against these catalogs.
