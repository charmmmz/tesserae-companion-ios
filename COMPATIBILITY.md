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

## Physical validation

On 2026-07-28, a physical iPhone paired with a Tesserae `0.207.0` deployment
and sent a Photos Share Sheet image through `/api/app/v1/images` to a Seeed
reTerminal E1004. The display refreshed successfully. That test exposed an EXIF
orientation mismatch in the original client; the current unreleased client
normalizes non-upright image pixels before upload.

After the server was updated to Tesserae `0.208.0`, the same paired iPhone
loaded the E1004's authenticated device preview and displayed the retained
full composition at the correct 1200 × 1600 portrait aspect ratio. Dashboard
preview preparation still needs a physical-device observation; its transport
and retry states are covered by client and contract tests.
