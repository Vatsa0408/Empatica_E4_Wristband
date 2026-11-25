import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../model/e4_sample.dart';
import '../storage/session_paths.dart';
import 'e4_ble_decoder.dart';
import 'e4_transport.dart';

/// Reverse-engineered E4 BLE characteristic UUIDs (Bluetooth base UUID alias
/// range). Empatica has never published the GATT profile — see CLAUDE.md.
const String _cmdCharUuid = '00003e71-0000-1000-8000-00805f9b34fb';
const String _bvpCharUuid = '00003ea1-0000-1000-8000-00805f9b34fb';
const String _accCharUuid = '00003ea3-0000-1000-8000-00805f9b34fb';
const String _tempCharUuid = '00003ea6-0000-1000-8000-00805f9b34fb';
const String _edaCharUuid = '00003ea8-0000-1000-8000-00805f9b34fb';

/// E4-proprietary notify chars in service 0x3EB0 (the service UUID is resolved
/// from the device's own service map). 0x3EB2 is the tag/button path (decoded
/// by [decodeTagCounter]); 0x3EB3 is battery (see [decodeBatteryCounts]).
const String _tagCharUuid = '00003eb2-0000-1000-8000-00805f9b34fb';
const String _batteryCharUuid = '00003eb3-0000-1000-8000-00805f9b34fb';

/// Clean-stop opcode written to [_cmdCharUuid] before disconnecting.
const int _opStopStreaming = 0x0A;

const String _deviceNamePrefix = 'Empatica E4';

/// Direct-BLE transport, the only transport on both Android and Windows
/// (Empatica's Windows E4 Streaming Server is permanently inoperative — see
/// CLAUDE.md). Covers BVP/EDA/ACC/TEMP via known characteristics, derives
/// HR/IBI offline from BVP, and decodes battery from the E4-proprietary char
/// 0x3EB3 (provisional, uncalibrated %). Tags (the physical button) come from 0x3EB2.
class BleTransport implements E4Transport {
  final StreamController<E4Sample> _samplesController = StreamController<E4Sample>.broadcast();
  final StreamController<bool> _connectedController = StreamController<bool>.broadcast();

  final List<StreamSubscription<void>> _notificationSubscriptions = [];
  StreamSubscription<bool>? _connectionSubscription;
  String? _deviceId;
  String? _cmdService;
  // ACC/EDA counters are 8-bit (byte 19) and BVP's is 6-bit (low bits of byte
  // 19); all three cycle 1..max and skip 0. TEMP is a plain 32-bit BE counter.
  final _accClock = SeqClock(modulus: 256, skipZero: true);
  final _edaClock = SeqClock(modulus: 256, skipZero: true);
  final _bvpClock = SeqClock(modulus: 64, skipZero: true);
  final _tempClock = SeqClock(modulus: 4294967296);

  /// Guards against re-entrant connect() calls (e.g. a double-tap firing
  /// two concurrent `ConnectRequested` events — flutter_bloc's default
  /// transformer processes events concurrently) stacking a second set of
  /// BLE notification listeners on top of the first, which is what causes
  /// every characteristic notification to be delivered twice.
  Future<void>? _connectFuture;

  /// Arrival time of the first BVP packet; tag counters (`/64` = seconds since
  /// the BVP stream started) are relative to it.
  double? _bvpStart;

  BvpDecoder _bvpDecoder = BvpDecoder();
  HrIbiPeakDetector _hrIbi = HrIbiPeakDetector();

  @override
  Stream<E4Sample> get samples => _samplesController.stream;

  @override
  Stream<bool> get connected => _connectedController.stream;

  @override
  Future<List<E4Device>> discover() async {
    final found = <String, E4Device>{};
    final scanSubscription = UniversalBle.scanStream.listen((device) {
      final name = device.name;
      if (name != null && name.isNotEmpty) {
        found[device.deviceId] = E4Device(id: device.deviceId, name: name);
      }
    });

    try {
      await UniversalBle.startScan(scanFilter: ScanFilter(withNamePrefix: [_deviceNamePrefix]));
      await Future<void>.delayed(const Duration(seconds: 5));
    } finally {
      await UniversalBle.stopScan();
      await scanSubscription.cancel();
    }
    return found.values.toList();
  }

  @override
  Future<void> connect(String deviceId) {
    return _connectFuture ??= _doConnect(deviceId).whenComplete(() => _connectFuture = null);
  }

  Future<void> _doConnect(String deviceId) async {
    // Tear down any still-active subscriptions from a previous connect
    // before subscribing again, so notification listeners never stack.
    if (_deviceId != null) {
      await disconnect();
    }
    _deviceId = deviceId;
    _bvpDecoder = BvpDecoder();
    _hrIbi = HrIbiPeakDetector();
    _bvpStart = null;
    _accClock.reset();
    _edaClock.reset();
    _bvpClock.reset();
    _tempClock.reset();
    await _openRawLog();

    await UniversalBle.connect(deviceId);

    await _connectionSubscription?.cancel();
    _connectionSubscription = UniversalBle.connectionStream(deviceId).listen(
      _connectedController.add,
      onError: _connectedController.addError,
    );

    final services = await UniversalBle.discoverServices(deviceId);
    final serviceForChar = <String, String>{};
    _rawLine('[E4 RAW] connected to $deviceId, ${services.length} services');
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        _rawLine('[E4 RAW] service ${service.uuid} char ${characteristic.uuid} props=${characteristic.properties}');
        serviceForChar[characteristic.uuid] = service.uuid;
      }
    }

    await _subscribe(deviceId, serviceForChar, _bvpCharUuid, _onBvp);
    await _subscribe(deviceId, serviceForChar, _edaCharUuid, _onEda);
    await _subscribe(deviceId, serviceForChar, _accCharUuid, _onAcc);
    await _subscribe(deviceId, serviceForChar, _tempCharUuid, _onTemp);
    await _subscribe(deviceId, serviceForChar, _batteryCharUuid, _onBattery, optional: true);
    await _subscribe(deviceId, serviceForChar, _tagCharUuid, _onTag, optional: true);

    final cmdService = _cmdService = serviceForChar[_cmdCharUuid];
    if (cmdService == null) {
      _samplesController.addError(StateError('E4 command characteristic $_cmdCharUuid not found; cannot start streaming'));
    } else {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final command = ByteData(5)
        ..setUint8(0, 0x01)
        ..setUint32(1, nowSeconds, Endian.little);
      _logRaw('WRITE cmd $_cmdCharUuid', command.buffer.asUint8List());
      await UniversalBle.write(deviceId, cmdService, _cmdCharUuid, command.buffer.asUint8List());
    }
  }

  @override
  Future<void> disconnect() async {
    // Clean stop before tearing down; a failed write (e.g. link already
    // lost) is logged, never allowed to block the disconnect itself.
    final stopDeviceId = _deviceId;
    final cmdService = _cmdService;
    _cmdService = null;
    if (stopDeviceId != null && cmdService != null) {
      try {
        await UniversalBle.write(stopDeviceId, cmdService, _cmdCharUuid, Uint8List.fromList([_opStopStreaming]));
      } on Object catch (error) {
        _rawLine('[E4 RAW] stop command failed: $error');
      }
    }
    for (final subscription in _notificationSubscriptions) {
      await subscription.cancel();
    }
    _notificationSubscriptions.clear();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    final deviceId = _deviceId;
    _deviceId = null;
    if (deviceId != null) {
      await UniversalBle.disconnect(deviceId);
    }
    await _rawSink?.close();
    _rawSink = null;
  }

  Future<void> _subscribe(
    String deviceId,
    Map<String, String> serviceForChar,
    String characteristicUuid,
    void Function(Uint8List) onData, {
    bool optional = false,
  }) async {
    final serviceUuid = serviceForChar[characteristicUuid];
    if (serviceUuid == null) {
      if (optional) {
        _rawLine('[E4 RAW] optional characteristic $characteristicUuid not present');
        return;
      }
      _samplesController.addError(StateError('E4 characteristic $characteristicUuid not found on this device'));
      return;
    }
    await UniversalBle.subscribeNotifications(deviceId, serviceUuid, characteristicUuid);
    final subscription = UniversalBle.characteristicValueStream(deviceId, characteristicUuid).listen(
      (bytes) {
        _logRaw(characteristicUuid, bytes);
        onData(bytes);
      },
      onError: (Object error, StackTrace stackTrace) => _samplesController.addError(error, stackTrace),
    );
    _notificationSubscriptions.add(subscription);
  }

  IOSink? _rawSink;

  /// Prints and also appends to `e4_raw_<unixStart>.log` in the session root,
  /// so a bench capture needs no console redirection.
  void _rawLine(String line) {
    debugPrint(line);
    _rawSink?.writeln(line);
  }

  Future<void> _openRawLog() async {
    await _rawSink?.close();
    try {
      final root = await const SessionPaths().sessionRoot();
      final unix = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      _rawSink = File('${root.path}/e4_raw_$unix.log').openWrite();
    } on Object catch (error) {
      _rawSink = null;
      debugPrint('[E4 RAW] raw log file unavailable: $error');
    }
  }

  void _logRaw(String label, Uint8List bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    _rawLine('[E4 RAW] ${_now().toStringAsFixed(3)} $label len=${bytes.length} $hex');
  }

  double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  /// BLE notifications only carry a packet-arrival time, not a per-sample
  /// timestamp. Spaces the samples in one packet evenly at [rate] Hz, ending
  /// at the packet's arrival time.
  List<double> _timestampsEndingAt(double arrival, int count, double rate) {
    final period = 1.0 / rate;
    return List<double>.generate(count, (i) => arrival - (count - 1 - i) * period);
  }

  void _onBvp(Uint8List bytes) {
    final now = _now();
    // Stamp before decoding so a duplicate delivery never advances the
    // stateful filter chain.
    final timestamps = _bvpClock.stamp(bvpCounter(bytes), now, bvpSamplesPerPacket, 64.0);
    if (timestamps == null || timestamps.isEmpty) return; // short packet / duplicate
    _bvpStart ??= now;
    final values = _bvpDecoder.decode(bytes);
    for (var i = 0; i < values.length; i++) {
      _samplesController.add(E4Sample(signal: E4Signal.bvp, timestamp: timestamps[i], values: [values[i]]));
      for (final derived in _hrIbi.addBvpSample(timestamps[i], values[i])) {
        _samplesController.add(derived);
      }
    }
  }

  void _onTag(Uint8List bytes) {
    final counter = decodeTagCounter(bytes);
    if (counter == null) return; // not a tag packet; raw-logged already
    final start = _bvpStart;
    if (start == null) _rawLine('[E4 RAW] tag before first BVP packet; using arrival time');
    _samplesController.add(E4Sample(signal: E4Signal.tag, timestamp: (start ?? _now()) + counter / 64.0, values: const []));
  }

  void _onEda(Uint8List bytes) {
    final values = decodeEda(bytes);
    if (values.isEmpty) return;
    final timestamps = _edaClock.stamp(edaCounter(bytes), _now(), values.length, 4.0) ??
        _timestampsEndingAt(_now(), values.length, 4.0);
    if (timestamps.isEmpty) return;
    for (var i = 0; i < values.length; i++) {
      _samplesController.add(E4Sample(signal: E4Signal.eda, timestamp: timestamps[i], values: [values[i]]));
    }
  }

  void _onTemp(Uint8List bytes) {
    final values = decodeTemp(bytes);
    if (values.isEmpty) return;
    final timestamps = _tempClock.stamp(tempCounter(bytes), _now(), values.length, 4.0) ??
        _timestampsEndingAt(_now(), values.length, 4.0);
    if (timestamps.isEmpty) return;
    for (var i = 0; i < values.length; i++) {
      _samplesController.add(E4Sample(signal: E4Signal.temp, timestamp: timestamps[i], values: [values[i]]));
    }
  }

  void _onAcc(Uint8List bytes) {
    final values = decodeAcc(bytes);
    if (values.isEmpty) return;
    final timestamps = _accClock.stamp(accCounter(bytes), _now(), values.length, 32.0) ??
        _timestampsEndingAt(_now(), values.length, 32.0);
    if (timestamps.isEmpty) return;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      _samplesController.add(
        E4Sample(signal: E4Signal.acc, timestamp: timestamps[i], values: [v[0].toDouble(), v[1].toDouble(), v[2].toDouble()]),
      );
    }
  }

  void _onBattery(Uint8List bytes) {
    final counts = decodeBatteryCounts(bytes);
    if (counts == null) {
      _rawLine('[E4 RAW] battery packet not recognised (layout/plausibility); skipped');
      return;
    }
    final level = batteryFraction(counts);
    _rawLine('[E4 RAW] battery median=$counts level=${level.toStringAsFixed(3)}');
    _samplesController.add(E4Sample(signal: E4Signal.battery, timestamp: _now(), values: [level]));
  }
}

/// Jitter-free timestamps from an on-wire modulo packet counter. The first
/// packet is anchored to its arrival time; afterwards each packet's samples
/// sit at `t0 + sampleIndex / rate`, where `sampleIndex` also advances over
/// packets the counter says were missed, so the session writer gap-pads them.
/// Assumes the counter increments by 1 per packet (ACC byte 19, EDA byte 19,
/// BVP low 6 bits of byte 19, TEMP BE32 @16). With [skipZero] the counter cycles
/// 1..modulus-1 (never 0), so the wrap `modulus-1 -> 1` is not a gap.
@visibleForTesting
class SeqClock {
  SeqClock({required this.modulus, this.skipZero = false});

  final int modulus;
  final bool skipZero;
  double? _t0;
  int? _lastCounter;
  int _sampleIndex = 0;

  void reset() {
    _t0 = null;
    _lastCounter = null;
    _sampleIndex = 0;
  }

  /// Returns null if [counter] is null (caller falls back to arrival time),
  /// empty for a duplicate packet.
  List<double>? stamp(int? counter, double arrival, int count, double rate) {
    if (counter == null) return null;
    final period = 1.0 / rate;
    final last = _lastCounter;
    if (last == null) {
      _t0 = arrival - (count - 1) * period;
    } else {
      if (counter == last) return const []; // duplicate delivery
      final missed = (counter - last - 1) % (skipZero ? modulus - 1 : modulus);
      if (missed > 0) debugPrint('[E4 RAW] seq gap: $missed packet(s) missed (counter $last -> $counter)');
      _sampleIndex += (1 + missed) * count;
    }
    _lastCounter = counter;
    final t0 = _t0!;
    final base = _sampleIndex;
    return List<double>.generate(count, (i) => t0 + (base + i) * period);
  }
}
