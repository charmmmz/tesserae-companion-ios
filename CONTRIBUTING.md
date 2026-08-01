# Contributing

Tesserae Companion is the official native iOS app for
[Tesserae](https://github.com/dmellok/tesserae). It is maintained in this
public repository, and contributions are welcome under Apache-2.0.

## Development setup

Requirements:

- macOS with Xcode;
- iOS 17 or later SDK support;
- Swift 6;
- Python 3.11 or later for contract checks.

Run the contract and package tests:

```sh
python3 -m venv .venv
.venv/bin/pip install -r Contracts/requirements.txt
.venv/bin/python -m pytest Contracts/test_contract.py
swift test --package-path Packages/TesseraeKit
```

Build the app without signing:

```sh
xcodebuild \
  -project TesseraeCompanion.xcodeproj \
  -scheme TesseraeCompanion \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The checked-in Xcode project is generated from `project.yml`. When target or
build settings change, regenerate it with XcodeGen and commit both files.

## Contract changes

Changes to `/api/app/v1` must update all relevant artifacts together:

1. `Contracts/app-v1.openapi.yaml`;
2. request or response files under `Contracts/Fixtures`;
3. `TesseraeKit` Codable models and tests;
4. `API_CONTRACT.md`, `DESIGN.md`, and `CHANGELOG.md`.

Do not make the client depend on firmware tokens, the global webhook token,
Flask sessions, privileged MCP, or internal web routes.

## Commits and pull requests

- Keep one concern per commit and pull request.
- Use Conventional Commit prefixes such as `feat:`, `fix:`, `docs:`,
  `test:`, and `chore:`.
- Explain the user or contract impact rather than only listing files.
- Do not commit credentials, signing certificates, provisioning profiles,
  photos, server addresses, or captured household data.
- Keep live networking behind explicit protocol boundaries until the matching
  Tesserae server contract has been released.

All checks must pass before review. Physical-device or display claims must
record the iPhone/iOS version, Tesserae version, display model, transport, and
observed result.
