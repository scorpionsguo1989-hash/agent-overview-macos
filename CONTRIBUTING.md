# Contributing

Contributions are welcome.

1. Fork the repository and create a focused branch.
2. Run `./scripts/privacy-check.sh`.
3. Run `./scripts/test.sh` and `./scripts/build.sh` on Apple Silicon macOS 13+.
4. Open a pull request describing the user-visible change and privacy impact.

Do not commit real session files, usage caches, screenshots, credentials, absolute
home-directory paths, or vendor account identifiers. New usage adapters must not
extract browser cookies, access tokens, passwords, or API keys.

Documentation images must be rendered from deterministic synthetic fixtures.
Do not capture a signed-in desktop, menu bar, account page, or live Agent Overview
panel for public documentation.
