# Tesserae compatibility

Tesserae Companion negotiates compatibility from the unauthenticated
`GET /api/app/v1` capability document. It requires:

- product `tesserae`;
- Companion API name `companion` and version `1`;
- Companion pairing enabled;
- `devices`, `dashboards`, `dashboard_push`, `image_push`, and `jobs`.

This is deliberately not a hard server-version check. A downstream build or
backport can be compatible when it advertises the same stable API, while a
build carrying a newer product version is not assumed compatible if its
feature set is incomplete.

## First known upstream implementation

As reviewed on 2026-07-28:

- upstream commit: `3e4d481` (`feat: companion API phase 2`);
- reported Tesserae version: `0.207.0`;
- API contract: byte-for-byte identical to this repository's OpenAPI 0.2.0
  and JSON fixtures;
- upstream Companion test suite: 38 tests passed.

That commit was on upstream `main` but was not yet represented by a Tesserae
release tag at review time. The practical minimum is therefore “a Tesserae
build containing the complete Companion API v1 surface,” with `0.207.0` the
first known upstream product version, rather than a published minimum release.

Relative `web_url` values such as `/` and `/pages/pantry` are resolved against
the paired server URL before the app stores or opens them.

## Optional preview extension

The app enables server-rendered card previews only when the capability probe
advertises `previews`. Upstream commit `76521718` added the two authenticated
read-only endpoints, ETag revalidation, Dashboard `202` preparation, and the
conditional feature advertisement. The deployed Tesserae `0.208.0` capability
probe has been verified to advertise this extension.

Preview support is not part of `CompanionCompatibility.requiredFeatures`.
Servers implementing only the five base features remain compatible and receive
aspect-correct placeholders instead of broken image requests.

## Optional contract 0.4 extensions

OpenAPI 0.4.0 adds two independently negotiated extensions:

- `limits.image_fit_modes` advertises the exact image layout vocabulary. When
  absent, the client assumes `fit` and `fill`; current accepted servers may
  advertise `fit`, `fill`, `blur`, `stretch`, and `center`.
- the `history` feature gates canonical History listing, composition previews,
  and idempotent resend to the original target snapshot.

The device-preview path is unchanged, but its 0.4 semantic is tightened to the
device-specific viewable result after image fit and panel geometry rather than
the source composition. Older edge servers may continue to return the
composition until they adopt the updated semantic.

OpenAPI 0.4.1 further defines that preview as the last full frame served to a
REST polling device and adds optional `has_pending_render` metadata. Clients
that connect to an older server decode the missing field as unknown and keep
the existing preview behavior.

These additions are not part of `CompanionCompatibility.requiredFeatures`.
The app must continue to pair with a base 0.2-compatible server, hide History,
and limit image sending to Fit/Fill when the extension fields are absent.

## Optional contract 0.5 extensions

OpenAPI 0.5.0 adds two independently negotiated link-send extensions:

- `image_url_push` gates `POST /api/app/v1/image-urls`;
- `webpage_push` gates `POST /api/app/v1/webpages`.

Neither is part of `CompanionCompatibility.requiredFeatures`. A client must
hide each action independently when its capability is absent. The routes use
separate Job kinds and share the existing fit-mode vocabulary.

The webpage route performs one bounded top-level server render at a default
logical width of 1280, then uses the normal push fan-out for mixed display
dimensions. It shares the Web UI manual Server preview's render queue, timeout,
concurrency, and short cache, but the callers keep different side effects:
manual preview returns a PNG without History, while Companion publishes and
records canonical History.

Companion URL routes always use the strict public-network trust policy and
cannot opt into the Web UI operator path's local-network allowance. Private,
loopback, link-local, reserved, unspecified, embedded-credential, and
equivalent redirect destinations are refused.

## Accepted contract 0.6 image framing

OpenAPI 0.6.0 defines one independently negotiated extension for manual photo
composition:

- `image_framing` gates normalized `focus_x`, `focus_y`, and `zoom` metadata on
  `POST /api/app/v1/images`;
- `limits.image_framing_max_zoom` supplies the editor's upper bound and is
  required whenever the feature is advertised; the accepted initial value is
  `4`;
- framing is Fill-only and its absence retains the existing centered Fill
  behavior;
- Tesserae resolves the same intent independently for every target aspect
  ratio and returns the original intent with canonical History for reproduction
  or re-targeting; resolved rectangles remain server-internal.

This feature is not part of `CompanionCompatibility.requiredFeatures`. Current
servers remain compatible, and current app sends continue to omit framing.
Upstream PR [#175](https://github.com/dmellok/tesserae/pull/175) merged the
renderer-level normalized `SourceCrop` primitive, but not the Companion API
capability, request validation, adapter, History persistence, or resend path.
The contract fixture is therefore forward-looking and must not be treated as
evidence that an existing Tesserae release supports interactive framing.

Coordinates use the EXIF-orientation-normalized source image as displayed.
Tesserae 0.225.0 normalizes orientation before applying `SourceCrop`, and the
Companion normalizes non-upright upload pixels as well. The shared rotated-EXIF
fixture guards against resolving the crop against the stored landscape buffer
of a visually portrait image.

## Proposed contract 0.7 Reminders snapshot bridge

OpenAPI 0.7.0 adds a `personal_data:write` Companion scope and the
`/api/app/v1/personal-data` family. The legacy `personal_data_reminders`
capability and strict `reminders.fridge` source remain server-side support for
the already published fridge widget; the current Companion does not use them.

The additive `personal_data.sources` capability block exposes the strict
personal-data source IDs accepted by the server. Companion uses the generic
`reminders` source when listed and may publish up to 20 explicitly selected
lists and 200 incomplete items in aggregate. List IDs are opaque publication
UUIDs generated and persisted per server instance; EventKit calendar IDs are
never uploaded. Companion hides the integration unless `reminders` is listed,
and it never falls back to `reminders.fridge` or migrates an old snapshot.
Duplicate publication IDs and more than 200 aggregate items are rejected rather
than truncated. An enabled bridge may publish `lists: []` to atomically remove
its last selected list while keeping the source fresh; only Stop Sync uses
`DELETE` to disable the source.

The contract was accepted and merged in upstream PR
[#182](https://github.com/dmellok/tesserae/pull/182). The server adapter is a
separate follow-up in Draft PR
[#183](https://github.com/dmellok/tesserae/pull/183); the native permission and
sync surface and community widget remain independently versioned deliverables.

Snapshot ingestion does not create a Job, render a dashboard, publish to a
display, or write History before returning. A separate fire-and-forget event
adapter may subsequently feed semantic changes into the existing opt-in page
refresh path; its outcome never changes the PUT response.

## Proposed contract 0.10 Apple Health summary

Apple Health is independently gated. Companion requires both
`personal_data_health` in the top-level feature set and `health.summary` in
`personal_data.sources`; Reminders support never implies Health support. The
source reuses the existing `personal_data:write` scope, generic PUT/DELETE/status
routes, version-one envelope, ordering rules, 24-hour stale threshold, and
48-hour maximum TTL.

The snapshot is one atomic source with explicit nullable Activity, Sleep, and
Workouts sections covering the active instance's latest seven calendar dates.
Older clients ignore the new feature and source ID. A Health-capable client must
not expose enablement against a server that omits either capability signal, and
must not split the sections into independently expiring server records.

The seven-day content window is not a retention promise. The server retains
only the latest snapshot and deletes it at expiry or immediately after DELETE.
Semantic changes may emit source-wide `personal_data.health.summary` into the
existing opt-in page-refresh path after PUT returns; an envelope-only renewal
does not. Section selectors remain a future additive extension.

## Accepted contract 0.11 Gallery management

Gallery remains optional and is enabled only when `GET /api/app/v1` advertises
`gallery`. It is not part of `CompanionCompatibility.requiredFeatures`, so
older servers remain compatible and the app must hide the native Gallery
surface when the capability is absent.

Gallery-capable pairings receive `gallery:read` and `gallery:write`. The first
write slice is intentionally non-destructive: it creates internal folders and
uploads one image per idempotent multipart request. Delete, rename, move, and
external-path administration are not implied by `gallery:write`. External
folders remain browseable and carry `writable: false` without exposing their
host path.

Choosing Send for a Gallery image reuses the existing media push contract: the
client reads the authenticated Gallery content resource and submits those bytes
through `POST /api/app/v1/images`. It does not require Offline Album support and
does not add another delivery endpoint.

The server advertises Gallery-specific upload bytes, accepted media types, and
an advisory client batch size. Uploads are normalized server-side: location
metadata is removed, orientation is baked into pixels, and the ICC profile is
preserved. A client queues separate requests and does not infer a batch API.
Contract 0.12 distinguishes those accepted upload types from stored image
types: HEIC and HEIF uploads return JPEG resources, while an existing GIF or
BMP can be browsed even though Companion cannot upload a new one.

Folder creation also returns the authoritative normalized storage name. The
app must replace its pending input with the returned `GalleryFolder.name`
rather than assuming the spelling, case, spaces, or punctuation survive.

Optional `Device.capability_support` entries are computed from current device
reports rather than model names. Under the Gallery contract, `frame_cache`
distinguishes supported, unsupported, and unknown targets for a future Offline
Album surface; ordinary Gallery browsing and online Send do not require that
device capability. An unknown `stale_heartbeat` state retains the last report's
`observed_at`; the server owns the poll-cadence-aware freshness threshold.

The contract was accepted in
[Discussion #225](https://github.com/dmellok/tesserae/discussions/225), and the
first server adapter is available on Tesserae edge from v0.300.0. The native app
surface remains a separate capability-gated follow-up.

## Accepted contract 0.13 Offline Album authoring

Offline Album is independently enabled by `offline_albums`; `gallery` alone
never exposes the authoring action. The feature and its optional
`offline_albums:write` scope are not part of the compatibility floor, so older
servers and clients continue to browse Gallery and use online Send unchanged.
The app reads the current session grant and hides or explains writes without
invalidating a valid pairing.

The contract uses one nested Album resource per opaque Gallery folder. A
non-mutating preflight returns one server-computed target result per requested
display. `supported`, `unsupported`, and `unknown` come from runtime reports;
unknown remains selectable with its warning, while unsupported is refused.
Optional `frame_cache.detail.capacity_bytes` and `max_frames` values are usable
only when present. Missing capacity is unknown rather than zero and must not be
filled from a model or storage-card allow-list.

Preflight distinguishes fully offline frame count from partial capacity and
marks projected bytes as `exact` or `estimated`. PUT claims at most one enabled
producer per display and never silently replaces another Album. A 409 contains
the contested display-to-Album map; only an explicit `replace_conflicts: true`
request performs takeover, and it preserves every displaced Album and its
uncontested bindings. DELETE removes only the Album producer and bindings, not
the Gallery folder or source photos.

Tesserae edge v0.303.0 contains the prerequisite single-producer enforcement
and optional frame-cache detail advertisement. It deliberately does not yet
implement the Companion preflight or nested routes; clients must continue to
gate this surface on `offline_albums` rather than product version. Contract
fixtures, Swift models, and transport methods can land before that adapter and
native Library UI without claiming an end-to-end feature.

## Physical validation

On 2026-07-28, a physical iPhone paired with a Tesserae `0.207.0` deployment
and sent a Photos Share Sheet image through `/api/app/v1/images` to a Seeed
reTerminal E1004. The display refreshed successfully. That test exposed an EXIF
orientation mismatch in the original client; the current unreleased client
normalizes non-upright image pixels before upload.

Upstream PR
[#148](https://github.com/dmellok/tesserae/pull/148), merged as `4a9ae2b`,
also fixed the server renderer invariant: arbitrary uploads are fitted into
composition dimensions before the renderer reconciles the result with a
firmware-native row stride. This keeps landscape photos upright on
portrait-native ESP32 panels while leaving panel-sized dashboard compositions
unchanged.

After the server was updated to Tesserae `0.208.0`, the same paired iPhone
loaded the E1004's authenticated device preview and displayed the retained
full composition at the correct 1200 × 1600 portrait aspect ratio. Dashboard
preview preparation still needs a physical-device observation; its transport
and retry states are covered by client and contract tests.
