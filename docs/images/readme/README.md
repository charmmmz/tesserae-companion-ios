# README screenshots

Unless noted below, captured on 24 October 2026 from app source
[`79e6d18367e946b237cc0c14569781541d4c5a74`](https://github.com/charmmmz/tesserae-companion-ios/commit/79e6d18367e946b237cc0c14569781541d4c5a74).

`dashboard-settings.png` was recaptured on the same date and simulator after the
Dashboard settings paper-background and standard Save-button correction. That
app change and its refreshed screenshot are committed together in Git history.

- iPhone 18 Pro Simulator, iOS 27.0, English, light appearance.
- Original 1206 × 2622 PNG captures; no resizing, compositing or image retouching.
- Demo content and simulated authenticated Bluetooth devices; no live server,
  household content, credentials or real device identifiers are shown.
- These illustrate the current development UI, rather than a released
  TestFlight build or physical-device/firmware acceptance.

| File | Screen / capture point |
| --- | --- |
| `displays.png` | Demo Mode → Displays |
| `dashboards.png` | Demo Mode → Dashboards, expanded display groups |
| `dashboard-settings.png` | Pantry → native settings, paper background and Save toolbar, before editing |
| `lineup-editor.png` | New Manual Lineup, selected display and two Dashboards |
| `gallery.png` | Library → family folder, square image grid |
| `send-photo.png` | Send → Use Sample, centered Fill with framing controls |
| `activity.png` | Demo Mode → Activity |
| `bluetooth-maintenance.png` | Simulated PicPak → authenticated Maintenance |

To refresh, build the app and use its demo journey or the corresponding existing
UI flows in `App/UITests/`. Set a consistent simulator status bar before capturing:

```sh
xcrun simctl status_bar <simulator-udid> override --time '9:41' \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl io <simulator-udid> screenshot <output.png>
xcrun simctl status_bar <simulator-udid> clear
```

XCTest captures can be exported with `xcrun xcresulttool export attachments`.
Keep sample content visibly distinct from live personal data, avoid keyboards,
transient sheets and mid-gesture frames, and verify each selected image before
replacing the files. See the root [README](../../../README.md) for server and
firmware capability requirements.
