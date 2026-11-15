# Cloud native read contract

This client contract covers the C1 native authorization API. It describes public request and response shapes, with synthetic examples, and contains no server implementation. The local connection contract remains `app-v1.openapi.yaml`.

The configured Cloud issuer supplies the OAuth endpoints. The public client is `tesserae-companion`, the exact callback is `com.charmmmz.tesseraecompanion:/oauth/callback`, and the protected resource is `${issuer}/api/t`. Native authorization uses PKCE S256 and single-use state. API keys and browser cookies are not App credentials. The native grant identifies one user and one tenant; API responses report the current membership role.

| Method | Path below `/api/t` | Response |
| --- | --- | --- |
| GET | `/bootstrap` | `{me, devices, pages}` as described by `cloud-app-read.schema.json` |
| GET | `/me` | The schema's `account` definition |
| GET | `/devices` | `{devices: [device]}` |
| GET | `/pages` | `{pages: [page]}` |
| GET | `/devices/{id}/frame.png` | Existing frame as PNG, or 404 when absent |
| GET | `/pages/{id}/thumb.png` | Existing preview as PNG, or 404 when absent |

Every request carries the runtime Bearer credential and requires `app:read`. First load uses one bootstrap request. Preview reads do not render or change the selected page. There are no native single-device or single-page detail endpoints in this contract; the corresponding list confirms that a resource still exists before a detail presents cached content. A missing preview is a placeholder, never a render request.

The client verifies the account's issuer, resource, user and tenant against the selected connection. Its models contain the read projection only. Pages have no editor code, data sources or connectors. Device frames have no internal storage keys. Numeric timestamps use Unix seconds. Null battery or last-seen values remain unknown. Limits are effective limits and null denotes unlimited; boolean features remain boolean. See `Fixtures/cloud-bootstrap.json` for a wholly synthetic account with both populated and missing previews.

JSON reads and device frames are `no-store`. Page thumbnails may be privately cached for 60 seconds and vary by Authorization and Cookie. The App bypasses the shared URL cache and scopes its in-memory images to the connection fence and resource. No conditional 304 behavior is assumed. Switching or signing out invalidates visible private data and in-flight UI updates.

| Status | Client meaning |
| --- | --- |
| 401 | A1 may renew and retry a safe read once. A repeated rejection requires sign-in recovery. |
| 403 | Access restricted; preserve the machine-readable `reason`, such as `membership_removed`, `tenant_unavailable`, `insufficient_scope`, or `resource_mismatch`. |
| 402 | Plan limit; retain the connection. |
| 404 | Resource or existing preview unavailable. |
| 429 | Rate limit; retain the connection and parse Retry-After when supplied. |
| 503 | Service unavailable; retain the connection. |
| Network failure | Offline recovery; no automatic credential removal. |

The web setup route is `${issuer}/app/#/setup`. The browser manages its own session and tenant, so the App must not imply that opening a web link transfers its native token. Cloud send, render, editing, Library and Lineups are outside A2.

Native photo submission and current-page refresh are described separately in [cloud-app-submission.md](cloud-app-submission.md).
