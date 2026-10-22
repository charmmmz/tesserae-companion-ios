# Bluetooth Photo v2 implementation and hardware handoff

Date: 2026-10-21. Local experimental implementation of phases 0–1 of the
[hardware audit](2026-10-21-bluetooth-hardware-audit.md). Hardware acceptance is
pending; this does not extend the production support list.

## User workflow

1. Hold the display's Refresh button for 3 seconds, then release to enter
   Maintenance. Authenticate in Companion using the displayed QR or passkey.
2. Select **Manual (Bluetooth)**. The firmware atomically saves the mode and
   photo key, and Companion saves the returned key in this installation's
   Keychain. **Allow This Device** authorizes another phone without rotating
   existing phones' key.
3. Close Maintenance (or exit with the button). The display restarts into the
   saved mode. Saving the mode alone keeps Maintenance open so a failed
   Keychain write can be retried before restarting.
4. With Companion open nearby, press Refresh once to open a bounded photo
   session. Choose Send, compose the photo, and send it directly over BLE.
5. The firmware verifies the full frame, stops Bluetooth, and then calls the
   panel driver. Return to Maintenance and select **Automatic (Wi-Fi)** to
   resume the saved server configuration.

For an unregistered display, hold Refresh during power-on/RESET to enter
Maintenance. Its existing AP-portal shortcut still opens fresh-device Setup;
that entry does not offer local photo authorization.

Manual mode persists across restarts, pauses server polling and Wi-Fi
heartbeats, and sleeps between button presses. A daily battery check does not
advertise or fetch server content. The photo window allows 90 seconds before
the first authenticated command, 5 minutes of authenticated inactivity, and
10 minutes total. These bounds need throughput testing on real hardware.

After a mode change is committed, Maintenance accepts diagnostics, another
mode selection/authorization retry, and reboot. Other actions explicitly ask
the phone to close Maintenance first, so disconnect/reboot cannot replace an
already acknowledged Clear Wi-Fi or factory reset.

## Scope and compatibility

- Companion selects geometry and encoding from authenticated firmware
  capabilities. It never derives the wire layout from a server hardware name
  or an ambiguous one-byte BLE hardware code.
- The native implementation shares one packed-frame receiver across four
  opt-in ESP-IDF builds: E1004 (1200×1600, Spectra 6, 960,000 bytes), E1001
  (800×480, mono, 48,000 bytes), E1003 (1872×1404, sixteen gray levels,
  1,314,144 bytes), and Sticky (480×800, four gray levels, 96,000 bytes).
  Normal firmware release/OTA environments do not enable Photo v2. All
  experimental profiles disable firmware OTA so a regular server offer cannot
  replace the build under test. Automatic content updates still resume when
  selected; returning to OTA-enabled firmware requires an explicit reflash.
- Companion has explicit codecs for mono, four/sixteen gray levels, BWRY,
  Spectra 6, and ACeP 7. Other boards require firmware opt-in and separate
  geometry, memory, power, and panel acceptance before being called supported.
- Existing PicPak Photo v1 keeps its own service, 400×300 bottom-up BWRY
  packing, 30,000-byte frame, 192-byte chunks, and existing photo key account.
- OpenDisplay remains a separate future protocol adapter. This change adds no
  OpenDisplay transfer support or Tesserae server requirement.

E1003 uses the existing `gray4-msb` codec with stride 936 and normal top-down,
left-to-right display coordinates: 0 is black and 15 is white. Its IT8951
driver performs the physical X-mirror conversion itself. Companion and the
BLE receiver must not mirror or transpose the frame. The experimental env
inherits the ordinary E1003 memory defaults, font, partition and panel driver.

## Photo v2 contract

The UUID family is `7A5E000N-7B6D-4F8B-9C2E-1D0A5A110001`:

| N | Purpose |
| --- | --- |
| 1 | Existing setup/maintenance service |
| 2 | Device info |
| 3 | Authenticated control |
| 5 | Authenticated events |
| 6 | Binary photo data |
| 7 | Existing PicPak Photo v1 service |
| 8 | Native Tesserae Photo v2 service |

Native photo advertisements use protocol major 2 and mode `0x04`. Connection
info declares `photo: 2`, `family: "tesserae"`, an immutable catalog `kind`,
device ID, hardware code, model, firmware, session ID and connection nonce.
Maintenance also declares the photo capability on opted-in builds. Unknown
or conflicting hardware codes remain unresolved until model information is
available; code 11 alone cannot enable PicPak maintenance commands.

Maintenance `set_screen_mode` includes `value: "bluetooth" | "wifi"` and a
nonzero UInt32 `request`. Its `screen_mode` event echoes both. Bluetooth
returns a 32-byte base64url `photo_key` only after NVS commit succeeds. Native
keys use Keychain account `tesserae-photo-v2:<device-id>`; legacy PicPak keys
retain their original account. Returning to Automatic revokes the firmware
key; factory reset erases it; Clear Wi-Fi preserves the manual mode and key.

Photo connections use the existing v2 AES-GCM/HKDF envelope with that key and
a fresh connection nonce. Photo mode accepts only key-authenticated controls
and binary data, and provides no passkey fallback or maintenance operations.

After authentication, `photo_capabilities` returns:

```json
{
  "event": "photo_capabilities", "schema": 2,
  "kind": "seeed_reterminal_e1004",
  "width": 1200, "height": 1600,
  "visible_width": 1200, "visible_height": 1600, "x_offset": 0,
  "format": "spectra6-msb", "stride": 600, "bytes": 960000,
  "chunk_bytes": 384,
  "digest": "e4a1365bc0232bd2666dbd403055fa710ab6cbe60cf2eaa2805140a7ea5f0f3f",
  "row_order": "top_down", "lifecycle": "manual"
}
```

The firmware hashes the canonical UTF-8 descriptor without a trailing newline:

```text
2|kind|width|height|visible_width|visible_height|x_offset|format|stride|bytes|chunk_bytes|top_down|manual
```

Companion validates the supported schema, dimensions, stride, byte budget,
layout, digest syntax and matching `kind`, and echoes the firmware digest.
It snapshots the device session and digest before encoding, and checks both
again before sending. Frames are limited to 4 MiB and rows are MSB-first,
top-down, with hidden columns and padding initialized white.

| Format | Bits/pixel | Controller codes |
| --- | --- | --- |
| `mono1-msb` | 1 | black 0, white 1 |
| `gray2-msb` | 2 | black 0 through white 3 |
| `gray4-msb` | 4 | black 0 through white 15 |
| `bwry2-msb` | 2 | black 0, white 1, yellow 2, red 3 |
| `spectra6-msb` | 4 | black 0, white 1, yellow 2, red 3, blue 5, green 6 |
| `acep7-msb` | 4 | black 0, white 1, green 2, blue 3, red 4, yellow 5, orange 6 |

`photo_begin` contains schema, nonzero UInt32 transfer ID, exact byte count,
format, capability digest and lowercase frame SHA-256. The first `photo_ack`
confirms offset zero. Binary logical messages contain a four-byte big-endian
transfer ID, four-byte big-endian offset, and 1–384 pixel bytes. Existing
encrypted BLE fragmentation handles ATT write limits. Control and data share
the connection's monotonic crypto counters, with separate reassembly buffers.

The first version uses one in-flight logical chunk and cumulative offset ACKs.
Retries re-encrypt with a fresh counter. Identical duplicate data is accepted;
future offsets, conflicting retries, overflow, wrong ID, and old connection
generations are rejected. Disconnect discards an unfinished frame. There is
no cross-connection resume or compression.

`photo_end` verifies completeness and SHA-256 before `photo_received`. This
acknowledges verified reception; the panel driver's void return does not
confirm physical refresh success. A verified commit survives an immediate
disconnect while the firmware shuts the radios down before painting.

## Verification and repeatability

Local checks completed during implementation:

- TesseraeKit unit suite and Companion unit suite, including geometry,
  packing, conflicting device IDs, retries, and existing PicPak regressions.
- Simulator UI tests for PicPak authorization/send and native E1004
  Maintenance/negotiated portrait send. Exported screenshots were inspected.
- Final integration with Companion's existing server-change and framing fixes
  passed both unit suites and seven nearby-device UI flows, including English
  and Chinese server change/Wi-Fi repair and ambiguous PicPak hardware identity.
- Firmware receiver and atomic mode/key tests under AddressSanitizer and
  UndefinedBehaviorSanitizer, plus the existing BLE crypto host tests.
- All four experimental ESP-IDF targets, normal E1003/E1004, and BLE-disabled
  `waveshare-133e6` firmware compilation. Exact build commands are recorded
  in the firmware workspace's `docs/ble-photo-v2.md`.
- A native E1004 frame generated by Swift was independently compared byte for
  byte against a controller-code oracle, then consumed by the C receiver in
  384-byte chunks and verified using real mbedTLS SHA-256. This is host
  interoperability, not a BLE or panel hardware test.

The firmware work is in the sibling checkout `tesserae-device-firmware-ble`,
branch `codex/ble-photo-v2`, based on upstream
`421d51a41a843e94757b2261aed619aad0996b66` (1.52.0). The initial clone
already contained this revision; it is newer than the fixed 1.51.0 snapshot
used by the earlier hardware audit. The reviewed implementation is
[firmware commit a0ca4f4](https://github.com/charmmmz/tesserae-device-firmware/commit/a0ca4f4b5ade4f80c7fa777d9627a889c97476d9).
Generate descriptors there with:

```sh
python3 tools/generate_ble_photo_fixtures.py /tmp/tesserae-ble-photo-fixtures
sh tools/test_ble_photo.sh
```

From this Companion checkout, export and verify the Swift six-color checker
frame against that descriptor:

```sh
TESSERAE_BLE_PHOTO_INTEROP_DIR=/tmp/tesserae-ble-photo-fixtures \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/TesseraeKit \
  --filter exportsFrameForFirmwareReceiverInteroperability
```

The generated `swift-e1004.bin` is 960,000 bytes, with SHA-256
`7e88b3db01f7e8c6b66ad4111ca47e48c891a5ff785e07fe33d3566455af2404`.
The opt-in test asserts this independent golden digest. The firmware's
`test/test_ble_photo_fixture.c` then receives this file and the expected hash
through the portable receiver; compilation instructions live in its protocol
document. Generated large binaries stay outside Git.

The E1003 follow-up adds the `seeed-reterminal-e1003-ble-photo` environment,
descriptor/hash fixtures, a complete Gray4 frame test, Maintenance and landscape
photo UI fixtures, and a transfer test covering 3,423 chunks with 96 pixel bytes
in the last chunk. With the same interop directory, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TESSERAE_BLE_PHOTO_INTEROP_DIR=/tmp/tesserae-ble-photo-fixtures \
swift test --package-path Packages/TesseraeKit \
  --filter exportsE1003GrayFrameForFirmwareReceiverInteroperability
```

The test uses `(x / 117 + y / 78) % 16` gray levels. Odd-width blocks exercise
nibble boundaries and changing rows detects orientation mistakes. Its
`swift-e1003.bin` is 1,314,144 bytes with SHA-256
`c1a3309bcaf1663b33c035132dfcf44faf61c154fca304f037b1c2444fb9de1b`.
An independent Python packing oracle and the actual C/mbedTLS receiver have
verified the entire frame. This remains host validation; an E1003 is available
for the upcoming physical test, with no hardware result recorded yet.
The follow-up also passed six targeted nearby UI flows, including both E1003
photo screens, E1004, PicPak and the existing E1003 server-change flow. The
exported E1003 editor screenshot was inspected for its landscape composition.

## Hardware acceptance needed from the author

Test each opted-in build separately, with no reachable Tesserae server:

1. Enter Maintenance via QR and passkey, select Manual, close, restart and
   reconnect by a short button press. Authorize a second phone, restart
   again, then confirm both can still send.
2. Send labeled corner markers, horizontal/vertical rules, text, gradients
   and all palette colors. Compare orientation, native size, packing and
   final physical refresh on E1004, E1001, E1003 and Sticky. On E1003, pay
   particular attention to the left/right corner labels and all sixteen grays.
3. Interrupt during preparation, middle chunks and final ACK; lock/background
   the phone; cancel; leave the app; retry. Confirm no incomplete frame is
   displayed and no old-session packet commits after reconnect.
4. Check 90-second idle closure, 5-minute authenticated inactivity, 10-minute
   hard deadline, button exit, low battery rejection, charging recovery and
   sleep current. Measure transfer time, peak memory and refresh power.
5. Clear Wi-Fi in Manual and confirm authorization survives. Select Automatic
   and confirm old keys fail and server updates resume. Factory reset and
   confirm authorization is erased.

Companion and firmware are delivered as separate changes. No display has been
flashed and no firmware release has been published as part of this work.
Remaining board families and OpenDisplay follow the later phases in the audit.
