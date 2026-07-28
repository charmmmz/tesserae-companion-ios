# Tesserae Companion — Product and Technical Design

| Field | Value |
| --- | --- |
| Status | Maintainer-aligned implementation draft |
| Document version | 0.2.0 |
| Last updated | 2026-07-28 |
| App name | Tesserae Companion |
| Planned first release | 1.0.0, focused on the accepted native Companion surface |
| Client | Native iOS, Swift 6, SwiftUI |
| Deployment target | iOS 17 or later, subject to prototype validation |
| Upstream reviewed | `dmellok/tesserae` `main` at `23f9adba53af30a059722e842680b16efccd1554` |
| Reviewed source version | Tesserae 0.205.0 |

## 1. Purpose

Tesserae Companion makes Tesserae easier for a household to use every
day without rebuilding Tesserae's administration surface.

The app exists because several important iPhone workflows are awkward in
a PWA:

- discovering a server on the local network;
- pairing securely without copying long tokens;
- sending a photo from the iOS share sheet;
- exposing stable actions to Shortcuts, Siri, and Automations;
- showing a compact, native overview of household displays.

The app complements Tesserae. Tesserae remains the system of record for
devices, dashboards, rendering, scheduling, rotations, history, and
delivery.

### Product principles

1. **Native where native matters.** Use iOS system integrations instead
   of wrapping the web UI.
2. **Server-authoritative.** Do not duplicate Tesserae rendering,
   scheduling, or device state on the phone.
3. **Household-friendly.** A family member should be able to pair and send
   a photo without understanding IP addresses, MQTT, renderers, or device
   tokens.
4. **Local-first and cloud-optional.** A normal installation works
   entirely on the user's LAN. Tesserae Companion does not introduce a
   required relay or account service.
5. **Safe contracts over convenient internals.** Do not ship against
   Flask session scraping, internal editor JSON, or the privileged MCP
   API.
6. **Honest community identity.** The app must always identify itself as
   community-built rather than official.

## 2. Scope

The first App Store release combines the V1 foundation with the native
integrations that justify an iOS app: Share Sheet and Shortcuts. History,
resend, and render previews are follow-ups and do not block the first stable
integration.

### V1 — household control foundation

| ID | Capability | Acceptance summary |
| --- | --- | --- |
| V1-01 | Discover Tesserae | Find compatible instances through Bonjour; manual URL and QR remain available. |
| V1-02 | Pair and reconnect | Pair with a one-time code, keep a revocable scoped token in Keychain, and reconnect without entering a password. |
| V1-03 | Instance overview | Show server name/version/reachability and a clear recovery path when unavailable or incompatible. |
| V1-04 | Display overview | List displays with name, panel type, raw last-seen time, freshness, battery when known, signal when known, and firmware when known. |
| V1-05 | Dashboard browser | List saved dashboards with bindings and favourites without forcing renders. |
| V1-06 | Push dashboard | Send a selected saved dashboard to its bound displays or an explicitly selected compatible display. |
| V1-07 | Send a photo in-app | Select a photo, preview Fit/Fill, choose target displays, and submit it to Tesserae. |
| V1-08 | Open web management | Deep-link to the appropriate Tesserae web page for editing and advanced management. |
| V1-09 | Accessible native UI | Support Dynamic Type, VoiceOver labels, Reduce Motion, light/dark appearance, and non-colour status cues. |

### Native integrations included in release 1.0

| ID | Capability | Acceptance summary |
| --- | --- | --- |
| V15-01 | Photo Share Extension | Send one image from Photos, Files, Safari, or another share source without first opening the app. |
| V15-02 | Share retry queue | Preserve an upload when the server is temporarily unreachable and let the containing app retry or discard it. |
| V15-03 | App Intents | Provide Push Dashboard, Send Image, and Open Tesserae intents with discoverable parameters. |
| V15-04 | Shortcuts entities | Make paired instances, dashboards, and displays selectable as App Entity parameters. |
| V15-07 | Defaults and favourites | Remember a favourite dashboard and default photo targets per instance; expose them to the share extension and intents. |
| V15-08 | Multiple instances | Store more than one Tesserae instance and let the user choose an active instance. |

### Explicitly out of scope for release 1.0

- Canvas or dashboard editing;
- widget/plugin installation or configuration;
- theme editing;
- schedule, rotation, and deck editing;
- firmware installation, calibration, and destructive device settings;
- a Tesserae cloud account or mandatory remote relay;
- APNs-based remote notifications;
- background Apple Health, Calendar, or Photos synchronization;
- exposing the experimental MCP authoring surface to the app;
- arbitrary server administration;
- History/resend and server-rendered previews;
- Android, iPad-specific layouts, watchOS, macOS, or visionOS targets.

The existing web UI remains accessible from the app for these workflows.
They may be reconsidered only after release 1.0 usage validates the
companion model.

## 3. Primary user journeys

### 3.1 First household setup

1. User opens Tesserae Companion.
2. iOS explains why local-network access is needed, then requests it.
3. The app browses `_tesserae._tcp.local`.
4. A discovered card shows the instance name and address.
5. The user opens Tesserae's web UI, chooses **Pair Companion**, and scans
   the resulting QR code or types the short one-time code.
6. The app exchanges the code for a scoped app token.
7. The app stores the token in Keychain and non-secret instance metadata
   in the shared app-group container.
8. The user reaches the display overview.

If discovery fails, the same flow begins from a manually entered
`http://host:port` or `https://host` URL. Discovery is convenience, not
identity or authentication.

### 3.2 Send an existing dashboard

1. User opens **Dashboards**.
2. The app shows cached rows immediately, then refreshes them.
3. User selects a dashboard and reviews its bound displays.
4. User taps **Send Now**.
5. The server accepts an asynchronous job.
6. The UI moves through Queued → Sending → Published, or presents a specific
   quiet-hours or failed outcome.

The app must not claim that an e-ink panel has physically refreshed when
the server only accepted or published the render.

### 3.3 Send a family photo from the share sheet

1. User selects one image and taps **Share → Tesserae Companion**.
2. The extension loads cached instances and target displays from the app
   group without delaying the share sheet.
3. User selects Fit or Fill and confirms the targets.
4. The extension normalizes orientation and encodes a bounded upload.
5. If the instance is reachable, it uploads and displays the accepted job.
6. If unreachable, it safely queues the item and tells the user it will
   need to be retried from Tesserae Companion.

The extension never silently drops an image and never reports “Sent” for
an item that is only queued locally.

### 3.4 Run from Shortcuts

The user can create automations such as:

- “Send Morning Dashboard to Kitchen Display”;
- “Choose Photo and Send to Family Frame”;
- “Open Tesserae Management”.

Actions that publish content are explicit user actions. They should not
open the app when iOS allows them to complete in place.

## 4. Information architecture

The iPhone app uses four top-level areas:

1. **Displays** — household status and lightweight telemetry.
2. **Dashboards** — browse, favourite, and send saved dashboards.
3. **Send** — choose a photo and target.
4. **Activity** — recent Companion jobs and outcomes.

Settings is presented from the instance switcher and contains:

- paired instances;
- default photo targets;
- favourite dashboard;
- web management;
- connection diagnostics;
- token removal/re-pair;
- About, community-client disclosure, privacy, acknowledgements, and
  version compatibility.

On compact widths, the four areas use a native `TabView`. The app does not
embed the entire admin UI in a persistent `WKWebView`; it opens the
server's management pages in `SFSafariViewController` or the system
browser.

## 5. Visual design

The app should feel related to Tesserae while remaining recognizably
native iOS.

### 5.1 Brand position

- Product name: **Tesserae Companion**
- Descriptor: **Community-built client for Tesserae**
- Avoid “official”, “by Tesserae”, or language implying maintainer
  ownership.
- App icon direction: the Tesserae tessellated mark with a subtle
  companion distinction. Final use requires maintainer approval.

### 5.2 Core visual tokens

These tokens are derived from Tesserae's current admin system:

| Role | Light | Dark |
| --- | --- | --- |
| Accent | `#0D8C7E` | `#2DD4BF` |
| Accent pressed | `#0A6F63` | `#14B8A6` |
| Accent soft | `#E6F3F1` | teal mixed at 18% into the dark surface |
| App background | `#F1F0EC` | `#0E1015` |
| Surface | `#FFFFFF` | `#181B22` |
| Recessed surface | `#F4F4F2` | `#13161C` |
| Primary text | `#18181B` | `#E7E9EE` |
| Secondary text | `#52524F` | `#B6BCC7` |
| Muted text | `#71706C` | `#8B93A1` |
| Border | `#E6E5E1` | `#2A2F38` |

Additional Tesserae semantic accents may be used by role:
terracotta, ochre, moss, teal, slate-blue, and plum. Status must always
include an icon and label, never colour alone.

### 5.3 Typography and iconography

- Use bundled Inter when it does not compromise Dynamic Type; fall back to
  the iOS system font.
- Use JetBrains Mono only for device identifiers, versions, dimensions,
  and diagnostic values.
- Prefer Phosphor's Swift icons if the dependency is healthy and the
  licence is confirmed; otherwise map the same concepts to SF Symbols.
- Keep native control behaviour, hit targets, focus, and accessibility
  semantics even when the surface styling follows Tesserae.

### 5.4 Component language

- Warm paper background with white or charcoal cards.
- Restrained 10–16 pt radii; pills only for compact states.
- Soft paper-like elevation, not glass-heavy layers.
- Teal focus and primary actions.
- Dashboard thumbnails preserve the server-rendered image without
  recolouring.
- Device status cards use generous spacing and one clear primary action.
- Motion is limited to navigation, progress, and state transitions and
  respects Reduce Motion.

## 6. Native iOS architecture

### 6.1 Targets and modules

```text
TesseraeCompanion (SwiftUI app)
├── Features
│   ├── Onboarding
│   ├── Displays
│   ├── Dashboards
│   ├── Send
│   ├── Activity
│   └── Settings
├── TesseraeKit (local Swift package)
│   ├── API
│   ├── Auth
│   ├── Discovery
│   ├── Models
│   ├── ImagePipeline
│   ├── Persistence
│   └── DesignSystem
├── TesseraeShare (Share Extension)
└── TesseraeIntents (App Intents and App Entities)
```

`TesseraeKit` contains no app-specific UI and is shared by the app,
extension, intents, and tests.

### 6.2 Technology choices

| Concern | Choice |
| --- | --- |
| UI | SwiftUI |
| Concurrency | Swift structured concurrency and actors |
| HTTP | `URLSession`, Codable request/response models |
| Discovery | Network.framework `NWBrowser` / Bonjour |
| Secrets | Keychain, shared only with approved app targets |
| Shared non-secret state | App Group container |
| Small cache | Codable files in App Group, actor-isolated |
| Images | PhotosUI, Core Image/ImageIO, bounded JPEG/HEIF upload |
| Reachability | Request-driven state plus `NWPathMonitor` as a hint |
| Shortcuts | App Intents and App Entities |
| Logging | `OSLog`, privacy annotations for URLs/tokens/user content |
| Dependencies | None for the foundation unless an icon package is approved |

The networking layer is protocol-driven so mocked contract fixtures can
exercise every feature without a running server.

### 6.3 State ownership

- Tesserae owns authoritative device, dashboard, render, and publish state.
- Keychain owns app tokens.
- The App Group owns cached instance metadata, display/dashboard summaries,
  defaults, favourites, and queued-share metadata.
- Queued image bytes live as protected files in the App Group and are
  deleted immediately after successful upload or user deletion.
- The UI may optimistically show a job as Queued but never as Sent until
  confirmed by server state.

### 6.4 Share Extension constraints

The extension must be small and deterministic:

- accept one still image in release 1.0;
- load cached targets instead of performing a full synchronization;
- normalize orientation and downsample before upload;
- obey the server-advertised encoded-byte and decoded-image limits;
- use shared Keychain access for the scoped token;
- complete within extension time and memory limits;
- write a recoverable local queue item if a network submission fails;
- never retain Photos library access beyond the shared item.

Video, Live Photo motion, multi-image albums, RAW editing, and automatic
background retry are out of scope.

## 7. Server integration strategy

### 7.1 What exists today

The reviewed Tesserae server currently provides:

- `GET /healthz`;
- a versioned native **device** API intended for panel firmware;
- `POST /api/v1/push` using a global webhook token;
- TRMNL BYOS endpoints;
- render and preview artifacts;
- optional mDNS advertising as a generic `_http._tcp.local` service;
- privileged, experimental `/api/mcp` endpoints that can list and mutate
  Canvas content;
- session-protected HTML and internal JSON for the admin UI.

Its OpenAPI documentation explicitly excludes the web editor and internal
admin JSON from the stable external contract.

Reviewed upstream references:

- [OpenAPI contract](https://github.com/dmellok/tesserae/blob/23f9adba53af30a059722e842680b16efccd1554/schema/openapi.yaml)
- [OpenAPI scope and versioning guide](https://github.com/dmellok/tesserae/blob/23f9adba53af30a059722e842680b16efccd1554/docs/dev/openapi.md)
- [Current mDNS advertiser](https://github.com/dmellok/tesserae/blob/23f9adba53af30a059722e842680b16efccd1554/app/mdns.py)
- [Current send workflows](https://github.com/dmellok/tesserae/blob/23f9adba53af30a059722e842680b16efccd1554/app/send_routes.py)
- [Current History model](https://github.com/dmellok/tesserae/blob/23f9adba53af30a059722e842680b16efccd1554/app/history_routes.py)
- [Tesserae admin visual tokens](https://github.com/dmellok/tesserae/blob/23f9adba53af30a059722e842680b16efccd1554/static/style/base.css)

### 7.2 Integration decision

Tesserae Companion will depend on a dedicated, scoped, versioned
`/api/app/v1` contract described in [API_CONTRACT.md](API_CONTRACT.md).

It will not use:

- a firmware device token, because that token represents a panel;
- the global webhook token as the app's general credential;
- Flask session cookies or password automation;
- `/api/mcp`, because it is experimental and authoring-privileged;
- internal `/send`, `/history`, `/pages/*.json`, or editor endpoints.

The server may implement app endpoints as thin adapters over the existing
DeviceRegistry, PageStore, EventLog, and PushManager. The separation is a
security and compatibility boundary, not a request to duplicate business
logic.

### 7.3 Minimum server compatibility

Release 1.0 must declare the first Tesserae release that implements the
accepted app contract. Before that release exists:

- development uses contract fixtures and a clearly labelled adapter only;
- TestFlight must not imply general compatibility;
- the App Store build must reject unsupported servers with a useful
  upgrade message;
- capability negotiation, not a hard-coded version comparison alone,
  controls optional features.

### 7.4 Discovery

The current generic `_http._tcp` advertisement is useful for
`tesserae.local`, but a companion app should have a dedicated service:

```text
Type: _tesserae._tcp.local.
Name: Tesserae — <instance name>
TXT:
  path=/
  app_api=/api/app/v1
  api_version=1
  install_id=<stable non-secret identifier>
  tls=0|1
```

The server should continue its existing `_http._tcp` advertisement for
backward compatibility.

iOS configuration will include:

- `NSLocalNetworkUsageDescription`;
- `_tesserae._tcp` in `NSBonjourServices`;
- local-network transport allowances required for private HTTP hosts.

Discovery yields a candidate URL only. Pairing establishes trust.

## 8. Security and privacy

### 8.1 Authentication

- Pairing codes are single-use, short-lived, and issued from an already
  authenticated Tesserae admin session.
- The returned app token is random, revocable, instance-specific, and
  scoped.
- The token is sent only in `Authorization: Bearer`.
- Tokens are stored in Keychain and redacted from all logs and analytics.
- Removing an instance deletes its token, cache, defaults, and queued
  uploads from the phone.
- Tesserae exposes a list of paired companion clients with name, scopes,
  last use, and Revoke.

Required release-1.0 scopes:

```text
devices:read
dashboards:read
push:write
media:write
```

The server may issue the release-1.0 scope set as one “Companion” role,
but it should persist explicit scopes so later clients can be narrower.

### 8.2 Local HTTP

Many household installations use HTTP on a trusted LAN. The app supports
it with a clear “Local connection, not encrypted” label. It must not
present HTTP as safe over the public internet.

HTTPS certificates use normal platform validation. A self-signed
certificate trust workflow is out of scope for release 1.0; users can use
local HTTP or a certificate trusted by iOS.

The app does not implement certificate pinning because self-hosted
instances legitimately rotate hosts and certificates.

### 8.3 User content

- Photos go directly from the phone to the selected Tesserae instance.
- The companion project runs no image relay in release 1.0.
- No third-party analytics SDK receives server addresses, display names,
  photo metadata, thumbnails, or tokens.
- No third-party advertising SDK is included.
- Analytics or telemetry leaves the device only after explicit opt-in.
- User data is never sold or shared.
- Image metadata is stripped unless Tesserae explicitly needs orientation,
  which should be normalized into pixels before upload.
- Diagnostics are opt-in exports that redact credentials and user images.

## 9. Error and job model

Every write returns `202 Accepted` with a persisted Job. The app maps stable
machine codes to actionable messages without parsing English strings.

Job lifecycle and terminal business outcome are separate:

| Layer | Value | App behaviour |
| --- | --- | --- |
| Lifecycle | `accepted` | Show Queued and begin polling. |
| Lifecycle | `running` | Show Sending without promising delivery. |
| Lifecycle | `succeeded` | Read `result.status`; do not infer a refresh. |
| Lifecycle | `failed` | Show safe server detail and retain the Activity row. |
| Result | `published` | Show Published to server/panel transport. |
| Result | `quiet` | Explain that quiet hours were respected; an explicit user send may retry with override. |

Both dashboard and image writes require `Idempotency-Key`. Reusing a key with
the same request returns the original Job; changing the payload returns
`idempotency_conflict`.

An e-ink device may poll after the server publishes an artifact. The UI
language must distinguish “published” from a physically observed refresh
unless the device protocol provides that acknowledgement.

## 10. App Intents

### Push Dashboard

- Parameters: Instance, Dashboard, optional Displays
- Defaults: active instance, dashboard bindings
- Result: accepted job and concise status

### Send Image

- Parameters: Image file, Instance, Displays, Fit mode
- Defaults: active instance and saved photo targets
- Result: accepted job; prompts when a required target is unavailable

### Open Tesserae

- Parameters: Instance, destination (`home`, `devices`, `dashboards`,
  `send`, `history`, `settings`)
- Result: opens the web management URL

App Entities use stable server IDs, display friendly names, and refresh
from cache quickly. If a Shortcut references a deleted entity, it fails
with a clear reconfiguration message rather than silently choosing
another target.

## 11. Accessibility and localization

Release 1.0 requirements:

- English and Simplified Chinese localizations;
- Dynamic Type through accessibility sizes;
- VoiceOver order and explicit action labels;
- minimum 44×44 pt interactive targets;
- sufficient light and dark contrast;
- icons plus text for status;
- Reduce Motion support;
- no information conveyed only by an e-ink preview image;
- dates, times, and numbers formatted with the user's locale.

Server-originated names remain as entered by the administrator. Error
codes are localized in the app; optional server details remain verbatim
in a diagnostics disclosure.

## 12. Delivery plan

### Phase 0 — contract and collaboration

- [x] Publish this draft to Tesserae Discussions.
- [x] Confirm the app name and brand-use boundary.
- [x] Agree on `/api/app/v1`, pairing, scopes, job semantics, and mDNS.
- [x] Create compact OpenAPI examples and local contract tests.
- [ ] Land server contract tests and OpenAPI additions.
- [ ] Record the minimum compatible Tesserae release.

### Phase 1 — native foundation

- [x] Create the SwiftUI workspace and application target.
- [x] Implement TesseraeKit API models, protocols, and fixtures.
- [x] Implement live manual URL, one-time-code exchange, Keychain credentials,
      and authenticated Companion transport.
- [ ] Implement Bonjour discovery and QR scanner.
- [x] Persist non-secret instance metadata and restore saved connections
      without deleting credentials on temporary network failures.
- [x] Build the Tesserae-aligned design system foundation.
- [ ] Complete the accessibility harness.

### Phase 2 — V1 workflows

- [x] Displays overview.
- [x] Dashboard browse, bindings, favourites, and push.
- [x] In-app photo send.
- [ ] Web-management links and diagnostics.

### Phase 3 — native integration workflows

- [ ] Share Extension and retry queue.
- [ ] App Intents and entities.
- [x] Activity backed by Companion Jobs.
- [ ] Multiple instances and defaults.

### Phase 4 — release validation

- [ ] Contract tests against the minimum and current Tesserae releases.
- [ ] Physical iPhone tests with local-network permission reset.
- [ ] At least one REST/MQTT Tesserae-native display and one HTTP-polled
      device where available.
- [ ] Share from Photos, Files, and Safari.
- [ ] Shortcuts run with the app terminated and with the server offline.
- [ ] VoiceOver, largest Dynamic Type, dark mode, and Simplified Chinese.
- [ ] TestFlight household trial.
- [ ] Privacy manifest, App Store disclosure, screenshots, support URL,
      and maintenance policy.

## 13. Test strategy

### Automated

- Codable fixtures shared with accepted API examples.
- Local OpenAPI component checks plus contract tests against a live test server
  once the server implementation exists.
- Unit tests for URL normalization, capability negotiation, token
  redaction, image sizing, Fit/Fill math, queue persistence, and status
  mapping.
- Share Extension tests for unsupported types, large images, cancellation,
  and unreachable instances.
- App Intent parameter-resolution and deleted-entity tests.
- Snapshot tests for critical cards at light/dark and accessibility text
  sizes.
- UI tests for onboarding, pairing, send, re-pair, and instance removal.

### Physical-device gates

Simulator success does not validate:

- local-network privacy prompts;
- Bonjour discovery on a real LAN;
- Camera-based QR scanning;
- Share Extension memory/time behaviour;
- Shortcuts execution while the app is suspended;
- final e-ink delivery.

Each release candidate records the iPhone/iOS version, Tesserae version,
display model/transport, and observed outcome.

## 14. Release and compatibility policy

- App versions use Semantic Versioning where practical.
- `/api/app/v1` is additive within v1. Removing or changing an existing
  field requires `/api/app/v2` and a migration window.
- Unknown JSON fields are ignored by the app.
- Optional features are enabled by the capability response.
- The app supports at least the documented minimum Tesserae release and
  the latest stable release at submission time.
- Security-sensitive server minimums may be raised with a clear App Store
  release note and in-app upgrade guidance.
- User-facing and contract changes are recorded in `CHANGELOG.md`.

## 15. Governance and maintenance

- The companion maintainer owns the iOS repository and App Store account.
- Tesserae's maintainer owns the server implementation and final shape of
  upstream APIs.
- Contract changes require review from both sides before either client or
  server treats them as stable.
- If the companion maintainer steps back, they will give notice and make
  a practical transfer or successor-maintenance path available.
- The maintainer will first seek to transfer the repository and App Store
  listing to a mutually acceptable successor. If none is available, new
  distribution stops rather than leaving an unmaintained listing in place;
  final source and releases remain available where practical.
- Secrets, Apple account access, signing certificates, and App Store
  Connect roles are never committed to the repository.
- App Store ownership, signing access, and release permissions must be
  documented before the first external TestFlight.

## 16. Decision log

| ID | Date | Decision | Status |
| --- | --- | --- | --- |
| D-001 | 2026-07-26 | Build a companion, not a mobile copy of Tesserae admin/Canvas. | Accepted in maintainer conversation |
| D-002 | 2026-07-26 | Name the app Tesserae Companion and label it community-built. | Accepted by upstream maintainer |
| D-003 | 2026-07-26 | Use native Swift 6 and SwiftUI. | Accepted by app maintainer |
| D-004 | 2026-07-28 | Keep first stable integration focused; History, resend, and previews do not block release 1.0. | Accepted in upstream maintainer review |
| D-005 | 2026-07-28 | Require a scoped `/api/app/v1`; do not depend on MCP, firmware tokens, or admin internals. | Accepted in upstream maintainer review |
| D-006 | 2026-07-28 | Pair through a purpose-specific one-time code and store a revocable per-client app token in Keychain. | Accepted in upstream maintainer review |
| D-007 | 2026-07-26 | Keep release 1.0 local-first with no required companion cloud. | Proposed |
| D-008 | 2026-07-28 | Use a dedicated `_tesserae._tcp` advertisement while retaining existing `_http._tcp`. | Accepted in upstream maintainer review |
| D-009 | 2026-07-28 | Keep V1 photo handling server-authoritative via PushManager-backed asynchronous jobs. | Accepted in upstream maintainer review |
| D-010 | 2026-07-26 | Ship English and Simplified Chinese in release 1.0. | Proposed |
| D-011 | 2026-07-28 | Separate Job lifecycle from `published`/`quiet` terminal outcomes and require idempotency for both write routes. | Maintainer-aligned contract clarification |
| D-012 | 2026-07-28 | Keep the iOS app in the public `charmmmz/tesserae-companion-ios` repository under Apache-2.0. | Accepted |
| D-013 | 2026-07-28 | Use `com.charmmmz.tesseraecompanion` with a `.share` extension, shared App Group, and shared Keychain access group. | Accepted by app maintainer |
| D-014 | 2026-07-28 | Develop the live client against a stateful local contract server until upstream `/api/app/v1` ships. | Accepted by app maintainer |
| D-015 | 2026-07-28 | Use 24 hours as the initial server-advertised Job and idempotency retention default. | Accepted by upstream maintainer |
| D-016 | 2026-07-28 | Use the Tesserae name and mark under the community-built, advertising, analytics, data-use, and free-web-feature terms in `ATTRIBUTION.md`. | Accepted by upstream maintainer |

## 17. Open questions for maintainer review

1. Which Tesserae release should become the minimum supported version?
2. Which later release should add on-demand previews, History, and resend?

## 18. Definition of release 1.0 done

Release 1.0 is done only when:

- every release-1.0 acceptance criterion passes;
- the stable server contract is released and documented;
- unsupported server versions fail safely;
- local discovery, manual URL, and QR pairing work on a physical iPhone;
- a photo can travel from the iOS share sheet through Tesserae to a real
  display;
- all declared App Intents run from Shortcuts;
- English and Simplified Chinese, accessibility, privacy, and App Store
  disclosures are complete;
- the changelog, compatibility table, maintenance policy, and handover
  path are current.
