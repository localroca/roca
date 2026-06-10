# Mac App Setup

This guide covers the current local development path for the Roca Mac app.

## Requirements

- Apple Silicon Mac.
- macOS 15 or newer.
- Xcode with Swift 6 support.
- Git.
- Network access for first-time Swift package dependency resolution.
- Optional: Ollama for local assistant testing.

The app target is `RocaMac` in `Roca.xcodeproj`. Local command-line builds have
code signing disabled. User-facing permission and local-data expectations are
tracked in [Privacy And Permissions](../privacy-and-permissions.md). Public
distribution checks are tracked in [Mac App Release Checklist](../release/mac-app.md).

## Clone And Resolve Dependencies

```sh
git clone https://github.com/localroca/roca.git
cd roca
```

SwiftPM dependencies are resolved by Xcode, `swift test`, or `xcodebuild`.
The first resolution can take a while because `mlx-swift` initializes upstream
MLX submodules and Moonshine downloads a large binary framework.

## Run Tests

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/roca-clang-cache swift test
```

SwiftPM keeps build products and dependency checkouts in the repo-local ignored
`.build` directory by default. The module cache path avoids polluting the
default user cache during scripted checks.

## Build The Mac App From The Command Line

```sh
xcodebuild -project Roca.xcodeproj -scheme RocaMac -configuration Debug -derivedDataPath .build/xcode-derived -clonedSourcePackagesDirPath .build -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

The command reuses the package checkout resolved by `swift test`. Derived data
and packages remain under `.build`, which is ignored by git.

## Build And Run From Xcode

1. Open `Roca.xcodeproj`.
2. Select the `RocaMac` scheme.
3. Wait for Xcode's first package resolution to finish.
4. Use the Debug configuration.
5. Run the app.

Roca is a menu-bar app. After launch, look for the Roca status item rather than
a normal dock-first application window.

During first-time package resolution, Xcode may temporarily report `RocaCore`,
`RocaProviders`, `RocaServices`, and `RocaStorage` as missing package products.
Xcode maintains this package cache separately from the command-line `.build`
cache.
If those errors remain after package activity stops, use **File > Packages >
Resolve Package Versions** and allow it to finish. Avoid resetting package
caches first because that discards the large dependency downloads and starts
resolution over.

## Local Validation

Before opening a pull request, check the relevant parts of the app:

- Swift package tests run, or dependency-resolution failures are captured with
  the exact command and output.
- The `RocaMac` app target builds in Debug.
- The app launches as a menu-bar app.
- Settings opens from the menu.
- macOS voice TTS can speak a short preview.
- Selected-text reading either works or gives a recoverable Accessibility
  message.
- Apple Speech voice input can start and stop with visible mic state.
- Chat panel opens and accepts typed input.
- Assistant setup explains missing Ollama or missing model state clearly.
- Core workflows still work when the companion window is hidden.

## Optional Local Assistant Setup

Roca can discover local Ollama models for assistant mode.

```sh
ollama serve
ollama pull qwen3:4b-instruct
```

Other compatible local models may work, but the app should explain setup or
selection failures instead of silently falling back to unrelated behavior.

## Optional Provider Assets

Roca works with built-in macOS voices and Apple Speech before optional model
downloads.

Optional local model paths:

- Kokoro TTS assets through Roca-managed provider storage.
- Moonshine STT assets through Roca-managed provider storage.

Provider downloads should be initiated through the app UI so install, verify,
repair, and remove state stays consistent.

## Current Setup Caveats

- The project is pre-launch and not yet packaged for end users.
- First-time dependency resolution may spend several minutes fetching the MLX
  submodules and Moonshine framework.
- Raw assistant transcript logging is opt-in under Settings > Logs, with local
  export and delete controls for the transcript file.
- The current SwiftUI companion is a placeholder state surface. The long-term
  companion direction is planned separately.
