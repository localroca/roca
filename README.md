# Roca

Roca is an open-source local-first AI workflow companion for Mac with modular voice, avatar, brain, and workflow layers.

The current app is a menu-bar companion with a desktop avatar, an in-memory chat panel, voice input, selected-text reading through the assistant, and a local Ollama-backed assistant loop. Speech works out of the box with built-in macOS voices, voice input works through Apple's on-device Speech framework, and users can optionally download Kokoro TTS or Moonshine STT for higher-quality local model paths.

Roca is local-first and model-friendly. Supported speech/listening models are installed and managed by Roca rather than configured as separate apps. Assistant mode starts with local Ollama discovery while the internal provider architecture stays modular for future Roca-managed brains, memory, workflow compression, and avatar work.

Project status: pre-launch. The current development target is Apple Silicon Macs on macOS 15+. See [docs/VISION.md](docs/VISION.md) for the public product direction and [docs/providers/assets.md](docs/providers/assets.md) for first-party managed model assets.

## Roadmap And Contributing

- Public roadmap: [Roca Roadmap](https://github.com/orgs/localroca/projects/3)
- Contributor guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Mac app setup: [docs/development/mac-app-setup.md](docs/development/mac-app-setup.md)
- Privacy and permissions: [docs/privacy-and-permissions.md](docs/privacy-and-permissions.md)

Roca is licensed under Apache License 2.0. Third-party library and model notices are tracked in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
