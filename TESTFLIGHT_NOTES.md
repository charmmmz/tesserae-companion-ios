# TestFlight notes draft

## Beta description

Tesserae Companion is the official Tesserae app for iPhone. It connects
directly to your self-hosted Tesserae server and focuses on native tasks that
are awkward in a web app: local discovery, quick Dashboard pushes, photo
sharing, and Shortcuts.

Dashboard editing and server administration remain in Tesserae's web
interface.

## What to test

1. Discover your Tesserae server, or use the QR/manual fallback, then pair.
2. Refresh Displays and Dashboards and relaunch the app to verify restoration.
3. Confirm Displays and Dashboards show real previews on a server advertising
   `previews`, and retain placeholders on a base-only server.
4. Push one saved Dashboard to its bound displays and to a different one-time
   target; confirm its server bindings do not change.
5. Send one photo from the app and Share Sheet. Confirm the last display and
   layout selection carry across both surfaces.
6. Take the server offline, send from the Share Sheet or Shortcuts, then use
   the visible Activity queue to retry or discard the saved request.
7. Run the Tesserae actions from Shortcuts, including Fit, Fill, Blur, Stretch,
   and Center on a compatible server.
8. Revoke this client in Tesserae and confirm the app asks to pair again.

Please include the iPhone model, iOS version, Tesserae version, and whether the
server uses LAN HTTP or HTTPS in feedback. Redact server addresses, tokens,
display names, Dashboard names, photos, and household information.

## Known limitations

- Requires a Tesserae server with the complete Companion API v1 surface.
- History/resend and richer previews appear only when the paired server
  advertises those optional Companion capabilities.
- Pairing and a Photos Share Sheet publish have passed on a physical iPhone;
  the remaining permission, failure-mode, and format matrix is still in progress.
