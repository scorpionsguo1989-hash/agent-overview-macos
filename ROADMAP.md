# Roadmap

## Near term

- Add a notarized release pipeline when signing infrastructure is available.
- Expand VoiceOver coverage for transient errors and reset-time announcements.
- Add documented, credential-free adapter interfaces.
- Expand deterministic fixtures for agent state transitions.

## Adapter policy

New adapters must use documented or local interfaces and must not extract browser
cookies, access tokens, passwords, or API keys. Status-only integrations are
preferred when a safe quota interface is unavailable.
