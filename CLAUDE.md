# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Flutter project scaffolded (`flutter create`), `lib/main.dart` is still the default counter
app — no feature code yet. A full implementation plan exists at
`docs/plan/e4-wristband-integration.md`; read it before starting the transport/BLoC work.

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
  (BVP), `0x3EA3` (ACC), `0x3EA6` (TEMP), `0x3EA8` (GSR/EDA). **No known characteristic
  for IBI, HR, battery, or tags**:
  - HR/IBI are derived offline from the decoded BVP signal via peak detection (the
    same approach Empatica uses internally) — they are self-derived, not device-native.
  - Battery: try the standard BLE Battery Service (`0x180F`) — untested, unconfirmed
    the E4 exposes it.
  - Tags (the device's physical button): no known BLE path at all; likely unavailable
    in this app.
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
- `tags.csv` (lowercase filename) — bare timestamps, no header rate row. May end up
  permanently empty since no BLE tag characteristic is known (see connectivity section).
- `BAT.csv` — no home in Empatica's format; write it IBI-style as a documented
  extension.
- `info.txt` per session — must state that `BVP.csv` is an unverified reverse-engineered
  approximation and `HR.csv`/`IBI.csv` are self-derived from BVP peak detection, not
  device-native values.

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

See `docs/plan/e4-wristband-integration.md` for the full step-by-step plan, package
list with versions, and citations.
