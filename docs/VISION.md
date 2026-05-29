# Roca Vision

Roca is an open-source local-first AI workflow companion for Mac with modular voice, avatar, brain, and workflow layers.

Modern AI has powerful brains, but it often lives behind chat boxes, browser tabs, and disconnected apps. Roca explores a different shape: a local workflow companion layer that can listen, speak, appear on your desktop, and connect to the AI systems you choose.

The goal is not to build another closed assistant. The goal is to give personal AI a local presence that is useful, private, customizable, extensible, and able to reduce friction in everyday knowledge work.

## What Roca Is

Roca starts as a Mac app with two coordinated surfaces:

- A menu-bar utility for status, controls, providers, permissions, logs, and practical workflows.
- A desktop companion that can show state, feel present, and make AI interactions more natural.

The initial development target is Apple Silicon Macs on macOS 15 and newer. This lets the first local-provider path lean into modern Apple-native ML tooling instead of carrying older platform constraints during the pre-launch build.

The companion is part of the product, not just decoration. It should make Roca feel alive without taking away user control. If you prefer the utility without the visible companion, you should be able to hide it and keep using the menu-bar experience.

The first workflows are intentionally grounded:

- Read selected text aloud from any app.
- Dictate into a focused app.
- Speak to a chosen AI backend and hear the response.
- Use a lightweight local brain to route requests to the right configured model.
- Compress recurring knowledge-work tasks while keeping the user in flow.
- Swap providers as better local and remote tools appear.

Roca should be useful from the first install and become more personal as you configure it.

## Local-First And User-Controlled

Roca is designed around local-first trust.

That means:

- You choose which speech, language, and assistant providers to use.
- Local providers should be preferred where they make sense.
- Remote providers should be explicit, configurable, and understandable.
- Microphone state should be visible.
- Memory should be local, inspectable, editable, and opt-in.
- The app should ask before crossing meaningful privacy boundaries.

Roca should not silently profile you or summarize every conversation into permanent memory. Early memory should focus on useful local state: settings, provider choices, voice/avatar preferences, routing rules, current-session context, and facts you explicitly ask Roca to remember.

## Modular By Design

Roca is a product first, but it is built to be modular.

The important layers should be swappable:

- **TTS:** local speech engines, macOS voices, cloud voices, and community providers.
- **STT:** low-latency local speech recognition, Apple-native Whisper-compatible options, and future providers.
- **Brains:** a lightweight local companion/router brain, local models, OpenAI-compatible endpoints, Ollama, cloud models, and other backends.
- **Avatars:** the default Roca companion, alternate first-party designs, and user-created avatars.
- **Memory:** local preferences, session memory, explicit saved facts, and future opt-in richer memory.
- **Workflows:** reading, dictation, assistant conversations, language practice, notes, and other modes over time.

No single model, voice, avatar, or backend should define Roca. The companion should help coordinate them.

## The Companion Router

Roca should feel alive before the user configures a large model.

The default local brain is not meant to be the smartest assistant in the room. Its job is to make the companion usable immediately and route work to the right place.

For example:

- A coding question can go to a coding model.
- A casual question can go to a chat model.
- A private task can stay local.
- A high-quality task can go to a remote provider if the user allows it.

The user should be able to see and change these choices. Roca should make provider routing understandable instead of turning it into a hidden black box.

## Companion Design

Roca should have a recognizable default identity while leaving room for mods and alternatives.

The visual direction is an original cel-shaded desktop companion with a clear silhouette, expressive states, and its own identity.

The first avatar does not need advanced animation. It does need to communicate useful state:

- Idle.
- Listening.
- Thinking.
- Speaking.
- Interrupted.
- Muted.
- Offline.
- Waiting for permission.

Presence matters most when it reflects real activity.

## What Roca Is Not

Roca is not trying to be a full autonomous desktop operator at the start.

It should not begin as:

- An always-listening wake-word assistant.
- A cloud-first companion.
- A hardwired wrapper around one TTS engine.
- A distribution platform for every possible extension.
- A replacement for every chat UI.
- A mascot attached to a technical settings panel.

The first product should stay focused on local voice, visible presence, provider choice, and daily utility.

## Open Source Direction

Roca is open source because companion software should be inspectable, modifiable, and trusted.

The open project should make it possible to:

- Understand what is running locally.
- Add new providers.
- Improve the Mac app.
- Experiment with voices, avatars, and model routing.
- Build workflows that fit real personal AI use.

The long-term hope is that Roca becomes a shared local workflow layer for personal AI: useful by default, private by design, modular by architecture, and expressive enough for people to make it their own.
