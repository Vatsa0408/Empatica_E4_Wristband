# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Feature code exists (BLE transport, decoders, session writer, BLoCs, UI). Plans and findings
live in `docs/plan/` (`readme.md`, `e4-full-signal-extraction.md`, `session-summary.md`,
`e4-parsing-verification.md`). Note: `docs/plan/e4-wristband-integration.md`, referenced by
earlier drafts of this file, does **not** exist.

## Goal

A Flutter app that connects to an Empatica E4 wristband, pulls its sensor streams
(BVP, EDA, HR, temperature, accelerometer, IBI, battery, tags), and persists the data
locally on the running device — Android phone or Windows laptop. No cloud/Empatica
Connect dependency for the core save path.

## E4 connectivity — the decision that shapes everything else

⚠️ **Empatica sunset the entire E4 software suite on 2025-02-14** — E4 connect, E4
manager, E4 realtime app, **E4 streaming server**, and E4 SDK are all officially
"inoperative" (https://www.empatica.com/research/e4-sunset/). No new API keys or device
registrations can be issued. This directly affects the Windows path below.

**Resolved 2026-09-23**: the Windows E4 Streaming Server path is dead for this
project — no `EmpaticaBLEServer.exe` install, no Bluegiga BLED112 dongle, and no
previously-issued API key are available, and none can be newly issued post-sunset.
The TCP transport described in earlier drafts of this doc will **not** be built.
**BLE via `universal_ble` is the sole transport, on both Android and Windows.**

The connection path, same on both platforms:

- **Direct BLE (Android + Windows) — the only transport**: Empatica has not
  published the E4's BLE GATT profile, but it has been reverse-engineered (see
  `ismaelwarnants/e4-python-server` on GitHub, flagged by its own author as unverified).
  Known characteristic UUIDs (Bluetooth base UUID): `0x3E71` (command/start), `0x3EA1`
  (BVP), `0x3EA3` (ACC), `0x3EA6` (TEMP), `0x3EA8` (GSR/EDA), plus tags and battery in
  service `0x3EB0` (below). **No known characteristic for IBI or HR**:
  - HR/IBI are derived offline from the decoded BVP signal via peak detection (the
    same approach Empatica uses internally) — they are self-derived, not device-native.
  - Tags (the device's physical button): characteristic `0x3EB2` in service `0x3EB0`.
    20-byte payload: byte 0 = `0x01`, bytes 1-4 = u32 little-endian counter, bytes 5-8 =
    the same counter repeated. `counter / 64` = seconds since the BVP stream started
    (verified within 0.06 s against 3 real button presses in the 2026-11-02 capture). Tag
    timestamp = arrival time of the first BVP packet + `counter / 64`.
  - Battery: characteristic `0x3EB3` in service `0x3EB0`. The device has **no** `0x180F`
    Battery Service. Payload layout is still undecoded: 13 x 10-bit values of ~985-993, only
    ~2 packets per 6 min; a 10-bit ADC reading ~97% is speculative. The app's BAT value is a
    placeholder.
  - Real sample rates (from the capture) are exactly nominal: BVP 64 Hz, ACC 32 Hz, EDA 4 Hz,
    TEMP 4 Hz. BVP carries 11 samples per packet (5.818 packets/s x 11 = 64.0 Hz); each
    sample is a pair of 7-bit values; only the EVEN field of each pair is used for BVP (a
    pulse at ~85-90 bpm was observed in two captures, absent in the odd fields); the odd field
    is discarded and its meaning is unknown. Whether the even values are deltas or raw levels
    is unsettled (`bvpEvenFieldsAreDeltas`). No ground-truth reference exists.
    Packet counters: BVP = low 6 bits of byte 19 (1..63, 0 skipped), ACC/EDA = byte 19
    (1..255, 0 skipped), TEMP = 32-bit big-endian in bytes 16-19.
  The reconstructed BVP is a filtered approximation, not a byte-identical decode of
  Empatica's own BVP, and **cannot be validated against a real streaming-server
  recording** since no server access exists — treat `BVP.csv` output as unverified
  and document that plainly for anyone consuming it.
  Use `universal_ble` (BSD-3-licensed) as the BLE package — it covers Android *and*
  Windows from one API. Avoid `flutter_blue_plus`: dual-licensed, requires a paid
  commercial license for for-profit use.

Because of this split, keep the platform-specific transport (TCP client vs. BLE) behind
one Dart interface so the rest of the app (parsing, storage, UI) doesn't care which
platform it's running on.

## Local storage

Output must replicate Empatica's own native E4 session export layout exactly (verified
via research, see plan doc for full citations) — one CSV per signal, not a database:

- `BVP.csv`, `EDA.csv`, `HR.csv`, `TEMP.csv` (4 Hz), `ACC.csv` (32 Hz, 3 columns
  raw `64*g` ints) — two-row header: row 1 = initial timestamp (Unix epoch), row 2 =
  sample rate in Hz, then one sample per row.
- `IBI.csv` — header is `<t0>, IBI` (no separate rate row, IBI is irregular).
- `tags.csv` (lowercase filename) — bare timestamps, no header rate row. Device-native,
  from BLE characteristic `0x3EB2` (see connectivity section); empty if the button is never pressed.
- `BAT.csv` — no home in Empatica's format; write it IBI-style as a documented
  extension.
- `info.txt` per session — must state that `BVP.csv` is an unverified reverse-engineered
  approximation and `HR.csv`/`IBI.csv` are self-derived from BVP peak detection, not
  device-native values; `tags.csv` is device-native (0x3EB2).

Two correctness-critical, non-cosmetic details:
1. **t0 must be the first-received-sample timestamp per signal, not wall-clock** — the
   real E4/streaming-server timestamps relative to the first packet it emitted, which
   may predate your subscription.
2. **The format is positional** — row *n* means `t0 + n/rate`. A dropped packet must be
   gap-padded to keep every later row aligned; log drops to a non-Empatica sidecar file
   rather than silently shifting timestamps.

No SQLite/drift, no `csv` package, no TCP package — plain `dart:io Socket` +
`LineSplitter` for the transport and hand-written comma-joined rows
(`toStringAsFixed(6)`) for writing are sufficient; the CSV files are the deliverable,
not a staging format to export from later.

## Recording modes

Both **continuous logging** (always-on while connected) and **manual start/stop**
session recording must be available, user-selectable — modeled as a `RecordingMode`
field on `RecordingState`, not two separate BLoCs.

## BLoC architecture

Two BLoCs cover this feature: `ConnectionBloc` (connect/disconnect, transport state,
errors) and `RecordingBloc` (start/stop/continuous mode, per-signal sample counts,
recording status). Co-locate events/states in each bloc file rather than splitting into
separate files. Throttle state emission to ~250ms for UI responsiveness — every sample
still gets written to disk regardless of emission throttling.

See `docs/plan/readme.md` and `docs/plan/e4-full-signal-extraction.md` for the plan, package
list and citations.
