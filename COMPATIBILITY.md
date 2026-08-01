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
