# Tesserae Companion API Contract

| Field | Value |
| --- | --- |
| Status | Implemented base contract with optional preview extension |
| Contract version | 0.3.0 |
| Namespace | `/api/app/v1` |
| Authentication | Revocable per-client Companion bearer token |
| Machine-readable source | [`Contracts/app-v1.openapi.yaml`](Contracts/app-v1.openapi.yaml) |
| Example payloads | [`Contracts/Fixtures`](Contracts/Fixtures) |

This is the server surface used by the native Tesserae companion. It
complements the web UI rather than replacing it. The five base features form
the compatibility floor; `previews` is an additive capability.

The proposal reflects the maintainer review in
[Discussion #147](https://github.com/dmellok/tesserae/discussions/147).
Dashboard editing, plugin administration, schedules, firmware controls,
History/resend, and general server administration remain outside this
contract.

## Contract rules

- JSON uses `snake_case`; timestamps are RFC 3339 UTC strings.
- Identifiers are opaque stable strings.
- Unknown response fields are additive and safe for clients to ignore.
- The unauthenticated capability probe exposes no display names, dashboard
  names, secrets, or other household content.
- Authenticated calls use only `Authorization: Bearer <companion_token>`.
- Dashboard and image writes require `Idempotency-Key`.
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
| `GET` | `/api/app/v1/devices/{device_id}/preview` | Read the latest full display composition |
| `GET` | `/api/app/v1/dashboards` | List saved dashboards without forcing renders |
| `GET` | `/api/app/v1/dashboards/{dashboard_id}/preview` | Read or prepare an on-demand cached preview |
| `POST` | `/api/app/v1/dashboards/{dashboard_id}/push` | Push to bindings or explicit targets |
| `POST` | `/api/app/v1/images` | Upload one still image to explicit targets |
| `GET` | `/api/app/v1/jobs/{job_id}` | Poll job lifecycle and terminal outcome |

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

The maintainer accepted 24 hours as the initial server default for both
records. Retention remains server-advertised rather than hard-coded so it can
be tuned without an app release; clients must use the advertised values.

## Display and dashboard reads

Display status exposes raw `last_seen_at` plus optional server-derived
`fresh`, `stale`, or `unknown`. It does not promise generic
online/sleeping/offline truth because many e-ink devices intentionally sleep.

Dashboard lists contain stable IDs, names, kind, bound device IDs, and an
optional web-management URL. Listing dashboards never triggers preview
renders.

When the capability probe advertises `previews`, the device endpoint returns
the latest full composition PNG with a content-addressed ETag. It represents
the renderer's latest composition, not a guarantee that a newer on-glass patch
or overlay is included. It returns `404` when no retained full composition is
available.

The Dashboard endpoint returns a cached composition PNG, or `202` with
`Retry-After` while the server prepares one in the background. An optional
`device_id` selects target dimensions; otherwise Tesserae resolves the
Dashboard target or virtual panel. Both endpoints accept `If-None-Match` and
return `304` when the cached client image remains current. The app keeps its
aspect-correct placeholder whenever `previews` is absent or no image exists.

## Writes, quiet hours, and jobs

Both writes accept:

- targets, with omitted dashboard targets meaning “use bindings”;
- `override_quiet_hours`, defaulting to `false`;
- a required `Idempotency-Key` header.

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

The app and Shortcuts respect quiet hours by default. Only an explicit
user-initiated Send/Share action may request an override.

## Client and server implementation boundary

The server implementation should be a thin adapter over existing Tesserae
stores and `PushManager`, not a second delivery pipeline. The iOS app does not
use firmware tokens, the global webhook credential, Flask session cookies,
privileged MCP, or internal web routes.

The client now includes a live `URLSession` transport against this contract,
but production compatibility remains gated until the matching server contract
is implemented and its minimum Tesserae release is recorded. The in-repository
fixture server is the only currently verified live endpoint.

## Contract checks

From the companion repository:

```sh
python -m pip install -r Contracts/requirements.txt
python -m pytest Contracts
swift test --package-path Packages/TesseraeKit
```

The Python checks validate every fixture against its OpenAPI component,
operation ID uniqueness, required endpoint coverage, Job/result separation,
idempotency headers, and the stateful local fixture server. Swift tests decode
the same JSON files into `TesseraeKit` models. With
`TESSERAE_FIXTURE_BASE_URL` set, they also exercise the live transport from
pairing through publish polling.

## Remaining decisions

- first Tesserae release containing the stable contract;
- later additive contracts for History and resend.
