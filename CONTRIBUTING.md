# Contributing

This project follows Omarchy's plugin model and development conventions where applicable.

## Principles

- Keep provider-specific logic out of QML.
- Keep credentials out of plugin settings, source code, shell config, logs, and tests.
- Prefer small, reviewable changes.
- Add tests for pure model behavior and helper protocol changes.
- Use the shared Omarchy shell UI components and theme roles.
- Do not edit `/usr/share/omarchy`; develop this plugin as a standalone repository.

## Style

- Two-space indentation for QML, JavaScript, JSON, and shell scripts.
- Bash scripts use `#!/bin/bash`.
- Markdown uses full lines rather than hard-wrapping at 80 columns.
- Provider-facing data should be normalized before reaching QML.

## Verification

Run:

```bash
./test/all
omarchy plugin validate .
```

For UI changes, also verify in a running Omarchy session and capture before/after screenshots when preparing a public release.

## Upstream Boundaries

This repository is the right home for provider-backed calendar integration. Omarchy core PRs should be limited to generic shell/plugin capabilities that this plugin proves are missing.
