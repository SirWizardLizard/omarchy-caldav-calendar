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

## Branching

`main` only accepts pull requests. Open a branch, push it, and merge through GitHub. GitHub Actions runs `./test/all` on every PR.

## Verification

Run:

```bash
./test/all
omarchy plugin validate .
```

For UI changes, also verify in a running Omarchy session and capture before/after screenshots when preparing a public release.

```bash
python3 scripts/demo-calendars seed
omarchy restart shell
python3 scripts/demo-calendars restore
omarchy restart shell
```

`seed` disables CalDAV sources (does not delete them), adds local Work / Personal / Home calendars, and fills the current month grid. Real data is copied to `~/.local/share/omarchy-calendar/demo-backup`. `restore` puts it back.

## Marketplace updates

`omarchy plugin update` pulls `main`. [omarchyplugins.com](https://omarchyplugins.com) stays on a pinned verified SHA until a **[Verify]** issue is filed.

Bump `version` in `manifest.json` on the release PR. After that merge:

- `.github/workflows/release.yml` tags `vX.Y.Z` and publishes a GitHub Release with generated notes (skipped if the version did not change or the tag already exists). You can also run the **release** workflow by hand for the current `main` SHA.
- `.github/workflows/marketplace-verify.yml` files the verify issue if the `MARKETPLACE_TOKEN` secret is set (classic PAT with `public_repo`). Without the secret it opens a reminder issue on this repo instead.

GitHub Releases and the marketplace pin are independent. Users who clone this repo follow tags; `omarchy plugin update` still tracks `main` until a marketplace verify lands.

## Upstream Boundaries

This repository is the right home for provider-backed calendar integration. Omarchy core PRs should be limited to generic shell/plugin capabilities that this plugin proves are missing.
