# Cloud native submission boundary

Cloud uses direct render responses rather than the local server's idempotent
job protocol. The App must not represent a Cloud connection or result as a local
`TesseraeInstance` or `PushJob`. The [read contract](cloud-app-read.md) and native
OAuth resource checks still apply.

| Operation | Request below `/api/t` | Required scope |
| --- | --- | --- |
| Photo | `POST /send/image`, multipart `image`, `device_ids`, `fit`, `rotate` | `app:send` |
| Current page | `POST /devices/{id}/render` | `app:refresh` |

One photo request supplies one image and one fit/rotation to all its targets.
The App prepares an upright PNG/JPEG, at most 12,582,912 bytes, for each distinct
effective output geometry and submits it with `fit=fit`, `rotate=0`. Effective
geometry subtracts panel underscan on both edges. Native stride, rotation and
packing remain the server's responsibility. Each selected target belongs to
exactly one frozen upload task; switching preview screens preserves the existing
per-aspect framing controls.

A batch can contain multiple initial upload tasks. Each task receives at most
one automatic POST attempt. A generated response needs valid frame evidence;
HTTP 200 alone is insufficient. Duplicate/missing target rows and generic row
errors remain unknown because processing may already have taken effect. Decode
warnings remain visible even when a frame was generated. A proven structured
precommit rejection is refused. After refusal or uncertainty, later tasks are
not attempted. Current-page refresh never chooses a different page or patches
dashboard bindings or Lineup definitions. Rendering still replaces the current
frame and may clear a staged next frame.

Cloud results do not assert physical delivery. A generated frame becomes
available for the display's next wake. A lost response, interrupted process or
failed persistence cannot safely authorize another automatic send. Explicit
selected resend creates a new linked batch; generated targets are excluded by
default, and unknown or deliberately included generated targets require duplicate
confirmation. It preserves the source photo's absolute expiry.

Photos expire seven days after initial batch creation. A batch with all clean
generated results shortens its media deadline to the earlier of its current
deadline or 24 hours after completion. This also applies to an explicit resend
batch, which inherits the source photo's deadline and cannot extend it. Warnings
do not shorten the current deadline. Results expire 30 days after their own
creation. Viewing changes neither deadline. Delete/expiry logically hides media
before physical cleanup; a stale handle cannot restore access. Deleting a result
leaves a minimal closed decision receipt to prevent duplicate publication.

Local C1 integration and simulator tests do not replace deployed authorization,
email, signed app/extension Keychain sharing or physical-panel release checks.
