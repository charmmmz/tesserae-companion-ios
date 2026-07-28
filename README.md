# Tesserae Companion

Tesserae Companion is a native iOS companion for
[Tesserae](https://github.com/dmellok/tesserae). It is intended to make
the small, frequent interactions around a household's displays feel at
home on iPhone: finding the server, checking displays, sending a saved
dashboard, sharing a photo, and running the same actions from Shortcuts.

It is a community-built client, not the official Tesserae app.

## Project status

- Product status: contract-connected native prototype
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

`TesseraeKit` owns the proposed models, Keychain boundary, and HTTP transport.
The app can use `LiveTesseraeClient` with a compatible `/api/app/v1` server,
while `MockTesseraeClient` remains available for previews and the built-in
demo journey.

Generate and open the project:

```sh
xcodegen generate
open TesseraeCompanion.xcodeproj
```

Run the package tests:

```sh
swift test --package-path Packages/TesseraeKit
```

Run the local contract server and exercise the live manual-connection flow:

```sh
python3 Contracts/fixture_server.py --port 8765
```

In the app, enter `http://127.0.0.1:8765` and any six-digit pairing code.
The fixture server is stateful enough to test capability probing, pairing,
authenticated lists, idempotent Dashboard pushes, image multipart uploads,
and Job polling. It is development infrastructure, not a Tesserae server.

Run the OpenAPI fixture checks with a Python environment containing the
small dependencies in `Contracts/requirements.txt`:

```sh
python -m pytest Contracts
```

The generated Xcode scheme also includes a simulator UI test that walks the
fixture-backed onboarding, Displays, Dashboards, Send, and Activity flow.

The application identifier is `com.charmmmz.tesseraecompanion`; the embedded
Share Extension is `com.charmmmz.tesseraecompanion.share`. Both use
`group.com.charmmmz.tesseraecompanion` and a shared Keychain access group.
Automatic signing is configured for the maintainer's Apple Developer team.
Xcode must be signed into that team before it can create development
provisioning profiles.

### Still pending

- final physical-device permission validation against an upstream-advertised
  `_tesserae._tcp` service;
- History/resend and real server-rendered previews.

The Share Extension is implemented against the proposed contract: it loads one
still image, validates server-advertised limits, selects targets and Fit/Fill,
then stores a protected retry record before uploading. An interrupted request
is retried by the containing app with the same idempotency key and is purged
after 24 hours.

Shortcuts can push a saved Dashboard, send one still image to selected
displays, or open the paired Tesserae web UI. The image action uses the same
24-hour retry queue and idempotency guarantees as the Share Extension.

The live HTTP and Keychain paths are implemented against the reviewed
contract, but the current Tesserae server does not yet provide `/api/app/v1`.
Production compatibility therefore remains gated on an upstream release and
physical-device validation.

## Repository boundary

The iOS app lives in the public
[`charmmmz/tesserae-companion-ios`](https://github.com/charmmmz/tesserae-companion-ios)
repository because it has an independent Xcode, signing, App Store, issue, and
release lifecycle.
The Tesserae server repository should own only the server implementation,
server-facing OpenAPI integration, and server contract tests.

The repository is licensed under Apache-2.0. See [LICENSE](LICENSE),
[NOTICE](NOTICE), and [ATTRIBUTION.md](ATTRIBUTION.md).

## Licence

Tesserae Companion's original code and documentation are available under the
[Apache License 2.0](LICENSE). Tesserae itself is a separate project under
AGPL-3.0-or-later; using this client licence does not change the Tesserae
server's licence or grant rights to its name and marks.

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

Tesserae's maintainer has granted permission to use the Tesserae name and
mark for **Tesserae Companion**, subject to the community-built, privacy,
advertising, data-use, and web-feature boundaries recorded in
[`ATTRIBUTION.md`](ATTRIBUTION.md).

If maintenance stops, the companion maintainer will give advance public
notice and first seek to transfer the repository and App Store listing to a
mutually acceptable successor. If no responsible successor is available,
new distribution will stop rather than leave an unmaintained listing in
place, while the final source and release remain available where practical.
