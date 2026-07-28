# TestFlight notes draft

## Beta description

Tesserae Companion is a community-built iPhone client for a self-hosted
Tesserae server. This beta focuses on native tasks that are awkward in a web
app: local discovery, QR pairing, quick Dashboard pushes, one-photo sharing,
and Shortcuts.

It is not the official Tesserae app. Dashboard editing and server
administration remain in Tesserae's web interface.

## What to test

1. Discover your Tesserae server, or use the QR/manual fallback, then pair.
2. Refresh Displays and Dashboards and relaunch the app to verify restoration.
3. Push one saved Dashboard.
4. Send one photo from the app and from the iOS Share Sheet using Fit and Fill.
5. Run the Tesserae actions from Shortcuts.
6. Temporarily take the server offline, retry, and verify cached information
   remains visible.
7. Revoke this client in Tesserae and confirm the app asks to pair again.

Please include the iPhone model, iOS version, Tesserae version, and whether the
server uses LAN HTTP or HTTPS in feedback. Redact server addresses, tokens,
display names, Dashboard names, photos, and household information.

## Known limitations

- Requires a Tesserae server with the complete Companion API v1 surface.
- History/resend and server-rendered Dashboard previews are not included.
- Initial device and network validation is still in progress.
