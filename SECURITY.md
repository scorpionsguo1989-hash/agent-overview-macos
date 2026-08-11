# Security policy

## Supported version

Security fixes are applied to the latest release on `main`.

## Privacy boundary

Agent Overview is a local macOS menu-bar utility. The public build:

- reads local process and task-state signals;
- queries Codex usage through the local Codex `app-server` process;
- does not read browser cookies, API keys, access tokens, or passwords;
- does not include telemetry or an analytics SDK;
- writes only derived usage values to a local cache with mode `0600`.

The cache is stored at `~/Library/Application Support/AgentOverview/usage-cache.json`.
It contains quota windows, plan labels, reset times, and check timestamps. It must
never contain credentials or task content.

## Reporting a vulnerability

Please open a private GitHub security advisory. Do not include real credentials,
session files, task content, or screenshots containing account information.
