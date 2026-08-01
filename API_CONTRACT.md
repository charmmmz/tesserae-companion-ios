# Tesserae Companion API Contract

| Field | Value |
| --- | --- |
| Status | Implemented base contract plus maintainer-approved gated extensions |
| Contract version | 0.6.0 |
| Namespace | `/api/app/v1` |
| Authentication | Revocable per-client Companion bearer token |
| Machine-readable source | [`Contracts/app-v1.openapi.yaml`](Contracts/app-v1.openapi.yaml) |
| Example payloads | [`Contracts/Fixtures`](Contracts/Fixtures) |

This is the server surface used by the native Tesserae companion. It
complements the web UI rather than replacing it. The five base features form
the compatibility floor; `previews`, `history`, `image_url_push`,
`webpage_push`, and `image_framing` are additive capabilities.

The proposal reflects the maintainer reviews in
[Discussion #147](https://github.com/dmellok/tesserae/discussions/147),
[Discussion #159](https://github.com/dmellok/tesserae/discussions/159), and
[Discussion #160](https://github.com/dmellok/tesserae/discussions/160).
Dashboard editing, plugin administration, schedules, firmware controls,
History deletion/administration, and general server administration remain
outside this contract.

## Contract rules

- JSON uses `snake_case`; timestamps are RFC 3339 UTC strings.
- Identifiers are opaque stable strings.
- Unknown response fields are additive and safe for clients to ignore.
- The unauthenticated capability probe exposes no display names, dashboard
  names, secrets, or other household content.
- Authenticated calls use only `Authorization: Bearer <companion_token>`.
- Every write requires `Idempotency-Key`.
- Write responses are persisted asynchronous jobs and return `202 Accepted`.
- Tesserae remains authoritative for target validation, rendering, quiet
  hours, publishing, and resource limits.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/app/v1` | Unauthenticated capability and limit probe |
| `POST` | `/api/app/v1/pair` | Redeem a single-use Companion pairing code |
| `DELETE` | `/api/app/v1/session` | Revoke the presented client token |
| `GET` | `/api/app/v1/devices` | List stable display targets and lightweight status |
| `GET` | `/api/app/v1/devices/{device_id}/preview` | Read the last-served device-specific logical preview |
| `GET` | `/api/app/v1/dashboards` | List saved dashboards without forcing renders |
| `GET` | `/api/app/v1/dashboards/{dashboard_id}/preview` | Read or prepare an on-demand cached preview |
| `POST` | `/api/app/v1/dashboards/{dashboard_id}/push` | Push to bindings or explicit targets |
| `POST` | `/api/app/v1/images` | Upload one still image to explicit targets |
| `POST` | `/api/app/v1/image-urls` | Fetch and send one public image URL |
| `POST` | `/api/app/v1/webpages` | Render and send one public webpage |
| `GET` | `/api/app/v1/jobs/{job_id}` | Poll job lifecycle and terminal outcome |
| `GET` | `/api/app/v1/history` | List canonical push History with cursor pagination |
| `GET` | `/api/app/v1/history/{history_id}/preview` | Read the retained composition thumbnail |
| `POST` | `/api/app/v1/history/{history_id}/resend` | Republish to the original target snapshot |

The full request, response, header, security, and error schemas are in the
OpenAPI document.

## Discovery and pairing

The server advertises both:

- dedicated `_tesserae._tcp.local` for Companion discovery;
- existing `_http._tcp.local` for backward compatibility.

Manual URL and QR pairing remain mandatory fallbacks. A QR payload contains
only the base URL and a short-lived, single-use Companion code; it never
contains the long-lived token.

The client uses this canonical QR interchange form:

```text
tesserae://pair?base_url=<percent-encoded-http-or-https-url>&code=<one-time-code>
```

It also accepts the equivalent JSON object with `base_url` and `code` keys so
server-side renderers can migrate without exposing a credential. Both forms
are validated before the normal capability probe and pairing request run.

Companion pairing is a separate credential purpose from firmware pairing.
The server keeps a dedicated Companion registry with client name, explicit
scopes, last use, and independent revocation. Release 1 may issue one fixed
Companion role while still persisting its scopes:

```text
devices:read
dashboards:read
push:write
media:write
```

## Capabilities and resource limits

`GET /api/app/v1` advertises actual server limits rather than making the app
hard-code them. The initial fixtures use the maintainer's suggested starting
point:

- 25 MiB encoded upload limit;
- 8192-pixel maximum decoded image edge;
- JPEG, PNG, HEIC/HEIF, and WebP still images;
- 24-hour job and idempotency-record retention.

Contract 0.4.0 also allows `limits.image_fit_modes`. The current accepted
server vocabulary is `fit`, `fill`, `blur`, `stretch`, and `center`. A client
connected to a server that omits this field must assume only `fit` and `fill`,
which preserves compatibility with the implemented 0.2.0 base contract.

The maintainer accepted 24 hours as the initial server default for both
records. Retention remains server-advertised rather than hard-coded so it can
be tuned without an app release; clients must use the advertised values.

Contract 0.5.0 adds two independently advertised capabilities:

- `image_url_push` enables `POST /image-urls`;
- `webpage_push` enables `POST /webpages`.

Clients expose neither action unless its exact capability is present. Both
routes use the existing image-fit vocabulary and do not change the five-feature
compatibility floor.

Contract 0.5.1 adds an optional nullable `icon` property to each Dashboard.
It carries the same bare Phosphor identifier stored by Tesserae's web UI.
Clients may normalize legacy aliases and must fall back safely when the field
is absent, null, or unknown; this additive display metadata needs no separate
capability.

Contract 0.5.2 adds optional `pending_render` metadata to each Display. It
identifies the exact retained revision waiting for that device and supplies an
authenticated preview path. Passing its `revision` to the existing device
preview endpoint returns that exact frame; omitting the query continues to
return the last-served frame. This is additive metadata under `previews`, so
older compatible servers can omit it without a separate capability.

Contract 0.6.0 defines independently capability-gated photo framing:

- `image_framing` enables normalized focus and zoom on image uploads;
- `limits.image_framing_max_zoom` is required whenever that capability is
  advertised, so an editor never hard-codes the server range; the first
  accepted server value is `4`, as an editor bound rather than an image-quality
  promise;
- framing is accepted only with `fit: fill`; omitting it preserves the
  existing centered Fill result;
- the server resolves the same intent independently for every target panel,
  rather than applying one fixed crop rectangle to mixed aspect ratios.

Upstream PR [#175](https://github.com/dmellok/tesserae/pull/175) merged the
underlying normalized `SourceCrop` renderer primitive. It does not by itself
add this Companion capability, request field, validation, History persistence,
or resend behavior. The maintainer accepted the 0.6 contract shape in
[Discussion #147](https://github.com/dmellok/tesserae/discussions/147#discussioncomment-17861578);
its server adapter remains pending.

## Photo framing

`POST /images` may include this optional intent when the server advertises
`image_framing`:

```json
{
  "device_ids": ["picpak-kitchen", "e1004-desk"],
  "fit": "fill",
  "framing": {
    "focus_x": 0.62,
    "focus_y": 0.38,
    "zoom": 1.35
  },
  "override_quiet_hours": false
}
```

`focus_x` and `focus_y` are normalized coordinates in the
EXIF-orientation-normalized source image as displayed. Tesserae 0.225.0 applies
orientation normalization before `SourceCrop`; the Companion also bakes
non-upright orientation into upload pixels. `zoom: 1` means ordinary Fill;
larger values crop more tightly, up to the advertised maximum. For each target,
the server first derives its ordinary Fill crop from normalized source and
target aspect ratios, divides both crop dimensions by `zoom`, centers the
result on the requested focus, and clamps it inside the source bounds. The
OpenAPI `ImageFraming` schema defines the exact formula.

This target-independent intent is important when one send contains both
portrait and landscape displays: each panel receives a different source crop
while preserving the user's chosen subject and zoom. Rotation is intentionally
deferred from this first slice. History may return the original framing, and a
client may reuse that intent to reproduce or re-target the composition.
Resolved per-target rectangles stay server-internal because they are derived
from a particular target set. Original-target resend continues through the
canonical retained-composition path.

## Remote image URLs and webpages

The two URL-backed actions remain separate because their failure modes,
resource limits, and server machinery differ:

- `/image-urls` fetches one remote still image, retains that fetched source as
  the History composition, and then applies the selected fit to each target;
- `/webpages` performs one top-level Chromium render, retains that screenshot
  as the History composition, and then applies the selected fit to each target.

Both routes fetch or render once per Job at a logical source size. Mixed target
dimensions do not cause per-display webpage renders; the existing push fan-out
adapts the one composition for each target group.

`/webpages` accepts an optional advanced `viewport_w` from 200 through 4096
logical pixels and defaults to 1280 when it is absent. The server owns the
logical capture height; the first app UI does not need to expose either
dimension.

The Web UI's iframe remains a deliberately lightweight preview. A site may
block that iframe with `X-Frame-Options` or CSP even though a top-level
server-side Chromium render succeeds. The Web UI's optional manual Server
preview and Companion `/webpages` must share one bounded rendering primitive,
including its render queue, timeout, concurrency cap, and short cache:

- a manual Web UI preview returns a PNG without publishing or writing History;
- a Companion `/webpages` Job publishes to explicit targets and writes
  canonical History.

Sharing the rendering primitive does not merge the callers' trust policies.
Current operator-driven Web UI fetches may allow same-host or private-network
destinations. Companion bearer tokens must always use a strict public-network
policy that refuses private, loopback, link-local, reserved, unspecified, and
embedded-credential URLs, with equivalent redirect checks and no client
override. A server adapter must therefore pass an explicit strict policy into
the shared primitive rather than inheriting an operator `allow_local` setting.

## Display and dashboard reads

Display status exposes raw `last_seen_at` plus optional server-derived
`fresh`, `stale`, or `unknown`. It does not promise generic
online/sleeping/offline truth because many e-ink devices intentionally sleep.
REST devices may also include `has_pending_render`: `true` means Tesserae has
rendered a newer full frame than the one most recently handed to the device.
Older compatible servers omit the field, and transports without a reliable
served signal report `false`.

When Tesserae retains that newer frame, `pending_render` identifies its opaque
`revision`, optional render time, and authenticated preview URL. Clients use
the revision with `GET /devices/{device_id}/preview?revision=...` to show a
separate Next Screen without replacing the last-served Current Screen. The
server returns `404` if that exact retained revision is no longer available.

Dashboard lists contain stable IDs, names, kind, bound device IDs, and an
optional web-management URL. Listing dashboards never triggers preview
renders.

When the capability probe advertises `previews`, the device endpoint returns
the last-served device-specific viewable PNG for REST polling devices, with a
content-addressed ETag. This represents the last full frame handed out by
`/frame`, not proof that the physical refresh completed. MQTT and push
transports fall back to the latest server render. Image fit and panel geometry
must already be applied. Renderer-specific palette and quantisation should be
represented when the renderer can expose a reusable PNG from that stage. It is
still not a guarantee that a newer on-glass patch or overlay is included. It
returns `404` when no retained served preview is available.

The Dashboard endpoint returns a cached composition PNG, or `202` with
`Retry-After` while the server prepares one in the background. An optional
`device_id` selects target dimensions; otherwise Tesserae resolves the
Dashboard target or virtual panel. Both endpoints accept `If-None-Match` and
return `304` when the cached client image remains current. The app keeps its
aspect-correct placeholder whenever `previews` is absent or no image exists.

## History, composition previews, and resend

When the capability probe advertises `history`, Activity can combine immediate
Companion Job progress with canonical server History:

- `GET /history` returns push rows newest first with an opaque `before_id`
  cursor and server-bounded `limit`;
- rows include the source, friendly label, original target snapshot, outcome,
  optional error and duration, preview availability, server-computed
  resendability, the original image fit mode, and optional framing intent when
  known;
- `GET /history/{id}/preview` returns the retained composition PNG with
  ETag/304 semantics;
- `POST /history/{id}/resend` uses the same required `Idempotency-Key`,
  asynchronous Job, and quiet-hours policy as the existing writes.

A History preview always answers **what content was sent**. A dashboard
composition is already rendered at panel dimensions and is therefore close to
WYSIWYG before renderer-specific processing. A photo/file/URL composition is
the input image and does not represent its later Fit/Fill/Blur/Stretch/Center
or device treatment. The device preview answers **what full frame was most
recently served to that particular display**, while `has_pending_render`
indicates that a newer server render is waiting for its next wake.

V1 resend targets only the original device snapshot and republishes the
retained composition through the canonical server path. The original fit and
framing intent remain History metadata for reproduction or re-targeting;
resolved crop rectangles are not public state. Resend records a new History
row rather than mutating the original and returns `not_resendable` or
`not_found` when the retained composition is unavailable. A successful Job may include
`result.history_event_ids` so Activity can replace local Job progress with
canonical rows without timestamp heuristics.

## Writes, quiet hours, and jobs

All five writes accept:

- targets, with omitted dashboard targets meaning “use bindings”;
- `override_quiet_hours`, defaulting to `false`;
- a required `Idempotency-Key` header.

For dashboard push, image upload, image-URL push, webpage push, and History
resend, reuse of the same key and payload returns the original persisted Job.

The same credential, method, path, key, and payload returns the original job.
Reusing a key with a different payload returns `409 idempotency_conflict`.

Job lifecycle and business outcome are intentionally separate:

```json
{
  "job": {
    "id": "job_01JQUIET",
    "kind": "dashboard_push",
    "status": "succeeded",
    "target_device_ids": ["picpak-kitchen"],
    "created_at": "2026-07-28T15:00:00Z",
    "updated_at": "2026-07-28T15:00:01Z",
    "result": {
      "status": "quiet",
      "reason": "all_targets_in_quiet_hours",
      "device_ids": ["picpak-kitchen"]
    },
    "error": null
  }
}
```

- Lifecycle is `accepted`, `running`, `succeeded`, or `failed`.
- A successful outcome is `published` or `quiet`.
- `quiet` is not infrastructure failure; the server correctly respected
  policy without refreshing the target.
- A failed job has a stable machine `error.code` and safe diagnostic message.
- A History resend Job uses `kind: history_resend`.
- Remote-image and webpage Jobs use `kind: image_url_push` and
  `kind: webpage_push`.
- `history_event_ids`, when present, precisely correlate a terminal Job with
  the canonical History rows it created.

The app and Shortcuts respect quiet hours by default. Only an explicit
user-initiated Send/Share action may request an override.

## Client and server implementation boundary

The server implementation should be a thin adapter over existing Tesserae
stores, `PushManager`, and the shared bounded webpage-render primitive, not a
second delivery or Chromium pipeline. The iOS app does not use firmware tokens,
the global webhook credential, Flask session cookies, privileged MCP, or
internal web routes.

The client includes a live `URLSession` transport and the base write path has
been verified against an edge Tesserae server and physical display. Contract
0.4.1, 0.5.0, and accepted 0.6.0 extensions remain capability-gated until their
matching server implementations and compatibility evidence are recorded. For
0.6.0, the app sends normalized intent; Tesserae validates it, resolves a
target-specific `SourceCrop`, renders, persists History, and resends.

## Contract checks

From the companion repository:

```sh
python -m pip install -r Contracts/requirements.txt
python -m pytest Contracts
swift test --package-path Packages/TesseraeKit
```

The Python checks validate every fixture against its OpenAPI component,
operation ID uniqueness, required endpoint coverage, Job/result separation,
idempotency headers, image-fit fallback and expansion, History composition
semantics, resend correlation, strict URL policy, single-render webpage
semantics, EXIF-orientation-normalized crop resolution, and the stateful local
fixture server. Swift tests decode the same JSON files into `TesseraeKit`
models and exercise the rotated-EXIF JPEG fixture. With
`TESSERAE_FIXTURE_BASE_URL` set, they also exercise the live transport from
pairing through publish polling.

## Remaining decisions

- first stable Tesserae release containing the base contract;
- first edge and stable Tesserae revisions implementing contract 0.4.1;
- first edge and stable Tesserae revisions implementing contract 0.5.0;
- first stable Tesserae revision including the additive 0.5.1 Dashboard icon;
- first stable Tesserae revision including the additive 0.5.2 exact pending
  preview metadata;
- first edge and stable Tesserae revisions implementing the accepted 0.6.0
  `image_framing` adapter and History/re-targeting semantics;
- the exact reusable PNG stage each packed renderer exposes as its
  device-specific preview.
