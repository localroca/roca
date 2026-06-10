# Contributing To Roca

Roca is pre-launch, but contributions are welcome when they improve the local
Mac app, provider boundaries, documentation, privacy behavior, or contributor
experience.

Start here:

- [Mac app setup](docs/development/mac-app-setup.md)
- [Public roadmap](https://github.com/orgs/localroca/projects/3)
- [Release checklist](docs/release/mac-app.md)
- [Triage guide](docs/maintainers/triage.md)

Please follow the [Code Of Conduct](CODE_OF_CONDUCT.md). Report security
issues through [SECURITY.md](SECURITY.md), not public issues.

## Contribution Priorities

Near-term work should keep the app reliable and understandable:

- Mac app setup and release readiness.
- Local-first privacy controls and clear permission behavior.
- Provider setup for speech, voice input, and local assistant use.
- Workflow-compression demos with explicit user-selected context.
- Future companion work that improves state clarity, accessibility, and user
  control.

Avoid broad automation, always-listening behavior, hidden memory, or remote
provider routing unless the relevant privacy and consent work is already in
place.

## Before Opening A Pull Request

Please make the smallest coherent change that solves the issue.

Run the relevant checks when possible:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/roca-clang-cache swift test
xcodebuild -project Roca.xcodeproj -scheme RocaMac -configuration Debug -derivedDataPath .build/xcode-derived -clonedSourcePackagesDirPath .build -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

If a check cannot run locally, include the command you tried and the failure
mode in the pull request.

## Communication

Use GitHub issues for bugs, feature proposals, provider requests, and workflow
ideas. Keep public issues focused on user value, implementation scope, and
reproducible behavior.

Do not post security vulnerabilities, credentials, private prompts, transcripts,
or other sensitive data in public issues.
