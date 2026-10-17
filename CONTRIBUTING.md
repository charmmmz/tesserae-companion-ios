# Contributing

Tesserae Companion is the official native iOS app for
[Tesserae](https://github.com/dmellok/tesserae). It is maintained in this
public repository, and contributions are welcome under Apache-2.0.

## Development setup

Requirements:

- macOS with Xcode 16.4 or later (Xcode 27.1 for iPhone Duo);
- iOS 18 or later SDK support;
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

## Adaptive UI checks

Run `AdaptiveLayoutUITests` on an ordinary iPhone, an iPad, and iPhone Duo.
Turning an ordinary iPhone must leave the app in portrait; iPad and Duo keep
their system window adaptation. Run the long-display-name tests on iPhone to
verify the portrait lock at standard and accessibility text sizes.
Use the iOS 27.0 runtime for the first two and iOS 27.1 for Duo when validating
foldable support. The app retains its iOS 18 deployment minimum; older SDKs
compile the two-column layout without referencing the new ArrangementView API.

CI runs app unit and adaptive UI tests on iPhone and iPad using the existing
macOS 15 runner. The separate Duo job runs only when repository variable
`IOS_DUO_RUNNER` identifies a runner with Xcode 27.1 and its Duo runtime. Without
that configuration it is explicitly skipped, so a green standard CI run does
not establish Duo coverage. A configured Duo runner missing its SDK or simulator
fails the job. Local Duo checks and the full release checklist remain required.

Simulator rotation does not prove Duo fold transitions. Follow the physical-device
and host-share cases in `TESTFLIGHT_CHECKLIST.md` before release.
