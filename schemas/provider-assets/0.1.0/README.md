# Roca Provider Asset Manifest Schema 0.1.0

This experimental schema describes first-party provider assets that Roca downloads, verifies, installs, repairs, and later updates under its own Application Support model store.

Provider asset manifests describe Roca-managed native provider assets such as Kokoro MLX models and voice files.

Schema `0.1.0` requires pinned asset URLs, SHA256 checksums, relative install paths, and optional voice groups. Voice groups separate asset availability from engine support so development builds can track incomplete runtime support without shaping final user-facing copy around that internal state.

Canonical schema:

```text
schemas/provider-assets/0.1.0/schema.json
```

Kokoro MLX catalog:

```text
templates/provider-assets/kokoro-mlx.json
```
