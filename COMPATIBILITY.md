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
- reported Tesserae version: `0.205.1`;
- API contract: byte-for-byte identical to this repository's OpenAPI 0.2.0
  and JSON fixtures;
- upstream Companion test suite: 38 tests passed.

That commit was on upstream `main` but was not yet represented by a Tesserae
release tag at review time. The practical minimum is therefore “a Tesserae
build containing the complete Companion API v1 surface,” with `0.205.1` the
first known upstream product version, rather than a published minimum release.

Relative `web_url` values such as `/` and `/pages/pantry` are resolved against
the paired server URL before the app stores or opens them.
