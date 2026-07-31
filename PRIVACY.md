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
  operated by the companion app maintainer.
- Display and Dashboard preview PNGs are fetched directly from that instance
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

The Tesserae server separately controls its own storage, logs, Job retention,
and any data sources used by Dashboards. The current Companion contract asks
the server to retain Job and idempotency records for 24 hours; server
operators remain responsible for their own privacy policy and configuration.

## User controls

- Disconnect revokes the presented Companion session when the server is
  reachable, removes the local Keychain token, and clears cached connection
  state and Activity thumbnails for that instance.
- The Tesserae administrator can revoke each paired client independently.
- Deleting the app removes its private container. iOS and the server control
  deletion of their respective Keychain and server-side records.
- Local Network permission can be changed at any time in iOS Settings.

## App Store privacy disclosure draft

Based on the current implementation, the intended App Store privacy answer is
**Data Not Collected** by the app developer: data is processed on device or
sent directly to the user's self-hosted Tesserae instance solely to perform
the user's request. This draft must be reviewed again against the shipping
binary, dependencies, monetization, support tooling, and Apple's then-current
definitions before each submission.

A public privacy-policy URL must be published before external TestFlight or
App Store review. This repository document is the source text for that page.

## Changes

Any future analytics, crash reporting, support upload, hosted relay,
advertising, or other developer-operated data path requires an explicit
product decision, an update to this document and the privacy manifest, and a
new App Store privacy review before release.
