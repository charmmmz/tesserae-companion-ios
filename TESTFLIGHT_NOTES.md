# TestFlight notes draft

## Beta description

Tesserae Companion is the official Tesserae app for iPhone. It connects
directly to your self-hosted Tesserae server and focuses on native tasks that
are awkward in a web app: local discovery, quick Dashboard pushes, photo
sharing, and Shortcuts.

Dashboard editing and server administration remain in Tesserae's web
interface.

## Version 0.8.2 (source build 16)

- Message capsules fade in and out over 0.18 seconds, with a gentle scale effect
  that is omitted when Reduce Motion is enabled.
- Displays avoids scroll-driven whole-list state updates; Lineups groups and
  searches its records with fewer repeated scans.
- Send closes after submission and keeps progress, confirmation, and explicit
  retries in the message capsule. Photo previews use a compact Fill/Fit toggle.

- Paper branding: a new ink/red/paper icon, warm surfaces, readable light/dark
  actions, and distinct success, warning, error, and progress colours.
- Better Simplified Chinese and larger-text layouts in Displays, Lineups,
  Gallery, Settings, Bluetooth setup, Send, and the Share Extension.
- VoiceOver display cards and selected targets, a native Lineup switch,
  larger touch targets, and custom animations that follow Reduce Motion.

### Focus for this candidate

1. Send a photo or link, then watch the capsule progress, confirmation, and
   dismissal. Repeat with Reduce Motion enabled and retry a failed submission.
2. Scroll Displays, drag cards to reorder them, and open a card after releasing
   a long press. Search Lineups and clear the query; display groups and controls
   should remain correct. Compare scrolling on a physical device.

### Broader regression focus

1. Check light and dark appearances, including success, error, disabled, and
   progress states. Photos and Dashboard artwork should keep their original colours.
2. Use Simplified Chinese, the largest accessibility text size, Bold Text,
   and Increase Contrast. Check long display/server names and the keyboard
   while editing a Lineup; preview target names and dimensions should wrap.
3. With VoiceOver, open a display, select photo targets, turn a Lineup off/on,
   open Settings, and adjust a full-screen Gallery photo. Check the named
   reorder and zoom actions on a physical iPhone.
4. Enable Reduce Motion and verify navigation, long-press reordering,
   photo pinch/double tap, native menus, and sheet dismissal still work.
5. Open Send to Tesserae from Photos/Safari, check large-text target/fit
   controls, then send to a real display and verify the result.

### 简体中文测试重点

本版补上消息胶囊的出现与消失动画，减少 Displays 滚动和 Lineups 分组时的
重复计算。发送后可通过胶囊查看进度、结果或重试。请重点检查：

- 发送照片或链接后，胶囊能否平滑消失；开启“减弱动态效果”后应只保留渐隐。
- Displays 滚动、长按排序和点击详情是否正常；Lineups 搜索、分组和控制是否正确。
- 发送失败后，关闭编辑器仍能从胶囊重试；请在真机上比较滚动流畅度。
- 最大辅助字体、粗体和增强对比度下，长设备名、分辨率、播放队列与设置是否完整显示。
- VoiceOver 能否清楚读出设备、选中目标和开关状态；弹窗焦点及照片缩放是否正确。
- 开启“减弱动态效果”后，原生长按排序、捏合、双击、菜单和关闭操作是否正常。
- 从照片或 Safari 打开分享扩展，以不同适配模式发送到真实显示屏并核对显示结果。

The repository's build number is 16. If Xcode Cloud assigns its own build
number, use the number shown in App Store Connect when reporting a result.

## Core regression checklist

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
- Earlier candidates had physical pairing and Photos Share Sheet checks. This
  0.8.2 candidate has Simulator coverage; physical-device and display acceptance
  still needs to be completed. These earlier results do not qualify this build.
