# TestFlight preparation checklist

This is a preparation checklist, not evidence that a build has been uploaded
or approved.

## Server compatibility

- [x] Use a Tesserae build that exposes the complete Companion API v1
      capability set: `devices`, `dashboards`, `dashboard_push`,
      `image_push`, and `jobs`.
- [ ] Replace the current known-good upstream reference (`0.207.0` from
      commit `3e4d481`) with the first published Tesserae release tag that
      contains it.
- [x] Confirm physical iPhone pairing and Share Extension image publishing on
      the Tesserae `0.207.0` deployment used by testers.
- [x] Confirm authenticated device preview loading and portrait presentation
      on the Tesserae `0.208.0` deployment.
- [ ] On a server with logical device previews, send one asymmetric photo
      using Fit, Fill, Blur, Stretch, and Center; confirm the Displays preview
      matches the target panel geometry and remains upright on a portrait
      reTerminal E1004.
- [ ] Confirm Dashboard preview preparation, ETag revalidation, and
      base-server placeholder fallback.
- [ ] Confirm dashboard push, Job polling, quiet hours, and `_tesserae._tcp`
      discovery on the deployment used by testers.

## Apple identifiers and signing

- [x] App identifier: `com.charmmmz.tesseraecompanion`.
- [x] Share Extension identifier:
      `com.charmmmz.tesseraecompanion.share`.
- [x] App Group: `group.com.charmmmz.tesseraecompanion`.
- [x] Shared Keychain group:
      `$(AppIdentifierPrefix)com.charmmmz.tesseraecompanion.shared`.
- [x] Automatic signing uses Apple Developer Team `3MSS7DJGVR`.
- [ ] Verify the App ID, extension App ID, App Group, and Keychain Sharing
      capabilities in the Apple Developer portal.
- [ ] Create the App Store Connect app record using the final display name,
      subtitle, category, age rating, support URL, and privacy-policy URL.

## Binary and privacy

- [x] Main app and Share Extension contain privacy manifests.
- [x] The manifests declare no tracking or developer-collected data.
- [x] Required-reason UserDefaults access is declared for app-only and shared
      App Group use as applicable.
- [ ] Re-audit the generated Privacy Report after Archive and update
      `PRIVACY.md` if any dependency adds data collection or required-reason
      API use.
- [ ] Review export-compliance answers for the final binary. The current app
      relies on Apple's networking and Keychain frameworks and does not
      implement custom cryptography; this is a submission note, not legal
      advice.
- [ ] Publish the privacy policy at a stable HTTPS URL.

## Product metadata

- [ ] Replace placeholder app icons and provide the final 1024 × 1024 App
      Store icon.
- [ ] Prepare English and Simplified Chinese descriptions, keywords, release
      notes, support text, and screenshots for each supported iPhone size.
- [ ] Confirm the community-built, non-official Tesserae attribution in the
      listing.
- [ ] Set marketing version and monotonically increasing build number for the
      beta candidate.

## Archive and validation

- [x] Build and install a signed Debug app containing the Share Extension and
      App Intents on physical device `AD89415F-DB55-5D1E-BEF7-F78EA165C3DD`.
- [ ] Launch that installed build while the device is unlocked and complete
      the new-feature smoke tests below.
- [ ] Run package, contract, simulator UI, and physical-device smoke tests
      from a clean commit.
- [ ] Archive with the Release configuration and validate the archive in
      Xcode Organizer.
- [ ] Confirm `PrivacyInfo.xcprivacy`, Simplified Chinese resources, App
      Intents metadata, and the embedded Share Extension are present in the
      archive.
- [ ] Confirm no development fixture server URL or demo-only assertion is
      presented as a live result.
- [ ] Upload only after explicitly authorizing an external TestFlight action.

## Internal beta test matrix

- [ ] First launch and Local Network permission allowed, denied, and later
      re-enabled.
- [ ] Bonjour discovery, QR pairing, manual URL fallback, and invalid or
      expired pairing codes.
- [ ] HTTP on the LAN and HTTPS with a valid public certificate.
- [ ] Relaunch while online, offline with cached data, and after server-side
      token revocation.
- [ ] Empty display and Dashboard lists plus server failures.
- [ ] Dashboard push in normal time and quiet hours, using both its bound
      displays and a one-time explicit target override.
- [ ] JPEG, PNG, HEIC/HEIF, WebP, oversized, over-dimension, and unsupported
      image cases.
- [ ] Change the default display and layout in the app, then confirm both are
      restored in the app and Share Extension after relaunch.
- [x] Share Extension success from Photos to a real display.
- [ ] Confirm Activity shows the sent photo thumbnail for main-app,
      Share Extension, and Shortcut sends, and that tapping it expands the
      image smoothly.
- [ ] Share Extension timeout, visible Activity queue card, manual Retry and
      Discard, 24-hour purge, and duplicate retry with one idempotency key.
- [ ] Each App Intent from Shortcuts, including Fit, Fill, Blur, Stretch,
      Center, unsupported-layout validation, and explicit quiet-hours override.
- [ ] English and Simplified Chinese layouts, Dynamic Type, VoiceOver, light
      mode, and dark mode.
- [ ] Disconnect while the server is reachable and unreachable, then pair
      again.

## Beta handoff

- [ ] Add a small internal tester group first.
- [ ] Provide a compatible Tesserae server version and pairing instructions
      in TestFlight test notes.
- [ ] Ask testers to report iOS version, device model, Tesserae version,
      network topology, and redacted reproduction steps.
- [ ] Do not create a release tag or move to external testers until the
      physical test matrix and privacy review are complete.
