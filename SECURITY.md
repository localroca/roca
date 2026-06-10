# Security Policy

Roca is pre-launch software. We still want vulnerability reports handled
privately and responsibly.

## Supported Versions

Security fixes currently target the latest `main` branch. Public release
support windows will be defined once Roca has packaged releases.

## Reporting A Vulnerability

Do not open a public issue for vulnerabilities, credentials, private prompts,
transcripts, or other sensitive data.

Use GitHub private vulnerability reporting from the repository's Security tab
when available. If private reporting is unavailable, contact a maintainer
privately through the repository owner.

Helpful reports include:

- A short summary of the issue.
- Impact and affected area.
- Reproduction steps or proof of concept.
- Relevant commit, build, or app version.
- Redacted logs or screenshots when useful.

## Scope

Reports are especially useful when they involve:

- Permission or consent bypasses.
- Unexpected transcript, prompt, selected-text, or local-file exposure.
- Unsafe provider routing or remote provider behavior.
- Packaging, signing, update, or dependency-chain issues.

We may ask for more detail before confirming impact. Please give maintainers a
reasonable chance to investigate before public disclosure.
