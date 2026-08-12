# TestFlight notes draft

## Beta description

Tesserae Companion is the official Tesserae app for iPhone. It connects
directly to your self-hosted Tesserae server and focuses on native tasks that
are awkward in a web app: local discovery, quick Dashboard pushes, photo
sharing, and Shortcuts.

Dashboard editing and server administration remain in Tesserae's web
interface.

## What to test

1. If you paired with an earlier build, pair again when prompted so the app can
   request the new Lineups permissions.
2. Switch Dashboards between Card and List layouts. Check that Dashboard icons
   align in a dedicated leading position, Display groups omit resolution text,
   compact rows open the preview and Push sheet, and preview cards retain Push.
   In the Push sheet, confirm the Dashboard name and target resolution appear
   centered beneath the preview image.
3. Open Lineups from Displays. Check that Manual, Daily, Interval, and Cycle
   Lineups are grouped under the correct display and show clear status,
   Dashboard count, and current playback information.
4. Open a Manual Lineup and tap a Dashboard row. Check its fitted preview,
   name, and target resolution use the same image-first layout as Dashboard Push;
   select a target when offered, and play it. Confirm the current Dashboard is
   highlighted with a pause control and its preview action says Now Playing.
5. Turn a Lineup off and on. Confirm its status updates immediately; turning it
   off should pause its automation while explicit manual controls remain
   available.
6. Review Daily, Interval, and Cycle details. Check that times, days, frequency,
   reset, Home Dashboard, and return-home information appear only when relevant.
7. Use Open in Tesserae from a Lineup and confirm it opens that Lineup's editor.
8. Send a photo from both Send and the Share Sheet using Fill. Test dragging,
   pinching, Reset, and switching the preview display; queued retries should
   preserve the chosen framing.
9. Check that successful sends use brief, non-blocking feedback and that the
   Send and Share Sheet layouts remain readable with larger text sizes.

Please include the iPhone model, iOS version, Tesserae version, and whether the
server uses LAN HTTP or HTTPS in feedback. Redact server addresses, tokens,
display names, Dashboard names, photos, and household information.

## Known limitations

- Requires a Tesserae server with the complete Companion API v1 surface.
- Lineups require a server advertising the Companion 0.8 Lineups capabilities;
  older pairings may need to pair again for the additional permissions.
- History/resend and richer previews appear only when the paired server
  advertises those optional Companion capabilities.
- Pairing and a Photos Share Sheet publish have passed on a physical iPhone;
  the remaining permission, failure-mode, and format matrix is still in progress.
