# Bluetooth photo throughput: PicPak test handoff

This change covers Companion, `varanu5/picpak-tesserae-client` (Photo v1), and
`dmellok/tesserae-device-firmware` (Photo v2). PicPak is the available hardware
test target; passing its test does not establish Sticky/E1003/E1004 acceptance.

## Connection policy

The authenticated photo reply retains `chunk_bytes` as a receiver maximum:
192 for PicPak and 384 for native Photo v2. Companion chooses image bytes per
packet as `min(chunk_bytes, maximumWriteValueLength(.withoutResponse) - 33)`.
The 33 bytes are the photo header (8), fragmentation header (4), and AES-GCM
envelope (21). The without-response limit avoids treating ATT long-write
capacity as one ordinary write. Tiny connections that cannot fit this envelope
retain the existing response-write fragmentation path.

Firmware can additionally advertise `write_without_response: true` and
`max_window: 4`. Companion requires both the explicit transport capability and
the characteristic's write-without-response property before using that mode.
Absent `max_window` means one outstanding packet. Control commands retain
response writes; all frames share one ordered encrypted-counter queue. The
photo window limits outstanding logical packets and CoreBluetooth readiness
limits writes queued to iOS.

An 8-second data timeout in the new mode sends a response-write control command
`{"op":"photo_status","id":<transfer>,"request":<nonzero UInt32>}`. The firmware
processes it after prior data and replies with matching `id`, `request`, and
confirmed `offset`. Companion stops refilling while waiting, then resumes at
that offset with fresh encrypted counters. Late status replies cannot rewind a
new window. No-progress recovery is bounded to two attempts. Old firmware
continues to use the oldest packet as a cumulative-ACK probe.

Firmware still rejects wrong identities/generations, invalid bounds and
conflicting duplicate pixels. A valid future packet leaves the buffer unchanged
and acknowledges the current offset. Only a complete image matching SHA-256 can
proceed to display refresh.

## PicPak hardware check

1. With the current App and firmware, send one chosen image and record the time
   from tapping Send to the reception confirmation. Record panel refresh time
   separately. Keep the same image, framing, dithering and distance for comparison.
2. Install the updated App and repeat with the old PicPak firmware. It must still
   discover, authorize, send and confirm the image through response writes.
3. Update PicPak using the matching local test package's **settings-preserving
   update** procedure. Use the complete matching boot/layout/application files
   when migrating a pre-0.9.9 layout. Do not use the fresh-install NVS image for
   this update; it clears the saved photo authorization. The firmware repository's
   README documents the update addresses and commands.
4. Send the same image several times. Check colors, bottom-up orientation and
   completion, then cancel a transfer and reconnect for another send. Confirm
   existing authorization survives the firmware update.

The test firmware keeps its source version (0.9.10); identify this local build
by its supplied SHA-256, not by version alone. An App build from before these
changes cannot exercise the new WWR path. Local simulator or unsigned Release
builds do not install on an iPhone; use a signed Xcode build or a TestFlight build
containing this change.

## Evidence to collect

- Firmware serial log `photo link`: actual interval, peripheral latency and MTU.
  The requested 15–30 ms interval is a preference that iOS may decline.
- Companion OS log category `BluetoothPhoto`: `max_write`,
  `pixels_per_packet`, `window`, `without_response`, then confirmed bytes,
  elapsed seconds, bytes/second and retry count. Reception timing includes the
  begin/end handshake and verification, and excludes physical screen refresh.
- With a typical 253-byte write limit, PicPak still uses its 192-byte receiver
  ceiling; the main speed change is the WWR window and removal of fixed ACK
  pacing. Native Photo v2 uses 220 image bytes at that same write limit.

Host/simulator checks cover sizing, flow-control ordering, legacy PicPak, dropped
photo data recovery and lost cumulative ACK recovery. Physical throughput,
radio interference, connection negotiation and power behavior remain hardware
acceptance items; no particular speedup is guaranteed by the automated tests.
