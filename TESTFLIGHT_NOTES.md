# TestFlight notes draft

## Beta description

Tesserae Companion is the official Tesserae app for iPhone. It connects
directly to your self-hosted Tesserae server and focuses on native tasks that
are awkward in a web app: local discovery, quick Dashboard pushes, photo
sharing, and Shortcuts.

Dashboard editing and server administration remain in Tesserae's web
interface.

## Version 0.8.0 (build 14)

- Simpler Lineup editors, Cycle daily start times, Daily and Keep Fresh display
  targets, and confirmation before discarding an unsaved draft.
- Dashboard and Lineup search, web editor shortcuts, more hardware brands and
  logos, and compact, expandable Device Details.
- On-device Auto Frame in Send and Share, plus direct Bluetooth photo sending
  and additional maintenance controls for compatible PicPak firmware.
- Per-server Health and Reminders retention, safer server switching, smoother
  Library previews, and more reliable Bluetooth reconnection.

Focus testing on saving each Lineup type, Back/Cancel/swipe-down draft protection
(including open pickers), server-time-zone schedules, and long Dashboard durations.
Check hardware labels in light/dark mode and with larger text. For compatible
PicPak firmware, verify photo transfer, cancellation, screen mode, refresh speed,
and recovery after reconnecting on physical hardware.

## What to test

1. If you paired with an earlier build, pair again when prompted so the app can
   request the new Lineups permissions.
2. Switch Dashboards between Card and List layouts. Check that Dashboard icons
   align in a dedicated leading position, Display groups omit resolution text,
   compact rows open the preview and Push sheet, and preview cards retain Push.
   In the Push sheet, confirm the Dashboard name and target resolution appear
   centered beneath the preview image.
3. Open Lineups from Displays. Check that Manual, Daily, Keep Fresh, and Cycle
   Lineups are grouped under the correct display and show clear status,
   Dashboard count, and current playback information. Include a Daily or
   Keep Fresh Lineup created on the web with no explicit Lineup display binding;
   it should still use the server-resolved Dashboard display and current state.
4. In Tesserae Settings → Companion, grant Create and edit Lineups to this
   iPhone. Create each available Lineup type in the app, select and reorder
   Dashboards, optionally assign Displays, and confirm saving the definition
   does not immediately refresh a Display. Remove the grant, reopen Create or
   Edit, and confirm the permission action opens this client's Companion
   settings page without requiring another pairing.
5. Edit a native Lineup's name, Dashboard order, schedule, and dwell values.
   Confirm advanced Lineups still open on the web, a removed grant shows a
   permission remedy without disconnecting the app, and a concurrent web edit
   asks the app to reload instead of overwriting it.
6. Open a Manual Lineup and tap a Dashboard row. Check its fitted preview,
   name, and target resolution use the same image-first layout as Dashboard Push;
   select a target when offered, and play it. Confirm the current Dashboard is
   highlighted with a pause control and its preview action says Now Playing.
7. Turn a Lineup off and on. Confirm its status updates immediately; turning it
   off should pause its automation while explicit manual controls remain
   available.
8. Review Daily, Keep Fresh, and Cycle details. Check that times, days, frequency,
   daily start, Home Dashboard, and return-home information appear only when relevant.
9. Use Open in Tesserae from a Lineup and confirm it opens that Lineup's editor.
10. Send a photo from both Send and the Share Sheet using Fill. Test dragging,
   pinching, Reset, and switching the preview display; queued retries should
   preserve the chosen framing.
11. Check that successful sends use brief, non-blocking feedback and that the
   Send and Share Sheet layouts remain readable with larger text sizes.

Please include the iPhone model, iOS version, Tesserae version, and whether the
server uses LAN HTTP or HTTPS in feedback. Redact server addresses, tokens,
display names, Dashboard names, photos, and household information.

## Known limitations

- Requires a Tesserae server with the complete Companion API v1 surface.
- Lineups read/control requires its advertised server capabilities; native
  create/edit additionally requires `lineup_authoring` and the optional
  per-client `lineups:write` grant in Tesserae Settings.
- History/resend and richer previews appear only when the paired server
  advertises those optional Companion capabilities.
- Pairing and a Photos Share Sheet publish have passed on a physical iPhone;
  the remaining permission, failure-mode, and format matrix is still in progress.
