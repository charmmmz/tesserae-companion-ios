# Tesserae Companion — Product and Technical Design

| Field | Value |
| --- | --- |
| Status | Official iOS app implementation draft |
| Document version | 0.4.0 |
| Last updated | 2026-08-01 |
| App name | Tesserae Companion |
| Planned first release | 1.0.0, focused on the accepted native Companion surface |
| Client | Native iOS, Swift 6, SwiftUI |
| Deployment target | iOS 18 or later |
| Upstream reviewed | `dmellok/tesserae` `main` at `76521718411ff0632920b2daa4ace19bc4e6d098` |
| Reviewed source version | Tesserae 0.208.0 |

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
6. **Clear official identity.** Describe Tesserae Companion as the official
   native iOS app while keeping its separate repository, publisher, licence,
   and operating responsibilities explicit.

## 2. Scope

The first App Store release combines the V1 foundation with the native
integrations that justify an iOS app: Share Sheet and Shortcuts. Read-only
previews and canonical History/resend are optional server capabilities. They
remain follow-ups for the Tesserae server and do not block the first stable
Companion release.

### V1 — household control foundation

| ID | Capability | Acceptance summary |
| --- | --- | --- |
| V1-01 | Discover Tesserae | Find compatible instances through Bonjour; manual URL and QR remain available. |
| V1-02 | Pair and reconnect | Pair with a one-time code, keep a revocable scoped token in Keychain, and reconnect without entering a password. |
| V1-03 | Instance overview | Show server name/version/reachability and a clear recovery path when unavailable or incompatible. |
| V1-04 | Display overview | List displays with name, panel type, raw last-seen time, freshness, battery when known, signal when known, and firmware when known. |
| V1-05 | Dashboard browser | List saved dashboards with bindings and favourites without forcing renders. |
| V1-06 | Push dashboard | Send a selected saved dashboard to its bound displays or an explicitly selected compatible display. |
| V1-07 | Send a photo in-app | Select a photo, preview server-advertised image layouts, choose target displays, and submit it to Tesserae. |
| V1-08 | Open web management | Deep-link to the appropriate Tesserae web page for editing and advanced management. |
| V1-09 | Accessible native UI | Support Dynamic Type, VoiceOver labels, Reduce Motion, light/dark appearance, and non-colour status cues. |
| V1-10 | Read-only previews | Lazily show the latest full display composition and cached Dashboard visuals when the server advertises `previews`; retain aspect-correct placeholders otherwise. |
| V1-11 | Canonical Activity | When the server advertises `history`, merge canonical push History, composition thumbnails, pagination, and resend into Activity without adding another top-level tab. |

### Video and Live Photo frame selection

The in-app Send and nearby Bluetooth composers accept photos, videos, and Live
Photos through the system Photos picker. A video adds a thumbnail timeline
directly below the existing display preview. Small, coalesced frame requests
update the preview throughout a drag. Releasing the timeline commits the precise,
full-size still used for sending; Send stays disabled until this frame is ready.
The existing framing and Send actions remain the completion path. There is no
separate editor or frame-confirmation step.

Live Photos initially use their supplied primary photo, with the Key Photo
thumbnail and timeline visible immediately. Motion loads in the background
without blocking the primary photo; Key Photo restores the original still
without hiding the timeline. Sharing a video or a Live Photo with motion available
uses the same controls for server and Bluetooth destinations. Only the selected
still image enters the existing delivery protocol. Decoding is bounded to the
target size, respects video orientation, and normalizes HDR frames to SDR.
Pending or superseded frame requests cannot be submitted; changing a frame
preserves manual framing and invalidates old subject analysis.

The Share Extension also recognizes Live Photo type declarations when the host
cannot vend a `PHLivePhoto` object. If the shared motion cannot be read, a compact
Choose Live Photo action opens the system picker filtered to Live Photos. This
does not request library authorization or discard the shared key photo on cancel.
The selected asset feeds the same timeline and preserves the chosen destinations.

### Post-1.0 photo framing roadmap

Manual photo composition is split into independently reviewable layers:

1. **Contract foundation (accepted 0.6 draft):** carry normalized focus and zoom,
   gate it with `image_framing`, and define mixed-target resolution precisely.
2. **Tesserae adapter:** validate the request, resolve one `SourceCrop` per
   target using the renderer primitive merged in upstream PR #175, and retain
   the original intent for History and re-targeting while keeping resolved
   rectangles internal.
3. **Native editor:** when the capability is present, add drag and pinch
   gestures to the in-app photo preview and send the normalized intent. Keep
   the current layout-only flow on older servers; Share Sheet and Shortcuts may
   remain centered Fill initially.

This keeps rendering server-authoritative while allowing a single user framing
choice to work across portrait and landscape displays. Rotation remains a
later extension rather than part of the first framing slice.

### Post-1.0 Lineups roadmap

Lineups move into the app in two server-gated phases. The first phase is read
and control: show the complete definition and live state, open advanced records
on the web, allow `next`, `previous`, and `play` controls, and expose an
enable/disable toggle. Paint actions use Jobs and History; enable/disable uses
the same action endpoint but returns the updated Lineup synchronously and does
not refresh a panel.

The second phase adds server-gated native authoring for daily, interval/Keep
Fresh, cycle, and manual Lineups. It uses the server's unified web/app builder,
an optional per-client `lineups:write` grant, and partial `If-Match` edits. The
app never infers authoring permission from read/control access and never reduces
an advanced read-only record to the fields the native editor understands.
The `session_read` capability lets the app refresh the current token grant and
open the server-provided Companion settings route without re-pairing. Playback
uses the server's `resolved_device_ids`; an empty explicit binding is never
expanded into action authorization by the app.
Deleting Lineups and editing advanced conditions, navigation, home, priority,
or window behavior continue to open Tesserae Web.

### Post-1.0 Gallery roadmap

Gallery is a native high-frequency photo workflow rather than general plugin
administration. The first capability-gated slice browses internal and external
folders, creates internal folders, uploads Photos selections one image per
idempotent request, and hands an existing image into the current Send flow.
External host paths are never exposed and external folders remain read-only.
Delete, rename, move, and external-path management stay out until a separate
operator-granted destructive scope is designed.

Tesserae owns storage identity, validation, normalization, thumbnails, and
device eligibility. Companion owns Photos selection, upload queueing,
concurrency, progress, retry, previews, and navigation. Upload removes location
metadata server-side, bakes orientation into pixels, and preserves ICC colour
profiles.

Offline Album is the next accepted action inside a Gallery folder, independently
gated by `offline_albums` and the operator-granted `offline_albums:write` scope.
Its contract-first layer uses server-computed `frame_cache` support from the
latest usable heartbeat, optional reported capacity and frame limits, and a
non-mutating per-target preflight. It never infers eligibility from model names
or an SD-card allow-list. Unknown targets remain selectable with a caveat;
unsupported targets are refused. Ordinary Gallery and online Send stay
available for devices such as PicPak even when Offline Album is unsupported.

The resource uses ETag/`If-Match` for Web/App concurrency. Server responses own
normalized image order and authoritative per-target plans; the app never fills
missing capability limits itself. Older firmware may report only playback state
and observation time, so progress counts and manifest versions stay optional.
Conflict prompts use both the opaque Album ID and server-provided Album name,
while capability races fail the whole write with the affected device IDs.

The native setup UI remains a follow-up to the 0.13 contract and server adapter.
It will edit one Album per Gallery folder, show explicit takeover when another
enabled Album claims a target, and keep desired configuration distinct from the
last observed cached/playing state. Any later Lineups integration is one
Album-owned playback step rather than one generated Dashboard per photo.
Per-photo and per-target framing is a later additive slice and must enter cached
frame identity before the app exposes that editor.

### Native integrations included in release 1.0

| ID | Capability | Acceptance summary |
| --- | --- | --- |
| V15-01 | Photo Share Extension | Send one image from Photos, Files, Safari, or another share source without first opening the app. |
| V15-02 | Share retry queue | Preserve an upload when the server is temporarily unreachable and let the containing app retry or discard it. |
| V15-03 | App Intents | Provide Push Dashboard, Send Image, and Open Tesserae intents with discoverable parameters. |
| V15-04 | Shortcuts entities | Make paired instances, dashboards, and displays selectable as App Entity parameters. |
| V15-07 | Defaults and favourites | Remember a favourite dashboard and default photo targets per instance; expose them to the share extension and intents. |
| V15-08 | Multiple instances | Store more than one Tesserae instance and let the user choose an active instance. |

### iPad and iPhone Duo adaptation

The iOS target and Share Extension support both device families while retaining
an iOS 18 minimum. Displays use a persistent NavigationSplitView; compact windows
collapse into native navigation, and Lineups has an explicit return action in wide
windows. Dashboards use the full page with adaptive cards or a list, opening a
native settings when selecting the name, with a compact modal for preview and push. Photo composers keep their draft,
framing, target selection and submission state above adaptive regions. On iOS
27.1, wide composers use ArrangementView to respect active divisions; older
systems use a two-column layout. Compact and accessibility layouts remain scrollable.

Root pages and display details have an independent 56-point circular
Send button, 16 points from the trailing safe-area edge and 12 points above the
bottom navigation safe area. The tab container selects compact versus wide
placement: compact pages place it above bottom tabs; wide windows place one
shared button at the tab-container level, outside both split-view columns and
above the bottom safe area. Both use the same size and margins. The Send sheet
offers Close without a Settings shortcut.
Pressing Send darkens its solid fill and lowers the shadow, with a brief scale
and spring return unless Reduce Motion is enabled. Opening the composer gives
one light impact when haptic feedback is enabled; the 56-point target stays fixed.
Message hosts belong to page content inside navigation containers,
including modal stacks. Capsules float 8 points below the window's top safe area,
directly below the Dynamic Island/status bar. A non-key window presents them above
navigation and sheets; touches outside an actionable capsule pass through.
The independent Send button
keeps a fixed position when messages appear; scrolling content reserves its
height so the final item remains reachable. Transient confirmations do not move
content. Persistent/actionable messages reserve only their measured overlap with
page content. Navigation
titles and toolbars stay fixed. Gallery density follows the available width without
overwriting the saved preference. Resizing cancels an unfinished display
reorder without committing it. BLE connection ownership remains in NearbyDeviceManager;
window changes do not initiate a new connection. No server API changes are required.

Simple toolbar, modal and completion actions use SF Symbols with native button
chrome: checkmark for Save/Done/confirming a new Lineup, xmark for Cancel/Close,
and a chevron for Back. New Folder uses plus. The localized action title remains
the accessibility name when the visible label is icon-only. Connect, Review,
Send/Retry, Select All and destructive confirmations retain descriptive text.
Changing a label does not change permissions, disabled states or draft protection.

Nearby Bluetooth photo sends close the send sheet as soon as the device confirms
receipt. Only after dismissal, the presenting page shows a brief “Sent to <display>”
message capsule. The editor, sending progress and success message never appear
together. There is no separate success sheet or Done button; local-storage warnings
remain visible in the capsule.

### Shared page actions

Every page uses `TesseraeToolbarActions` from `App/Sources/DesignSystem` for its
trailing actions. `TesseraeRootToolbar` composes it with Settings.
Compact root pages use `.tesseraeRootPageChrome()` for message lifetime/spacing
and the independent Send button in the bottom safe area. App-level message
presentation belongs to `.tesseraeWindowMessageOverlay(center:)`.
The component owns the single native capsule, icon-only labels, 44 × 44-point
targets, 4-point spacing, symbol sizing, accent tint, and muted disabled state.
Feature views supply action semantics and availability; they do not override
button style, font, size, or capsule background.

```swift
.toolbar {
    TesseraeToolbarActions {
        Menu {
            // Descriptive secondary operations.
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        Button("Save", systemImage: "checkmark") { save() }
            .disabled(!hasChanges || isSaving)
    }
}
```

Keep native Back and modal cancellation/confirmation actions in their semantic
placements on opposite sides. Complex operations retain text. New ordinary
pages use the paper background, including nested Forms and Lists. These defaults
also apply to subsequent agent work through `AGENTS.md`; the UI conventions CI
check rejects direct trailing `ToolbarItem`/`ToolbarItemGroup` declarations outside
the shared component. Relevant simulator flows and screenshot inspection still
verify appearance and behavior.

Pushed selection pages follow the same rule, grouping Refresh and Done in the
trailing capsule. Custom sheet-header actions use
`.tesseraeModalChromeButtonStyle()` for consistent native chrome and minimum
44-point targets; ordinary sheets, including the Lineup duration picker, keep
the paper backdrop. Preview-overlay actions use `.tesseraeIconActionLabel()`
to preserve their target and symbol sizes at accessibility text sizes.

### Explicitly out of scope for release 1.0

- full Canvas/Dashboard layout or source-code editing;
- widget/plugin installation or global configuration;
- theme authoring;
- advanced schedule, navigation, condition, and deck editing outside the four
  native Lineup intents;
- firmware installation, calibration, and destructive device settings;
- a Tesserae cloud account or mandatory remote relay;
- APNs-based remote notifications;
- background Apple Health, Calendar, or Photos synchronization;
- exposing the experimental MCP authoring surface to the app;
- arbitrary server administration;
- Android, watchOS, macOS, or visionOS targets;
- independent multiwindow scenes or simultaneous inner/outer-display experiences.

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

### Native Dashboard settings

On compatible servers, Dashboard names open native settings. Content fields
are grouped by component; display bindings, update intervals and appearance
have separate pages. Component fields are searchable and grouped by control
type (selections, text, numbers, switches, and web settings), preserving server
order within each group. Rows show the title and current value; switches remain
editable inline. Other edits, help, defaults, clear and reset actions live on
the field's detail page. Unsupported controls retain their stored values and
show the server's read-only reason alongside the web editor shortcut.

Dashboard Settings opens with a large preview and an overlaid push button at
the top right. More and the accessible Save checkmark use the root-page toolbar
capsule, with equal 44-point targets and a muted disabled Save state. The icon
picker renders the same Phosphor glyphs as Dashboard cards, including the
existing icon when it is outside the curated choices.

A shared draft survives component and choice navigation. Ordered multiselect
retains saved or unavailable choices, supports priority changes, and does not
repeat selected rows among available choices. The explicit Save on Dashboard
Settings submits one revision-checked partial update. Conflicts preserve the
draft and require a confirmed reload; saving refreshes the preview without
pushing a frame. Leaving an unsaved draft requires confirmation.

`dashboard_settings` gates basic settings; `dashboard_component_settings`
additionally gates per-instance widget fields and scoped searchable choices.
`dashboards:write` is optional and requires an operator grant; existing pairings
retain read-only access until granted. Servers without these capabilities keep
preview/push and the web shortcut. Layout, code and global plugin management
remain in the web editor.

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

The existing display selector includes cached and nearby Bluetooth displays,
marked with the Bluetooth logo, alongside server displays. Explanatory text is
limited to transfer and actionable error states; the row's accessibility value
still names Bluetooth. Established device links and exact
peripheral UUIDs fold a known display into one row; names and partial MAC suffixes
do not establish identity. A saved Bluetooth display stays visible while absent
and cannot accidentally use the server route. Selecting a Bluetooth display
connects it and uses the same preview, Fit/Fill, framing, media-frame controls,
and Send action. Bluetooth currently uses one display session at a time; server
selection retains multiple targets. First-time authorization and configuration
remain in the main app. The extension closes only after the matching
`photo_received` receipt, never on the last packet acknowledgement, and errors
leave the page open. Metadata is published read-only by the app, while immutable
app-group receipts return confirmed previews without overwriting inventory.
Bluetooth sending does not require server pairing or enter the server retry queue.

Both the in-app photo Send and Share Sheet composers start nearby discovery on
entry. Remembered Bluetooth targets remain dimmed and disabled until their exact
peripheral is discovered; a connected, authenticated target remains available
when it stops advertising. Bluetooth selection is exclusive of every other target;
server targets retain multi-selection. Scanning and connection handshakes add no
status-log text to the composer. The share preview reserves one canvas and footer
slot across negotiated panel sizes, so changing aspect ratio does not move the
device list or discard per-aspect framing.


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
4. **Activity** — immediate Companion Job progress plus canonical server
   History and resend when supported.

Settings is presented from the instance switcher and contains:

- paired instances;
- default photo targets;
- favourite dashboard;
- web management;
- connection diagnostics;
- token removal/re-pair;
- About, official-app identity, privacy, acknowledgements, and
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
- Installed home-screen name: **Tesserae**
- Descriptor: **The official iOS companion for Tesserae**
- Use “official” only for the native iOS app designation; do not imply that
  the Tesserae server maintainer directly owns the Apple account, signs the
  binary, or publishes from the server repository.
- App icon: the official Tesserae tessellated mark, adapted only to provide
  the opaque edge-to-edge source required for the iOS platform mask.

### 5.2 Core visual tokens

The first Paper branding pass follows Tesserae's palette introduced in
0.448.0, with Paper made the default server theme in 0.449.0. Values are
implemented as adaptive colours in `SharedUI/TesseraeTheme.swift` so the app
and Share Extension use the same light and dark appearances. The app's
`AccentColor` asset mirrors the accent for system surfaces.

| Role | Light | Dark |
| --- | --- | --- |
| Brand foreground / tint | `#B03227` | `#E98476` |
| Solid action fill | `#B8352A` | `#C13C30` |
| Accent soft | `#F3DCD6` | `#3B211D` |
| App background | `#EEEAE1` | `#151412` |
| Surface | `#FFFDF8` | `#22211E` |
| Recessed surface | `#F1ECE1` | `#1E1D1B` |
| Success | `#3D7A3A` | `#8DBF7F` |
| Warning | `#805808` | `#D9B45A` |
| Danger | `#B8352A` | `#E58474` |
| Information / progress | `#2B4E9B` | `#7C9BE0` |

Ordinary screens, sheets and nested settings use the adaptive paper background.
Forms and Lists hide their system scroll background and apply
`tesseraeScreenBackground()`, including navigation destinations and selection
pages. Native grouped rows keep their semantic fills; custom icon-picker tiles
use the surface and accent-soft tokens. Full-screen photo viewers use a black
viewing canvas, and device previews preserve the content's original colours.

Brand foreground is for links, selection, and app identity. It has at least
4.5:1 contrast against the paper, card, recessed, and soft selection surfaces.
Native prominent buttons use the separate solid action fill. Completed actions
and healthy states use success; active operations use information; warnings
and failures have their own tokens. Danger and brand accent remain separate
roles. Solid action fills use a darker red so white labels stay readable. Status must include an icon and
label, never colour alone. Primary/secondary text, separators, control pressed
states, and native materials continue to use iOS semantic styles.

The mark stays ink `#1C1B19`, red `#D0493C`, and paper `#FFFDF8` in both
appearances. A thin edge makes the Onboarding mark visible on dark paper;
its internal tiles do not change. The App Icon uses the official full-bleed
square artwork and an opaque 1024 px export for the iOS platform mask.
Photos, server-rendered Dashboard previews, and manufacturer marks preserve
their original colours. Earlier icon concepts in `Design/` are historical
references and are not bundled in the app.

### 5.3 Typography and iconography

- Use the iOS system font and Dynamic Type, with system monospaced styles
  for device identifiers, versions, dimensions, and diagnostic values.
- Manufacturer logos scale with the adjacent caption text, preserving their
  proportions and fitting within narrow columns; model names can move below them.
  Prefer transparent vector artwork so enlarged marks retain smooth edges.
  Measure horizontal spacing from the visible artwork: discard transparent
  canvas padding before applying the shared 4-point logo-to-model gap. Preserve
  the original asset rendering and scale the mark down when its column narrows.
- Hardware labels cover the upstream hardware catalog and named device adapters.
  epdiy and CrossPoint retain platform/firmware names without claiming a manufacturer;
  NOTE4C identifies ZecTrix independently of its shared PicPak transport protocol.
- Use the bundled Phosphor regular icon font for server-selected Dashboard
  icons so identifiers match the web UI; keep SF Symbols for native
  navigation and controls.
- Keep native control behaviour, hit targets, focus, and accessibility
  semantics even when the surface styling follows Tesserae.

### 5.4 Component language

- Warm paper background with warm light or charcoal cards, without the
  previous ambient glow or decorative grid.
- Restrained 10–16 pt radii; pills only for compact states.
- Soft paper-like elevation, not glass-heavy layers.
- Brick-red actions and selection; independent semantic status colours.
- Retain native navigation, tabs, sheets, menus, gestures, and control
  feedback. Web fonts and the server's 2 px corner treatment are not part
  of this native branding pass.
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
| Display status | Foreground-only 15-second polling while Displays is visible; Companion API v1 has no event subscription endpoint |
| Shortcuts | App Intents and App Entities |
| Logging | `OSLog`, privacy annotations for URLs/tokens/user content |
| Dependencies | Local TesseraeKit plus the regular Phosphor 2.1.2 icon font for server-selected Dashboard icons |

The networking layer is protocol-driven so mocked contract fixtures can
exercise every feature without a running server.

### 6.3 State ownership

- Tesserae owns authoritative device, dashboard, render, and publish state.
- Keychain owns app tokens.
- The App Group owns cached instance metadata, display/dashboard summaries,
  defaults, favourites, and queued-share metadata.
- Queued image bytes live as protected files in the App Group and are
  deleted immediately after successful upload or user deletion.
- Successful image sends retain only a protected 480-pixel Activity thumbnail,
  bounded by age, item count, and total bytes. The app, Share Extension, and
  App Intents all address it by the server job ID.
- The UI may optimistically show a job as Queued but never as Sent until
  confirmed by server state.

### 6.4 Share Extension constraints

The extension must be small and deterministic:

- accept one image, video, or Live Photo, sending only a prepared still image;
- load cached targets instead of performing a full synchronization;
- normalize orientation and downsample before upload;
- obey the server-advertised encoded-byte and decoded-image limits;
- use shared Keychain access for the scoped token;
- request Bluetooth access for nearby discovery while the image composer is visible;
- reconnect only to authorized photo services; pair and configure in the app;
- complete within extension time and memory limits;
- write a recoverable local queue item if a network submission fails;
- never retain Photos library access beyond the shared item.

Video and Live Photo motion are used only for selecting a still frame. Multi-image
albums, RAW editing, and automatic background retry are out of scope.

### 6.5 Personal Data retention

Current Personal Data retention behavior: Reminders and Health each retain one
latest snapshot with a per-server choice of 1, 2 (default), 7, 30, or 90 days,
or Never. Finite choices respect the server's advertised maximum; Never requires
`personal_data_retention` and an explicit user selection. Sync applies a changed
choice even when contents are unchanged. Freshness continues to report data age
independently, and stopping sync with deletion removes the stored snapshot.
This is an optional extension to D-027; older servers retain finite deadlines.

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

Dashboard push and image-send requests require `Idempotency-Key`. Reusing a key with
the same request returns the original Job; changing the payload returns
`idempotency_conflict`. Dashboard settings PATCH instead uses the fetched page
and schema revisions for concurrency control.

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

Display cards are a single native button in VoiceOver order. The card reads
its name, freshness, and list position; hardware, battery, Wi-Fi, and pending
refresh remain available as accessibility custom content. Move Up/Down
remain available without a drag. Target rows report selection and Lineup
enablement uses a native switch. Full-screen photos support VoiceOver zoom
adjustments, and custom movement follows Reduce Motion.

Ordinary iPhones stay in portrait. iPad supports all orientations so system
window resizing remains available, and Duo retains window and fold adaptation.
Boundary checks preserve selected content and drafts when the device turns or
the available window changes. Native search, sheets, keyboards, and navigation
retain system interaction and appearance.

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
- [x] Implement Bonjour discovery and QR scanner.
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

- [x] Share Extension and retry queue.
- [x] App Intents and entities.
- [x] Activity backed by Companion Jobs.
- [x] Capability-gated canonical History, composition previews, pagination,
      and resend in Activity.
- [ ] Multiple instances and defaults.

### Phase 4 — release validation

- [ ] Contract tests against the minimum and current Tesserae releases.
- [ ] Physical iPhone tests with local-network permission reset.
- [ ] At least one REST/MQTT Tesserae-native display and one HTTP-polled
      device where available.
- [x] Share from Photos to a physical display.
- [ ] Share from Files and Safari.
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

- The iOS app maintainer owns the iOS repository and App Store account and
  operates them under Tesserae's official-app designation and brand terms.
- Tesserae's maintainer owns the server implementation and final shape of
  upstream APIs.
- Contract changes require review from both sides before either client or
  server treats them as stable.
- If the iOS app maintainer steps back, they will give notice and make
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
| D-002 | 2026-07-26 | Name the app Tesserae Companion and label it community-built. | Historical; identity clause superseded by D-026 |
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
| D-016 | 2026-07-28 | Use the Tesserae name and mark under the community-built, advertising, analytics, data-use, and free-web-feature terms in `ATTRIBUTION.md`. | Accepted; identity clause superseded by D-026 |
| D-017 | 2026-07-28 | Treat authenticated read-only previews as an optional additive capability with ETag revalidation and placeholder fallback. | Implemented upstream and in the client |
| D-018 | 2026-07-29 | Advertise image fit modes from server limits; prioritise Fit/Fill/Blur and keep Stretch/Center in advanced UI. | Accepted by upstream maintainer |
| D-019 | 2026-07-29 | Keep History thumbnails as source compositions, but make Displays use the device-specific post-fit preview. | Accepted by upstream maintainer |
| D-020 | 2026-07-29 | Add canonical server History and idempotent resend to Activity as an optional capability without adding another tab or exposing History administration. | Accepted by upstream maintainer |
| D-021 | 2026-07-30 | Add separate capability-gated image-URL and webpage Job routes; render or fetch once, then use existing per-target push fan-out. | Accepted by upstream maintainer |
| D-022 | 2026-07-30 | Reuse one bounded webpage-render primitive for Web UI manual preview and Companion push while keeping Companion on a strict no-LAN URL policy. | Accepted by upstream maintainer |
| D-023 | 2026-07-31 | Carry bare Phosphor Dashboard identifiers through Companion API 0.5.1, normalize legacy aliases in the client, and fall back to `cube` for missing or unknown names. | Accepted by app maintainer |
| D-024 | 2026-08-01 | Keep display cards and Current Screen tied to the last-served frame, and show an exact, separate Next Screen from optional Companion API 0.5.2 pending-render revision metadata. | Accepted by app maintainer |
| D-025 | 2026-08-01 | Use capability-gated normalized photo focus and zoom, resolved by Tesserae into a separate SourceCrop for each target; stage the contract and server adapter before enabling native drag/pinch UI. | Accepted by upstream maintainer |
| D-026 | 2026-07-31 | Designate Tesserae Companion as the official native iOS app while retaining the existing privacy, advertising, data-use, free-web-feature, repository, and publishing boundaries. | Accepted by both maintainers |
| D-027 | 2026-08-02 | Use Companion as an opt-in Reminders snapshot bridge under one strict `/personal-data` family; retain only the latest expiring value and keep ingestion separate from rendering until the unified scheduling model settles. | Accepted by upstream maintainer in Discussion #176 |
| D-028 | 2026-08-03 | Generalize Reminders additively: upload explicitly selected lists through `reminders` with anonymous publication IDs, let widgets select one uploaded list, and retain `reminders.fridge` server-side only for the already published fridge widget. The new Companion and Apple Reminders widget do not fall back or migrate legacy snapshots. | Accepted in Discussion #176 and merged in upstream PR #182; server adapter proposed in Draft PR #183 |

## 17. Open questions for maintainer review

1. Which Tesserae release should become the minimum supported version?
2. Which edge and stable releases should first advertise the optional 0.4.0
   image-fit and History extensions?
3. Which edge and stable releases should first advertise the optional 0.5.0
   image-URL and webpage extensions?
4. Should the initial Personal Data policy use the proposed 24-hour stale
   threshold and 48-hour maximum TTL, or different server-advertised values?

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

## Bluetooth display association

Bluetooth records use full hardware MACs obtained from authenticated BLE info.
To associate with a renamed server device, Companion submits only those known
MACs to the scoped device lookup and accepts unique IDs already in the current
inventory. Device lists neither provide nor persist MACs. Matching stays scoped
to the active connection, rejects ambiguity, and respects explicit manual
association overrides saved by earlier versions. Device Details no longer offers
a manual linking picker. Confirmed mode observations persist locally before
reporting through the `device_mode_observations` capability and
`PUT /devices/{device_id}/mode-observation` (requires `device_setup:write`). The
foreground task retries saved observations with backoff, using server-scoped
acknowledgements so offline work and server changes cannot lose pending modes.
Older servers keep local behavior. Reports contain mode, observation time and
`ios_ble` source. With `device_status_observations`, they also carry locally saved
battery percentages and firmware versions with their original read times; the
server stores them as advisory facts without changing delivery rules. Shared
photo receipts are imported before subsequent reporting.
Device Details also resolves firmware locally from the associated Bluetooth
record and server heartbeat, preferring the newer observation and Bluetooth
on a timestamp tie. Battery updates do not refresh the firmware read time.
