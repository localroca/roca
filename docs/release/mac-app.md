# Mac App Release Checklist

This checklist tracks what must be true before distributing Roca as a Mac app.
The project is still pre-launch, so treat this as release readiness rather than
a public packaging promise.

## Preflight

- Confirm the target release scope and version.
- Run package tests:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/roca-clang-cache swift test
```

- Build the app target locally:

```sh
xcodebuild -project Roca.xcodeproj -scheme RocaMac -configuration Debug -derivedDataPath .build/xcode-derived -clonedSourcePackagesDirPath .build -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

- Review user-facing privacy, permissions, and local-data copy.
- Confirm third-party notices are current.
- Confirm no local logs, transcripts, models, derived data, or secrets are
  included in the release artifact.

## Packaging

- Use a clean checkout or clean derived data path.
- Archive the `RocaMac` scheme with release signing enabled.
- Export a Developer ID signed app or installer artifact.
- Preserve the exact Xcode version, commit SHA, version, build number, and
  export settings used for the artifact.
- Smoke-test the exported artifact on an Apple Silicon Mac outside the build
  checkout.

## Signing And Notarization

- Use the Apple Developer ID Application certificate for public Mac
  distribution.
- Keep hardened runtime enabled unless a specific entitlement requires review.
- Review app entitlements before every public release.
- Submit the exported artifact to Apple notarization with `notarytool`.
- Staple the notarization ticket to the distributed artifact when applicable.
- Verify Gatekeeper accepts the final artifact before publishing.

Useful verification commands once release export is wired:

```sh
codesign --verify --deep --strict --verbose=2 <path-to-Roca.app>
spctl -a -vvv -t exec <path-to-Roca.app>
xcrun stapler validate <path-to-artifact>
```

## Release Artifact Checks

- Roca launches as a menu-bar app.
- Settings opens from the menu-bar item.
- Quitting and window closing behavior matches the current app policy.
- macOS voice preview works.
- Voice input starts and stops cleanly.
- Selected-text reading works or shows a clear recoverable permission message.
- Chat opens and explains missing Ollama or missing model setup clearly.
- Optional provider asset download, repair, and remove states are not broken.
- Transcript logging remains opt-in and local export/delete controls work.

## Release Notes And Rollback

- Publish concise release notes with user-visible changes, known caveats, and
  minimum supported macOS/hardware.
- Tag the release commit after the final artifact is verified.
- Keep the previous verified artifact available until the new release has been
  smoke-tested by maintainers.
- If rollback is needed, mark the release withdrawn, remove the bad artifact,
  and point users back to the previous verified release.

## Open Release Decisions

- Final packaging format: `.dmg`, `.zip`, or installer package.
- Release signing/export settings file.
- Update channel and release cadence.
- Crash-reporting and diagnostics policy.
