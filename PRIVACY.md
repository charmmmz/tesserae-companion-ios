# Privacy

Tesserae Companion is a direct client for a Tesserae server selected and
operated by the user. The app has no developer-operated backend, advertising
SDK, analytics SDK, tracking, or telemetry.

## Data flow

- Server addresses, display names, Dashboard names, Job summaries, and
  non-secret connection state remain on the device in the app's shared
  container.
- The per-client Companion bearer token is stored in the iOS Keychain with a
  device-only accessibility class. It is not stored in UserDefaults or in the
  App Group container.
- Photos selected in the app, Share Sheet, or Shortcuts are sent directly to
  the user's selected Tesserae instance. They do not pass through a service
  operated by the iOS app maintainer.
- Photos added to Gallery are queued only in memory while the import sheet is
  open and uploaded one at a time to the selected Tesserae instance. Tesserae
  removes location metadata, normalizes orientation, and retains the resulting
  Gallery image in server-owned storage; server operators control its retention
  and deletion. Companion keeps authenticated Gallery thumbnails only in
  memory.
- Display, Dashboard, and Gallery preview images are fetched directly from that instance
  only when it advertises the optional feature. The app keeps them in memory
  with their ETags and does not write them to the App Group or photo library.
- A photo whose upload is interrupted is stored with iOS file protection in
  the App Group so the containing app can retry it with the same idempotency
  key. It is deleted immediately after server acceptance or purged after 24
  hours if delivery cannot complete.
- After server acceptance, Activity stores only a protected JPEG thumbnail
  with a maximum edge of 480 pixels so the user can recognise what was sent.
  Thumbnails remain on device and are limited to 30 days, 100 items, and
  15 MB; the oldest entries are removed first.
- Bonjour browsing is limited to the local network and only discovers
  `_tesserae._tcp` candidates. Discovery does not authenticate or pair a
  client.
- Foreground Bluetooth browsing is limited to the Tesserae setup service. A
  nearby display advertises only a protocol version, setup state, and partial
  hardware suffix. Its temporary QR secret remains in memory for the active
  session; the six-digit fallback is handled by the iOS Bluetooth pairing
  sheet. A Wi-Fi name and password entered during setup are encrypted to that
  physically verified display and are not uploaded to the Companion server.
  The app keeps a local, per-server list of network names it configured; a
  password is stored in the device-only Keychain only when the user enables
  “Save password on this iPhone,” and can be forgotten from Nearby Displays.
  The app passes only a short-lived server-issued
  registration code to firmware and never receives the display's device token.

The Tesserae server separately controls its own storage, logs, Job retention,
and any data sources used by Dashboards. The current Companion contract asks
the server to retain Job and idempotency records for 24 hours; server
operators remain responsible for their own privacy policy and configuration.

## Apple Health bridge

The Apple Health extension has no developer-operated relay. It sends one
selected, expiring seven-date summary directly through the existing paired
connection to the user's selected Tesserae Server. The user independently
enables Activity, Sleep, and Workouts. Before the Apple authorization sheet,
Companion lists every HealthKit type it requests and every value the
corresponding section may upload. The app requests no Health write access.

The bounded snapshot may contain:

- daily steps, walking/running distance, Move, Exercise, and Stand values and
  goals;
- one normalized primary sleep episode per wake date, including its preserved
  start/end time and in-bed, asleep, awake, Core, Deep, REM, and unspecified
  totals;
- workouts with a stable per-instance opaque publication ID, normalized
  activity type, start/end, active duration, active energy, explicitly requested
  distance modalities, flights, swimming strokes, and bounded segment summaries.

Routes, coordinates, heart rate, raw samples, HealthKit UUIDs, device or source
identity, workout events, and free-form metadata never enter the contract.
Nullable fields remain null rather than becoming false zeroes. Apple does not
reveal each read denial to apps, so the snapshot does not claim or upload
per-type authorization status.

The server retains only the latest snapshot. It becomes stale using the
server-advertised 24-hour default, expires within the advertised 48-hour maximum,
and is deleted immediately when Health sync is disabled. Raw values are excluded
from ordinary logs, API errors, diagnostics, and backups. A normal live History
thumbnail may contain health values already rendered, and an e-ink display keeps
its prior image until another frame replaces it. Both limitations must be shown
before enablement and remain available on the persistent Health settings page.

The server operator is responsible for protecting the Tesserae server, network
connection, credentials, and access controls. The Health contract adds no
HTTPS-only policy or alternate transport path beyond the connection the user has
already selected for Companion.

## User controls

- Disconnect revokes the presented Companion session when the server is
  reachable, removes the local Keychain token, and clears cached connection
  state and Activity thumbnails for that instance.
- The Tesserae administrator can revoke each paired client independently.
- Deleting the app removes its private container. iOS and the server control
  deletion of their respective Keychain and server-side records.
- Local Network permission can be changed at any time in iOS Settings.
- Bluetooth permission can be changed at any time in iOS Settings. Camera
  permission is requested only when the user chooses to scan a display's setup
  code; the app does not capture or retain photos during setup.
- Stopping Apple Health sync deletes `health.summary` from the selected server.
  HealthKit read permissions remain separately controllable in Apple's Settings
  and Health surfaces.

## App Store privacy disclosure draft

Based on the current implementation, the intended App Store privacy answer is
**Data Not Collected** by the app developer: data is processed on device or
sent directly to the user's self-hosted Tesserae instance solely to perform
the user's request. This draft must be reviewed again against the shipping
binary, dependencies, monetization, support tooling, and Apple's then-current
definitions before each submission. The HealthKit entitlement, authorization,
local queries, and settings UI require a fresh review of App Store privacy
labels, the privacy manifest, this public policy, App Review notes, and the
shipping binary before distribution.

A public privacy-policy URL must be published before external TestFlight or
App Store review. This repository document is the source text for that page.

## Changes

Any future analytics, crash reporting, support upload, hosted relay,
advertising, or other developer-operated data path requires an explicit
product decision, an update to this document and the privacy manifest, and a
new App Store privacy review before release.
