# Changelog

All notable product, contract, design, and implementation changes to
Tesserae Companion are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
App releases follow [Semantic Versioning](https://semver.org/) where
practical. The planned App Store release 1.0.0 focuses on the accepted native
Companion surface; History and resend remain optional, server-gated
capabilities.

## [Unreleased]

### Added

- OpenAPI 0.5.0 optional `image_url_push` and `webpage_push` capabilities with
  separate idempotent asynchronous routes, strict public-network URL policy,
  canonical History correlation, and a fixed logical webpage viewport.
- Contract fixtures and stateful fixture-server coverage for remote-image
  fetches, one-render webpage fan-out, blocked private destinations, and the
  new Job kinds.
- OpenAPI 0.4.1 and Display cards now use the device's last-served full-frame
  preview and show an `Update pending` badge when Tesserae has rendered a newer
  frame that a sleeping REST display has not fetched yet. Older servers remain
  compatible, and transports without a served signal continue to show
  server-latest.
- Display cards now open a native details view with a larger current-screen
  preview, freshness and last-seen information, power and signal telemetry,
  hardware identity, firmware, and panel characteristics.
- Dashboard cards now open a one-time target chooser, defaulting to their valid
  bindings while allowing an explicit display override without editing the
  Dashboard on the server.
- Image sends remember the last valid display selection and layout per Tesserae
  instance across the app and Share Extension.
- The Send Image Shortcut now offers all five server-advertised layouts: Fit,
  Fill, Blur, Stretch, and Center.
- Activity now shows image sends waiting in the 24-hour Share/Shortcut queue,
  including their thumbnail, destination, fit mode, latest failure, and explicit
  Retry and Discard controls.
- Settings now offers a confirmed Clear Local Activity action that empties the
  current instance's Activity list and persistently hides existing server
  History on this iPhone without deleting canonical Tesserae server History.
- OpenAPI 0.4.0 optional `history` capability with cursor-paginated canonical
  History, ETag-backed composition previews, idempotent resend to original
  targets, fit-mode metadata, and exact Job-to-History correlation.
- Server-advertised `limits.image_fit_modes` with all five Tesserae modes and
  a backward-compatible Fit/Fill fallback when the field is absent.
- Capability-gated server History in Activity, including composition
  thumbnails, pull-to-refresh, pagination, resend, and correlation-based
  replacement of short-lived local Job progress.

### Changed

- The Companion webpage contract now explicitly reuses the Web UI manual
  Server preview's bounded Chromium queue, timeout, concurrency, and cache
  primitive while retaining a stricter no-LAN Companion trust policy.
- Display cards now show freshness using compact, accessible status glyphs
  beside the device name, distinguish states by both shape and colour, tighten
  hardware brand and model spacing, and omit the redundant orientation label.
- Settings now places the Disconnect action inside the Connection section so
  connection status, storage details, and lifecycle control stay together.
- Settings About now links directly to the Tesserae Companion GitHub repository
  instead of showing the redundant community-client label.
- Activity cards no longer show redundant disclosure chevrons; tapping a card
  with an available image still expands and collapses its preview.
- History cards now use a compact `Resend` action aligned with the status pill
  instead of a full-width action row.
- Activity now follows foreground sends for up to 30 seconds and reconciles
  unfinished Jobs during refresh, preventing a stale Sending card from
  lingering beside its correlated Published server History entry.
- Tightened the device-preview contract to the device-specific viewable result
  after image fit and panel geometry, while keeping History previews as source
  compositions used to identify what was sent. Displays accessibility labels
  now use the same device-specific terminology.
- Send and Share now expose Fit, Fill, and Blur as primary layouts,
  Stretch and Center as advanced choices, and simulate all five using the same
  geometry as Tesserae's server renderer.

### Fixed

- Activity now reconciles legacy or incomplete successful Companion Jobs with
  their canonical server History rows using a strict one-to-one match, avoiding
  duplicate cards when `history_event_ids` is unavailable.
- Button-triggered Fetched History rows now show the uniquely matching display
  name when the server row omits its `device_ids` snapshot.
- Activity pull-to-refresh now returns the list to its resting position
  immediately while History and pending Job reconciliation continue in the
  background. It also avoids overlapping refreshes and no longer retries queued
  image sends from the refresh gesture.

## [0.2.0] - 2026-07-29

### Added

- Machine-readable `/api/app/v1` OpenAPI 0.3.0 contract with JSON request,
  response, Job, quiet-hours, error fixtures, and optional binary previews.
- Contract tests that validate fixtures, endpoint coverage, unique operation
  IDs, mandatory write idempotency, and Job/result semantics.
- Swift fixture-decoding coverage and asynchronous Job polling in the mock
  client.
- Repository contribution, security, attribution, pull-request, and CI
  foundations for an eventual standalone iOS repository.
- Apache-2.0 project licence and NOTICE with explicit community-client and
  Tesserae attribution boundaries.
- Initial iOS 17+ SwiftUI application framework generated by XcodeGen.
- Four-tab native shell for Displays, Dashboards, Send, and Activity, plus
  onboarding, manual connection, settings, and demo flows.
- Local `TesseraeKit` Swift package with proposed Companion models, service,
  discovery, and credential-storage protocols.
- Fixture-backed server implementation and unit tests so the UI can develop
  without depending on unaccepted upstream endpoints.
- Live `URLSession` Companion client covering capability probing, pairing,
  session revocation, authenticated lists, Dashboard pushes, image multipart
  uploads, server errors, and asynchronous Job polling.
- Keychain-backed, device-only Companion token storage.
- Stateful local HTTP contract server and end-to-end Swift transport test.
- Embedded Share Extension target with reserved Bundle ID, App Group, and
  shared Keychain boundaries.
- App Group-backed connection snapshots with cached displays, dashboards,
  jobs, launch restoration, and explicit revoked-credential handling.
- `_tesserae._tcp.local` Bonjour browsing with resolved server addresses,
  retryable empty/error states, and manual fallback.
- Native QR scanning for canonical `tesserae://pair` and equivalent JSON
  payloads containing only a server URL and one-time code.
- Functional Share Extension with cached display selection, Fit/Fill,
  explicit quiet-hours override, server-advertised image validation, and
  direct Companion API upload.
- App Group-backed image retry handoff that reuses the original
  `Idempotency-Key` when the containing app resumes an interrupted transfer.
- App Intents and Shortcuts entities for pushing a Dashboard, sending one
  image, selecting displays, and opening the paired Tesserae web UI.
- Capability-based compatibility validation for the complete Companion API v1
  feature set, plus an upstream compatibility record for Tesserae `0.207.0`.
- Tesserae-aligned light and dark visual tokens and accessible status labels.
- Privacy manifests for the main app and Share Extension, including the
  required reasons for app-only and App Group UserDefaults access.
- A plain-language privacy policy, App Store privacy disclosure draft, and
  internal TestFlight preparation/test notes.
- Simplified Chinese localization for the primary app, pairing, permission,
  Share Extension, and Shortcuts surfaces.
- Actionable loading and empty states for Displays, Dashboards, and image
  targets, plus visible server failure details in Activity.
- Capability-gated device and Dashboard previews with authenticated PNG
  loading, ETag revalidation, asynchronous Dashboard preparation, and safe
  placeholder fallback.
- Bundled manufacturer marks for Seeed Studio, Pimoroni, TRMNL, Waveshare,
  and PicPak, sourced from each vendor's current official site or brand kit.
- Tesserae teal App Icon with a simplified iPhone and link mark.
- Local Activity photo thumbnails shared by the app, Share Extension, and
  Shortcuts, protected on disk and bounded to 30 days, 100 items, and 15 MB.
- Dashboard thumbnails open a native full-size preview with pinch and
  double-tap zoom without changing the list layout or drag-to-reorder gesture.

### Changed

- Light and dark screens now use Tesserae's ambient page treatment: the warm
  paper or slate base, a restrained teal glow near the top, and a faint
  24-point grid extending behind content and Settings, with stronger light-mode
  contrast so the texture remains visible on iPhone displays.
- Connection failures now use the persistent top status banner and Retry action
  without also presenting a duplicate blocking error alert.
- Dashboard favourites have been replaced by a per-server order that users can
  change with native long-press drag and drop; cards move continuously between
  targets with the same spring treatment used by Charm Player Home.
- Dashboard cards now match the compact split layout used by Displays, with
  metadata and actions on the left and a fixed-size preview on the right.
- Dashboard cards now use a compact `Push` action instead of the full-width
  `Send Now` button.
- Display cards now shape their panel preview placeholders from the server's
  actual width and height instead of stretching every display into the same
  landscape rectangle.
- Display cards now identify known hardware with its manufacturer mark and
  friendly model name instead of exposing the server's raw device-kind value;
  known marks adapt to light and dark appearance without a white backing, while
  generic protocols and unknown hardware retain a neutral fallback.
- Aligned the Companion contract with maintainer decisions: `/api/app/v1`,
  persisted asynchronous jobs, dedicated Companion credentials,
  `_tesserae._tcp`, dynamically advertised image limits, and JPEG, PNG,
  HEIC/HEIF, and WebP support.
- Separated Job lifecycle (`accepted`, `running`, `succeeded`, `failed`) from
  the terminal publish outcome (`published`, `quiet`).
- Established the iOS app as a separate public `tesserae-companion-ios`
  repository under Apache-2.0.
- Project status now distinguishes the runnable fixture-backed prototype from
  live Tesserae server compatibility.
- Manual connection now calls the proposed Companion API instead of switching
  to fixture data after URL validation.
- Recorded the upstream maintainer's permission to use the Tesserae name and
  mark, its privacy and product terms, and a concrete App Store handover path.
- Accepted 24 hours as the initial server-advertised Job and idempotency
  retention default.
- Relative server and Dashboard web-management paths are now resolved against
  the paired Tesserae base URL.
- Successful image sends now report server acceptance and point to Activity
  instead of describing the fixture-server implementation.
- Updated the project status with the first physical iPhone-to-display Share
  Extension validation against Tesserae `0.207.0`.
- The Share Extension now uses the same paper background, cards, teal accent,
  image preview, and target-selection treatment as the main app.
- The Displays header now keeps transport details in Settings instead of
  repeating the Companion API connection mode.
- Displays now uses compact two-column cards with device health and telemetry
  on the left and an aspect-correct panel silhouette on the right; the
  redundant server-status card has been removed.
- Send now previews the first selected display at its real panel aspect ratio
  and updates immediately between Fit letterboxing and Fill cropping, matching
  Tesserae's web Send preview. Multi-display sends remain rendered separately
  by the server for each target.
- Activity photo cards now show the actual sent image on the left and expand
  it inline when tapped. The fixed thumbnail remains in place while one
  pre-decoded image expands below it, avoiding the previous multi-stage morph.
- The Send panel preview now opens the system photo picker when tapped, without
  a separate Choose Photo button.

### Fixed

- Settings now refreshes the displayed Tesserae server version after launch
  restoration and manual refresh instead of retaining the version captured
  when the Companion was first paired.
- Kept the Send button's label in the layout while showing its progress
  indicator, preventing the button from changing thickness during upload.
- Dashboard previews now request and adopt the first bound display's panel
  shape, so portrait artwork fills the thumbnail instead of showing side bars.
- Send reserves a stable preview slot and retains a preview target while display
  selections change, preventing the Displays list from jumping vertically.
- Corrected the Apple Developer Team identifier used by automatic signing so
  the app and Share Extension can create provisioning profiles and deploy to
  physical devices.
- Corrected the XcodeGen resource phase so asset catalogs, privacy manifests,
  and localized resources are embedded in the app and Share Extension.
- Kept Bonjour delegate isolation compatible with the Xcode 16.4 toolchain
  used by GitHub Actions.
- Normalized non-upright EXIF image orientation into the uploaded pixel matrix
  so Photos and Share Sheet images do not rotate on the display.
- Added a real selected-image preview to the main Send screen.
- Merged Share Extension Job records when the main app becomes active so shared
  photos appear in Activity and continue polling to a terminal result.
- Reduced Share Extension memory pressure by using ImageIO to rotate and
  downsample shared photos directly to the largest registered panel edge
  instead of decoding and re-encoding the full-resolution source with Core
  Image.
- Constrained the main app and Share Extension image previews to the selected
  panel canvas and applied the same centered Fit letterboxing and Fill cropping
  geometry as Tesserae's server renderer, preventing preview images from
  overflowing their screen frames.

### Security

- Companion bearer tokens are stored in Keychain with
  `AfterFirstUnlockThisDeviceOnly` accessibility and are never placed in the
  App Group.
- Local HTTP is limited to iOS local-network transport policy; public HTTPS
  continues to use platform certificate validation.
- Temporary network failures retain cached connection metadata and Keychain
  credentials; only an authenticated `401` or missing credential requires
  pairing again.
- Bonjour discovery never authenticates a client; all discovered instances
  still require purpose-specific pairing.
- Shared original images are protected on disk, removed immediately after
  server acceptance, and purged after 24 hours when an interrupted upload
  cannot be completed. Activity retains only a protected 480-pixel JPEG
  thumbnail, automatically bounded to 30 days, 100 items, and 15 MB.

## [0.1.0] - 2026-07-26

### Added

- Initial Tesserae Companion product and technical design.
- Combined V1 and V1.5 scope for the planned 1.0.0 release.
- Native Swift 6 and SwiftUI architecture.
- Tesserae-aligned visual tokens and community-client App Store position.
- Household onboarding, Bonjour discovery, QR/manual fallback, display
  overview, dashboard push, and in-app photo-send requirements.
- Share Extension, retry queue, App Intents, Shortcuts entities, History,
  resend, defaults, and multiple-instance requirements.
- Proposed scoped `/api/app/v1` server contract.
- Proposed one-time pairing and revocable app-token model.
- Proposed `_tesserae._tcp.local` service alongside Tesserae's existing
  generic HTTP advertisement.
- Security, privacy, accessibility, localization, testing, release, and
  maintenance requirements.
- Decision log, maintainer questions, and release definition of done.

### Security

- Explicitly rejected firmware device tokens, the global webhook token,
  Flask session automation, internal admin JSON, and privileged MCP as
  Tesserae Companion's long-term API boundary.
- Required Keychain storage, scoped credentials, revocation, redacted
  diagnostics, direct-to-instance photo transfer, and idempotent writes.

[Unreleased]: https://github.com/charmmmz/tesserae-companion-ios/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/charmmmz/tesserae-companion-ios/releases/tag/v0.2.0
[0.1.0]: https://github.com/charmmmz/tesserae-companion-ios/commit/6519c5c
