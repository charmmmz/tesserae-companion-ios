# README screenshots

Unless noted below, captured on 24 October 2026 from app source
[`79e6d18367e946b237cc0c14569781541d4c5a74`](https://github.com/charmmmz/tesserae-companion-ios/commit/79e6d18367e946b237cc0c14569781541d4c5a74).

`lineup-editor.png` and `bluetooth-maintenance.png` use the simple-action icons
from [`45f6c07f013e60c8ad3946a6ed7c7e0d6ad4b3db`](https://github.com/charmmmz/tesserae-companion-ios/commit/45f6c07f013e60c8ad3946a6ed7c7e0d6ad4b3db).
The four editing-detail screenshots show the nested-page paper background fix;
`dashboard-settings.png` shows the shared More/Save capsule. These captures were
made on the same date and simulator and are committed with their UI corrections
in Git history.

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
| `dashboard-settings.png` | Pantry → native settings, shared More/Save capsule, before editing |
| `lineup-editor.png` | New Manual Lineup, icon actions, selected display and two Dashboards |
| `gallery.png` | Library → family folder, square image grid |
| `send-photo.png` | Send → Use Sample, centered Fill with framing controls |
| `activity.png` | Demo Mode → Activity |
| `bluetooth-maintenance.png` | Simulated PicPak → authenticated Maintenance, current battery status |
| `dashboard-components.png` | Pantry → Demo Reminders settings, before searching or editing a field |
| `lineup-selection.png` | New Manual Lineup → two selected Dashboards in playback order |
| `offline-album.png` | Library → family → Offline Album → display readiness review |
| `gallery-upload-details.png` | Simulated uploads → individual photo statuses |

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
