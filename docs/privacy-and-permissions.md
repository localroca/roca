# Privacy And Permissions

Roca is pre-launch software for Apple Silicon Macs on macOS 15 and newer. This
page describes the current public expectations for permissions, local data, and
provider boundaries. For broader local-first principles, see
[Roca Vision](VISION.md).

## Permission Summary

| Area | Current Use | Expectation |
| --- | --- | --- |
| Microphone | Voice input after the user starts listening. | Roca should not listen in the background or run an always-listening wake word by default. |
| Speech Recognition | Apple Speech dictation when voice input is active. | Speech recognition should start only from an explicit user action. |
| Accessibility | Selected-text reading and focused-app text insertion. | Roca should request this through macOS when needed and explain recoverable failures. |
| Selected Text | Reading highlighted text through the assistant. | Roca should use selected text only for the workflow the user invoked. |

## Local Data

Roca stores app data under:

```text
~/Library/Application Support/Roca/
```

Current subdirectories include settings, logs, and managed local model assets.
Roca-managed speech/listening models are stored under:

```text
~/Library/Application Support/Roca/Models/
```

Raw assistant transcript logging is disabled by default and can be enabled in
Settings > Logs. When enabled, Roca writes local assistant chat messages to the
logs directory. Public testing still needs explicit delete and export controls
before transcript logging is considered release-ready.

## Provider Boundaries

- Built-in macOS voices work without optional model downloads.
- Apple Speech is used for the current Apple-native dictation path.
- Ollama, Kokoro, and Moonshine paths are intended to run locally.
- Future remote providers should require explicit setup and clear user choice.

## Current Caveats

Roca is not packaged for broad public use yet. Permission prompts, transcript
controls, and provider setup should stay clear and visible as the app moves from
Dev Alpha toward public testing.
