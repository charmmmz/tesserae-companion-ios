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

- Prepared the capability-gated Companion 0.8 Lineups read/control contract,
  complete advanced Deck-compatible Swift models, fixture server behavior,
  synchronous enable/disable controls, and Job-backed next/previous/play
  actions. Existing tokens re-pair to receive the new Lineup scopes; native
  authoring remains a separate contract.

### Changed

- Send now places display selection directly below Source and consolidates the
  photo preview footer into one centered `display name · resolution` selector,
  removes the repeated Previewing on label and file-size metadata, and uses
  consistent title-to-content spacing across sections.

### Fixed

- Preview controls now grow and reflow for larger Dynamic Type sizes instead
  of clipping text in fixed-height rows. The preview-display selector also
  becomes non-interactive and hides its menu chevron when fewer than two
  displays are selected, making its state clearer.
- Choosing a photo from the preview is now limited to the visible rounded image
  canvas instead of also responding to taps in the surrounding preview slot.

## [0.5.2] - 2026-08-05

### Added

- Dashboards can now switch between the existing preview-card layout and a
  compact, remembered list layout that hides artwork and keeps Push on the
  trailing edge of each row. Push confirmation still loads and shows the
  target-specific preview from either layout.

### Fixed

- Explicitly user-initiated Photo, Link, Dashboard, Share Sheet, and Resend
  actions now bypass quiet hours automatically, matching Tesserae's manual-send
  behavior while Scheduler, Rotation, and Shortcuts automations remain quiet.
- Dashboard lifted cards and the shared Dashboard/Display reorder labels now
  use their rounded outline as the drag-preview shape, removing the pale
  rectangular edge around Dashboard drags.
- Expanding Dashboard groups with many cards now keeps their view hierarchy
  warm, avoids repeated row-order work and full-group alpha masking, and
  defers preview refresh work until after the transition, reducing animation
  hitches while hidden card controls remain unable to receive taps.
- Dashboard groups now switch their content and disclosure state immediately,
  avoiding animated frame sequences when expanding or collapsing sections with
  many cards.
- Dashboard logos now use a consistent icon slot and vertical alignment with
  their names in both card and list layouts.

## [0.5.1] - 2026-08-04

### Changed

- Display cards, Dashboard display-group headers, and Display drag previews now
  use the display's server-configured Phosphor icon, with the existing panel-
  orientation symbol retained when an unknown icon slug is received. Display
  cards place freshness as a compact status dot on the icon so the brand and
  model row remains visually distinct.
- Dashboards are grouped under every display they are bound to, with independently
  collapsible group headers whose state is remembered per Tesserae instance, and
  an additional Shared Displays group for multi-display dashboards. Group
  transitions keep preview cards stationary while the section closes, reuse
  decoded preview artwork for smoother reopening, and prevent hidden controls
  from receiving taps. Opening a dashboard from
  one display keeps the preview
  confirmation sheet, removes repeated target metadata, and targets that display
  directly. Shared Displays retains the preselected bound-display picker for
  selective multi-display pushes, with scrolling prioritized over sheet resizing
  so changing a selection no longer jolts the sheet.
- Dashboard drag previews now use the same server-selected Phosphor icon as
  their cards. Display cards gain the same long-press drag ordering, retain
  their order per Tesserae instance across refreshes, apply that order to Send
  target and preview menus, and use a clearer display-shaped tab icon.
- Enabled Apple Reminders sync now performs a catch-up check whenever the App
  becomes active. Foreground and EventKit triggers share one debounced path,
  skip uploading unchanged content while the server snapshot remains fresh,
  and republish when content changes or the snapshot is missing or stale;
  Sync Now continues to force an upload.

### Fixed

- Display cards now distinguish a tap for details from a long-press drag, so
  display ordering can be changed reliably without the detail button consuming
  the drag gesture.

## [0.5.0] - 2026-08-03

### Added

- Personal Data settings can now request Reminders access, select up to 20
  lists, and enable, refresh, or delete one strict expiring snapshot. Once
  enabled, the App observes EventKit database changes for its full process
  lifetime, coalesces bursts for two seconds, and refreshes the selected lists
  when the App is active; a notification received while inactive is queued
  until the App returns to the foreground.
  The integration requires `reminders` in `personal_data.sources` and never
  falls back to the deprecated one-list `reminders.fridge` source. EventKit
  notifications do not provide a guaranteed background wakeup, so this first
  client slice still does not claim periodic or reliable background sync.
- Send Photo now supports drag-to-position, pinch-to-zoom, reset, and selected-
  display preview switching with a trailing-aligned, name-sized selector for
  Fill when the connected Tesserae server advertises image framing. Older
  servers and other fit modes keep their existing behavior.
- A proposed OpenAPI 0.7 Reminders bridge now defines the additive generic
  `reminders` multi-list source alongside the original `reminders.fridge`
  source, using anonymous app-generated list IDs, strict bounded fields,
  required expiry, metadata-only status, and immediate deletion.

### Changed

- Settings now uses a compact Server, Personal Data, and About hierarchy.
  Connection diagnostics and Disconnect live in Server Details, Clear Local
  Activity lives with Activity, and Apple Reminders shows its actual sync or
  compatibility state. The Reminders page also removes repeated capability and
  source rows, consolidates snapshot status, shortens its privacy and sync
  guidance, and includes Simplified Chinese localization.
- An enabled Apple Reminders bridge can now publish an empty list set after the
  final list is deselected, keeping the source fresh and making widgets show
  their unavailable state. Stop Sync remains the only action that deletes and
  disables the source.
- Project status and TestFlight documentation now reflect the first external
  beta submission instead of describing the app as an internal beta candidate
  or pre-upload artifact.
- Send Photo now exposes every server-supported Image Fit mode directly in the
  selector instead of placing Stretch and Center under More, and defaults new
  selections to Fill when available.
- Send Photo now gives its Preview image more visual priority: Change Photo
  sits in the header, resolution and file size share one caption, Fill framing
  controls appear over the image, hide during direct manipulation, and return
  two seconds after the gesture ends. The always-present display selector is
  presented as a dedicated Previewing on row, shows a stable placeholder when
  no display is selected, and remains visible but disabled when zero or one
  display is selected.
- Dashboards now refresh immediately when their tab becomes visible, continue
  revalidating while the app stays active, and reliably replace cancelled
  in-flight preview requests instead of showing stale content until relaunch.
- The maintainer-approved OpenAPI 0.6 photo-framing draft now uses the
  server-advertised `4×` editor bound and defines focus coordinates in
  EXIF-orientation-normalized source space, with schema-aligned framing errors
  and rotate-90 plus edge-clamp fixture coverage.
- Tesserae Companion now requires iOS 18. Dashboard Push measures its content
  to choose a matching sheet height, shows the Dashboard preview above its
  bound displays at its rendered image size, scrolls only when that content is
  long, and keeps its action button fully visible outside the scrolling region.
- Dashboard preview images now expand and collapse inside their cards like
  Activity photos instead of opening a separate full-screen zoom sheet.

### Fixed

- A selected Reminders list that was later deleted can now be removed directly
  from its unavailable warning, allowing the remaining lists to sync normally.
- Reminders without a due date are now uploaded with the contract-required
  `due_date: null` field instead of omitting the field and being rejected by
  strict servers.
- Grocery Reminders sync no longer crashes when EventKit delivers reminder
  fetch results on its background queue.

## [0.4.0] - 2026-08-01

### Changed

- Tesserae Companion now presents itself as Tesserae's official native iOS
  app across onboarding, Settings, repository identity, attribution, and beta
  metadata while keeping the **Tesserae Companion** App Store name and
  **Tesserae** home-screen name.
- Settings About now shows the official product status and the installed app
  version and build instead of a stale framework placeholder.
- The original name-and-mark agreement is retained as project history, with
  the later official-app designation superseding only its former
  community-built identity requirement; the privacy, advertising, data-use,
  free-web-feature, repository, and publishing boundaries remain explicit.

## [0.3.0] - 2026-08-01

### Added

- A proposed OpenAPI 0.6.0 `image_framing` capability now carries normalized
  photo focus and zoom for server-resolved Fill composition across mixed
  display aspect ratios, with contract fixtures and TesseraeKit transport
  models. Existing servers and unframed sends remain unchanged.
- Display hardware branding now recognizes Tesserae's Xteink X3, X4, X4
  grayscale, and X4 Pro device kinds.
- Display details now distinguish the last-served Current Screen from the exact
  pending Next Screen in one swipeable preview carousel when a Tesserae 0.5.2
  server retains that revision, with a stable header that does not shift the
  preview while swiping between screens.
- Dashboard cards now render the same Phosphor icon selected in Tesserae's web
  UI through the optional OpenAPI 0.5.1 `icon` field, including legacy-name
  normalization and a safe cube fallback for missing or unknown identifiers.
- TesseraeKit live and mock transports now submit remote image URLs and
  webpages through the OpenAPI 0.5.0 asynchronous Job routes, ready for clients
  to expose only when the corresponding optional capability is advertised.
- Send now offers a Link source when supported by the connected server, with
  separate Image URL and Webpage Snapshot actions and the existing display and
  layout choices.
- Activity identifies accepted link Jobs as Image URL or Webpage sends while
  retaining the server-provided URL label.
- The Share Extension now accepts one web URL, defaults ordinary links to a
  Webpage Snapshot when supported, allows switching to Image URL, and retains
  failed submissions for the app's 24-hour retry and discard flow.
- OpenAPI 0.5.0 optional `image_url_push` and `webpage_push` capabilities with
  separate idempotent asynchronous routes, strict public-network URL policy,
  canonical History correlation, and a fixed logical webpage viewport.
- Contract fixtures and stateful fixture-server coverage for remote-image
  fetches, one-render webpage fan-out, blocked private destinations, and the
  new Job kinds.
- OpenAPI 0.4.1 and Display cards now use the device's last-served full-frame
  preview. A subtle preview-corner indicator and an explanatory detail status
  show when Tesserae has rendered a newer frame that a sleeping REST display
  has not fetched yet. Older servers remain compatible, and transports without
  a served signal continue to show server-latest.
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

- Dashboard Push now lists only displays bound to that Dashboard, opens at the
  full-height sheet detent by default, and uses clearer bound-display wording.
- Onboarding now uses Tesserae's official tessellated logo instead of a generic
  system grid symbol.
- Hardware brand marks now use per-brand optical sizing, reducing the visual
  weight mismatch between compact glyphs and wordmarks such as Seeed Studio,
  PicPak, Waveshare, and Xteink.
- The App Icon now uses the official Tesserae tessellated mark. The App Store
  product name remains **Tesserae Companion**, while the shorter installed
  home-screen name is now **Tesserae**.
- Activity now refreshes immediately when opened and every 15 seconds while it
  remains visible in the foreground, so sends from the Tesserae web UI,
  schedules, and other clients appear without a manual pull. Existing immutable
  History thumbnails stay cached instead of being revalidated on every poll,
  while completed in-app sends continue to reconcile immediately.
- Display details now open directly as a large sheet instead of pushing a
  separate navigation page. While Displays is visible and the app is in the
  foreground, lightweight device status automatically refreshes every 15
  seconds.
- Display details present the `spectra_6`, `waveshare_e6`, and `e6` transport
  identifiers as the hardware-neutral `Spectra 6 · 6-color` label.
- The Companion webpage contract now explicitly reuses the Web UI manual
  Server preview's bounded Chromium queue, timeout, concurrency, and cache
  primitive while retaining a stricter no-LAN Companion trust policy.
- Display cards now show freshness using compact, accessible status glyphs
  beside the device name, distinguish states by both shape and colour, tighten
  hardware brand and model spacing, and omit the redundant orientation label.
- Settings now places the icon-labelled Disconnect action directly below
  connection status, ahead of the longer storage explanation.
- Clear Local Activity now uses a system alert and keeps its server-retention
  explanation there instead of repeating it below the Settings action.
- Settings About now links directly to the Tesserae Companion GitHub repository
  instead of showing the redundant community-client label.
- Activity cards now follow the Displays and Dashboards layout with metadata on
  the left, a consistent preview on the right, and a compact status glyph in
  the preview's top-right corner. Previews use the target display's panel
  dimensions, so rendered History and queued image fit modes reflect the
  device's actual aspect ratio and resolution without artificial gaps.
- History cards now use a content-width, filled `Resend` action matching the
  Dashboard `Push` control.
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

### Removed

- QR pairing and its camera permission. Onboarding now supports Bonjour
  discovery plus manual mDNS, IP, or reverse-proxy URL and one-time-code entry.

### Fixed

- Failed Dashboard sends no longer appear twice in Activity when the server
  emits both a target-aware Companion Job and a targetless History row; the
  retained card keeps the selected display name and error details.
- Activity now maps the complete set of server push, button, touch, and
  condition History outcomes to compact semantic status glyphs, so successful
  actions no longer appear as pending clocks and unknown future statuses remain
  visibly neutral.
- Completed sends now refresh device delivery state immediately. While Displays
  remains visible, a change in pending state or `last_seen_at` revalidates that
  display's ETag-backed last-served preview, so the pending indicator appears
  after a render and the card advances after the panel wakes and fetches it.
- Display preview refreshes can no longer become permanently stuck after a
  device-list update cancels an in-flight request; active Displays polling now
  revalidates each current-screen preview with its ETag every cycle.
- Authenticated previews now bypass URLSession's independent response cache
  and rely on the app's explicit ETag state, preventing an older cached body
  from replacing a newer current-screen image after revalidation.
- Display detail sheets no longer install a competing pull-to-refresh gesture;
  their telemetry continues to follow the foreground Displays refresh cycle.
- Cancelling an in-progress pull-to-refresh no longer marks a healthy Tesserae
  connection offline or shows a misleading `Could not reach Tesserae:
  cancelled` banner.
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

[Unreleased]: https://github.com/charmmmz/tesserae-companion-ios/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/charmmmz/tesserae-companion-ios/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/charmmmz/tesserae-companion-ios/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/charmmmz/tesserae-companion-ios/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/charmmmz/tesserae-companion-ios/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/charmmmz/tesserae-companion-ios/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/charmmmz/tesserae-companion-ios/releases/tag/v0.2.0
[0.1.0]: https://github.com/charmmmz/tesserae-companion-ios/commit/6519c5c
