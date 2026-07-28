# Security Policy

## Supported versions

Tesserae Companion is currently a fixture-backed prototype and has no
supported public release. This section will be replaced by a version table
before TestFlight or App Store distribution.

## Reporting a vulnerability

Do not disclose suspected credential, pairing, local-network, image-handling,
or privacy vulnerabilities in a public issue.

Use the repository's private GitHub Security Advisory reporting flow. If that
flow is temporarily unavailable, contact the repository owner privately
instead of opening a public issue.

Include:

- affected commit or app version;
- iOS and Tesserae versions;
- whether the issue requires LAN, authenticated, or physical access;
- reproducible steps with tokens, URLs, photos, and household names redacted;
- expected security or privacy impact.

No live credential is ever required for a report. Fixture credentials in
`Contracts/Fixtures` and `MockTesseraeClient` are intentionally non-secret.

## Security boundaries

- Companion credentials are per-client, scoped, revocable, and stored in
  Keychain when live persistence is implemented.
- Pairing codes are purpose-specific, single-use, and short-lived.
- Bonjour discovers candidates; it does not authenticate servers.
- Photos travel directly to the selected Tesserae instance.
- The client does not fall back to firmware, webhook, MCP, or browser-session
  credentials.
- Logs and diagnostics must redact credentials and user content.
