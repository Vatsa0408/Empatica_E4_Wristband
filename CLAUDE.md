# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Empty repo — no Flutter project has been scaffolded yet. This file describes the intended
project so early scaffolding decisions stay consistent; update it once real code exists
(add build/lint/test commands and actual module layout as soon as they're established).

## Goal

A Flutter app that connects to an Empatica E4 wristband, pulls its sensor streams
(BVP, EDA, HR, temperature, accelerometer, IBI, battery, tags), and persists the data
locally on the running device — Android phone or Windows laptop. No cloud/Empatica
Connect dependency for the core save path.

## E4 connectivity — the decision that shapes everything else

The E4 has no official public SDK, so the connection path differs by platform and must
be decided before writing app code:

- **Windows**: Empatica's E4 Streaming Server (a separate desktop app, Bluetooth-paired
  to the wristband) exposes a local TCP socket (default port `28000`) using a simple
  line-based text protocol (commands like `device_list`, `device_connect`,
  `device_subscribe <stream> ON`, then newline-delimited data frames). The Flutter app
  is a TCP client to this server — it does not talk BLE directly on Windows.
- **Android**: there is no equivalent streaming-server bridge, and Empatica has not
  published the E4's BLE GATT service/characteristic UUIDs. A direct BLE integration on
  Android is a reverse-engineering effort, not a documented one. Confirm this is
  actually wanted before investing in it — it may be more realistic to only support
  live streaming from Windows (via the TCP bridge) and treat Android as a
  viewer/storage target for data synced from the Windows session, rather than a second
  independent BLE client.

Because of this split, keep the platform-specific transport (TCP client vs. BLE) behind
one Dart interface so the rest of the app (parsing, storage, UI) doesn't care which
platform it's running on.

## Local storage

Sensor streams arrive as high-frequency time series (BVP/accel at 32-64 Hz, EDA/temp at
4 Hz, HR/IBI lower). Favor an embedded store suited to append-heavy time series over
ad-hoc file writes (e.g. sqlite/drift, or per-session CSV files mirroring Empatica's own
E4 export format if compatibility with existing E4 tooling matters) — decide this once
the first stream is actually flowing, not before.
