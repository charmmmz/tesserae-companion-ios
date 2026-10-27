# README screenshots

Unless noted below, captured on 24 October 2026 from app source
[`79e6d18367e946b237cc0c14569781541d4c5a74`](https://github.com/charmmmz/tesserae-companion-ios/commit/79e6d18367e946b237cc0c14569781541d4c5a74).

`bluetooth-maintenance.png` uses the simple-action icons
from [`45f6c07f013e60c8ad3946a6ed7c7e0d6ad4b3db`](https://github.com/charmmmz/tesserae-companion-ios/commit/45f6c07f013e60c8ad3946a6ed7c7e0d6ad4b3db).
The component, Offline Album and upload-detail screenshots show the nested-page
paper background fix. `gallery-folder-actions.png` was captured
from [`a23a2cff10e79796d5020341ad181f17dc7c70c9`](https://github.com/charmmmz/tesserae-companion-ios/commit/a23a2cff10e79796d5020341ad181f17dc7c70c9)
after extracting the shared toolbar component into DesignSystem.
The Dashboard settings, Lineup editor and selection, choice settings and duration
captures accompany the full UI conventions audit. The source revision and capture
refreshes are recorded in Git history. Changed captures use new filenames for
both README thumbnails and their links.

`send-photo-compact-displays.png` was refreshed on 25 October 2026 from the
working tree based on `9dbba3c`, including the compact display-selection spacing
fix. It is the original `Photo composer compact targets` attachment from
`AdaptiveLayoutUITests.testPhotoFramingSurvivesDeviceTurn`, captured after resetting
the demo framing to 1.0×.

`displays-floating-send.png`, `dashboards-floating-send.png` and
`activity-floating-send.png` were refreshed on 26 October 2026 from the working
tree based on `830c083`, with the independent Send button and top-message layout.
They are the original `Displays Root Toolbar`, `Dashboards Root Toolbar` and
`Activity Root Toolbar` attachments from
`TesseraeCompanionUITests.testRootToolbarsKeepSettingsAndContextActionsConsistent`
in `/tmp/tesserae-floating-send/phone-unified.xcresult`, on the
`Tesserae Adaptive iPhone` simulator. The navigation title, bottom tabs and Send
placement were checked before replacing the superseded captures.

- iPhone 18 Pro Simulator, iOS 27.0, English, light appearance except the dark
  duration picker.
- Original 1206 × 2622 PNG captures; no resizing, compositing or image retouching.
- Demo content and simulated authenticated Bluetooth devices; no live server,
  household content, credentials or real device identifiers are shown.
- These illustrate the current development UI, rather than a released
  TestFlight build or physical-device/firmware acceptance.

| File | Screen / capture point |
| --- | --- |
| `displays-floating-send.png` | Demo Mode → Displays |
| `dashboards-floating-send.png` | Demo Mode → Dashboards, expanded display groups |
| `dashboard-settings-actions.png` | Pantry → native settings, shared actions and bounded Push icon, before editing |
| `lineup-editor-actions.png` | New Manual Lineup, native icon actions, selected display and two Dashboards |
| `gallery-folder-actions.png` | Library → family folder, square image grid and shared More/Add capsule |
| `send-photo-compact-displays.png` | Send → Use Sample → reset framing, centered Fill at 1.0× with compact display selection |
| `activity-floating-send.png` | Demo Mode → Activity |
| `bluetooth-maintenance.png` | Simulated PicPak → authenticated Maintenance, current battery status |
| `dashboard-components.png` | Pantry → Demo Reminders settings, before searching or editing a field |
| `lineup-selection-actions.png` | New Manual Lineup → two selected Dashboards and shared Done capsule |
| `offline-album.png` | Library → family → Offline Album → display readiness review |
| `gallery-upload-details.png` | Simulated uploads → individual photo statuses |
| `dashboard-choices.png` | Album widget → Players → ordered selection with shared Refresh/Done capsule |
| `lineup-duration.png` | Cycle Lineup → Photo Frame duration, ten minutes, dark paper backdrop |

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
replacing the files. Give visibly changed captures a new descriptive filename,
update both `href` and `src` in the root README, and remove unused older assets.
See the root [README](../../../README.md) for server and
firmware capability requirements.
