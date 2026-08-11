# Privacy

Agent Overview is local-first and has no telemetry.

It derives state from process lists and local agent event files. Only coarse state
such as offline, idle, working, awaiting input, completed, or error is shown. Task
messages and file contents are not copied into the app cache.

Codex quota data is requested from the locally installed Codex executable through
`account/rateLimits/read`. The app does not request or store an OpenAI API key.

Other vendors' private quota APIs and credential stores are intentionally excluded
from the public build. Claude, Kimi, Cursor, Hermes, and OpenClaw are status-only.
