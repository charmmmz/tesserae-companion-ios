# Tesserae Companion

Tesserae Companion is a native iOS companion for
[Tesserae](https://github.com/dmellok/tesserae). It is intended to make
the small, frequent interactions around a household's displays feel at
home on iPhone: finding the server, checking displays, sending a saved
dashboard, sharing a photo, and running the same actions from Shortcuts.

It is a community-built client, not the official Tesserae app.

## Project status

- Product status: native prototype framework and API-contract review
- Document version: 0.2.0
- Planned first App Store release: 1.0.0
- Included product scope: native V1 plus Share Sheet and Shortcuts integrations
- iOS implementation: native Swift and SwiftUI
- Server dependency: the proposed scoped `/api/app/v1` surface

The first release deliberately keeps dashboard creation, Canvas editing,
plugins, themes, schedules, rotations, firmware, and advanced device
management in Tesserae's existing web UI.

## Documents

- [DESIGN.md](DESIGN.md) is the product, UX, architecture, delivery, and
  acceptance-criteria source of truth.
- [API_CONTRACT.md](API_CONTRACT.md) is the proposed server contract to
  review and refine with the Tesserae maintainer.
- [Contracts/app-v1.openapi.yaml](Contracts/app-v1.openapi.yaml) and
  [Contracts/Fixtures](Contracts/Fixtures) are the machine-readable contract
  and shared server/client examples.
- [CHANGELOG.md](CHANGELOG.md) records decisions and user-visible changes.
- [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
  [ATTRIBUTION.md](ATTRIBUTION.md) define repository, reporting, and upstream
  boundaries.

## Prototype

The repository now contains an iOS 17+ SwiftUI prototype generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```text
App/
├── Sources/
│   ├── Features/
│   └── DesignSystem/
└── Resources/
Packages/
└── TesseraeKit/
    ├── Sources/TesseraeKit/
    └── Tests/TesseraeKitTests/
project.yml
```

`TesseraeKit` owns the proposed models and protocol boundaries. The app
currently uses `MockTesseraeClient`, so onboarding, displays, dashboards,
photo sending, and Activity can be exercised without pretending that the
proposed server contract already exists.

Generate and open the project:

```sh
xcodegen generate
open TesseraeCompanion.xcodeproj
```

Run the package tests:

```sh
swift test --package-path Packages/TesseraeKit
```

Run the OpenAPI fixture checks with a Python environment containing the
small dependencies in `Contracts/requirements.txt`:

```sh
python -m pytest Contracts/test_contract.py
```

The generated Xcode scheme also includes a simulator UI test that walks the
fixture-backed onboarding, Displays, Dashboards, Send, and Activity flow.

The prototype bundle identifier is `com.charm.TesseraeCompanion`. Signing,
the final bundle identifier, App Groups, Keychain access groups, and extension
targets will be decided before physical-device or TestFlight work.

### Deliberately not live yet

- Bonjour browsing and local-network permission timing;
- QR scanning and one-time-code exchange;
- Keychain-backed credential persistence;
- live HTTP requests to a Companion API;
- Share Extension and App Intents targets;
- History/resend and real server-rendered previews.

These remain behind protocols or explicit fixture labels until their upstream
implementations are released. The namespace and minimum contract shape are
maintainer-aligned, but the current Tesserae server does not implement them.

## Repository boundary

The iOS app should live in its own `tesserae-companion-ios` repository because
it has an independent Xcode, signing, App Store, issue, and release lifecycle.
The Tesserae server repository should own only the server implementation,
server-facing OpenAPI integration, and server contract tests. No public
repository has been created yet; ownership, visibility, and licence still
require an explicit decision.

Source availability does not currently grant a redistribution licence. See
`ATTRIBUTION.md` before copying or publishing this repository.

## Collaboration workflow

1. Discuss a change in GitHub Discussions or an issue before changing a
   stable contract.
2. Record accepted product or architecture decisions in the decision log
   in `DESIGN.md`.
3. Update `API_CONTRACT.md` in the same change as any server-contract
   decision.
4. Add a concise entry under `[Unreleased]` in `CHANGELOG.md`.
5. Link the implementing Tesserae PR and iOS PR from the relevant
   requirement or decision.
6. Move an item to Done only after its acceptance criteria have passed on
   a physical iPhone and a real Tesserae-backed display.

Document-only changes can land before server or app implementation. An API
item marked **Proposed** is not safe for the app to depend on until the
matching Tesserae release and minimum compatible version are recorded.

## Naming and App Store position

- App name: **Tesserae Companion**
- Store description: **A community-built companion client for Tesserae**
- Publisher: the companion app maintainer's Apple Developer account
- Official status: always described as community-built, never official

Use of the Tesserae name and brand mark in the final App Store listing
remains subject to explicit maintainer approval. If maintenance stops, the
maintainer will give notice and provide a practical handover path so users
are not stranded.
