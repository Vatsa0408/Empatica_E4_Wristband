import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../model/e4_sample.dart';
import 'e4_ble_decoder.dart';
import 'e4_transport.dart';

/// Reverse-engineered E4 BLE characteristic UUIDs (Bluetooth base UUID alias
/// range). Empatica has never published the GATT profile — see CLAUDE.md.
const String _cmdCharUuid = '00003e71-0000-1000-8000-00805f9b34fb';
const String _bvpCharUuid = '00003ea1-0000-1000-8000-00805f9b34fb';
const String _accCharUuid = '00003ea3-0000-1000-8000-00805f9b34fb';
const String _tempCharUuid = '00003ea6-0000-1000-8000-00805f9b34fb';
const String _edaCharUuid = '00003ea8-0000-1000-8000-00805f9b34fb';

/// Standard GATT Battery Service — untested/unconfirmed on the E4, tried on
/// a best-effort basis only (see CLAUDE.md).
const String _batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const String _batteryLevelCharUuid = '00002a19-0000-1000-8000-00805f9b34fb';

const String _deviceNamePrefix = 'Empatica E4';

/// Direct-BLE transport, the only transport on both Android and Windows
/// (Empatica's Windows E4 Streaming Server is permanently inoperative — see
/// CLAUDE.md). Covers BVP/EDA/ACC/TEMP via known characteristics, derives
/// HR/IBI offline from BVP, and makes a best-effort attempt at battery via
/// the standard GATT Battery Service. No known BLE path exists for tags
/// (the physical button); `E4Signal.tag` is simply never emitted.
class BleTransport implements E4Transport {
  final StreamController<E4Sample> _samplesController = StreamController<E4Sample>.broadcast();
  final StreamController<bool> _connectedController = StreamController<bool>.broadcast();

  final List<StreamSubscription<void>> _notificationSubscriptions = [];
  StreamSubscription<bool>? _connectionSubscription;
  String? _deviceId;

  /// Guards against re-entrant connect() calls (e.g. a double-tap firing
  /// two concurrent `ConnectRequested` events — flutter_bloc's default
  /// transformer processes events concurrently) stacking a second set of
  /// BLE notification listeners on top of the first, which is what causes
  /// every characteristic notification to be delivered twice.
  Future<void>? _connectFuture;

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

    await UniversalBle.connect(deviceId);

    await _connectionSubscription?.cancel();
    _connectionSubscription = UniversalBle.connectionStream(deviceId).listen(
      _connectedController.add,
      onError: _connectedController.addError,
    );

    final services = await UniversalBle.discoverServices(deviceId);
    final serviceForChar = <String, String>{};
    debugPrint('[E4 RAW] connected to $deviceId, ${services.length} services');
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        debugPrint('[E4 RAW] service ${service.uuid} char ${characteristic.uuid} props=${characteristic.properties}');
        serviceForChar[characteristic.uuid] = service.uuid;
      }
    }

    await _subscribe(deviceId, serviceForChar, _bvpCharUuid, _onBvp);
    await _subscribe(deviceId, serviceForChar, _edaCharUuid, _onEda);
    await _subscribe(deviceId, serviceForChar, _accCharUuid, _onAcc);
    await _subscribe(deviceId, serviceForChar, _tempCharUuid, _onTemp);

    final cmdService = serviceForChar[_cmdCharUuid];
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

    await _tryBattery(deviceId, services);
  }

  @override
  Future<void> disconnect() async {
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
  }

  /// Best-effort attempt at battery level via the standard GATT Battery
  /// Service. The E4 is not confirmed to expose it — absence is expected,
  /// not an error, so failures here are swallowed after logging.
  Future<void> _tryBattery(String deviceId, List<BleService> services) async {
    BleService? batteryService;
    for (final s in services) {
      if (BleUuidParser.compareStrings(s.uuid, _batteryServiceUuid)) {
        batteryService = s;
        break;
      }
    }
    if (batteryService == null) return;
    final hasLevelChar = batteryService.characteristics.any((c) => BleUuidParser.compareStrings(c.uuid, _batteryLevelCharUuid));
    if (!hasLevelChar) return;

    try {
      await UniversalBle.subscribeNotifications(deviceId, batteryService.uuid, _batteryLevelCharUuid);
      final subscription = UniversalBle.characteristicValueStream(deviceId, _batteryLevelCharUuid).listen(
        (bytes) {
          _logRaw('battery $_batteryLevelCharUuid', bytes);
          _onBattery(bytes);
        },
        onError: (Object error, StackTrace stackTrace) => _samplesController.addError(error, stackTrace),
      );
      _notificationSubscriptions.add(subscription);
    } on Object catch (_) {
      // Unconfirmed on E4 — battery just stays unavailable.
    }
  }

  Future<void> _subscribe(
    String deviceId,
    Map<String, String> serviceForChar,
    String characteristicUuid,
    void Function(Uint8List) onData,
  ) async {
    final serviceUuid = serviceForChar[characteristicUuid];
    if (serviceUuid == null) {
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

  void _logRaw(String label, Uint8List bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    debugPrint('[E4 RAW] ${_now().toStringAsFixed(3)} $label len=${bytes.length} $hex');
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
    final values = _bvpDecoder.decode(bytes);
    if (values.isEmpty) return;
    final timestamps = _timestampsEndingAt(_now(), values.length, 64.0);
    for (var i = 0; i < values.length; i++) {
      _samplesController.add(E4Sample(signal: E4Signal.bvp, timestamp: timestamps[i], values: [values[i]]));
      for (final derived in _hrIbi.addBvpSample(timestamps[i], values[i])) {
        _samplesController.add(derived);
      }
    }
  }

  void _onEda(Uint8List bytes) {
    final values = decodeEda(bytes);
    if (values.isEmpty) return;
    final timestamps = _timestampsEndingAt(_now(), values.length, 4.0);
    for (var i = 0; i < values.length; i++) {
      _samplesController.add(E4Sample(signal: E4Signal.eda, timestamp: timestamps[i], values: [values[i]]));
    }
  }

  void _onTemp(Uint8List bytes) {
    final values = decodeTemp(bytes);
    if (values.isEmpty) return;
    final timestamps = _timestampsEndingAt(_now(), values.length, 4.0);
    for (var i = 0; i < values.length; i++) {
      _samplesController.add(E4Sample(signal: E4Signal.temp, timestamp: timestamps[i], values: [values[i]]));
    }
  }

  void _onAcc(Uint8List bytes) {
    final values = decodeAcc(bytes);
    if (values.isEmpty) return;
    final timestamps = _timestampsEndingAt(_now(), values.length, 32.0);
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      _samplesController.add(
        E4Sample(signal: E4Signal.acc, timestamp: timestamps[i], values: [v[0].toDouble(), v[1].toDouble(), v[2].toDouble()]),
      );
    }
  }

  void _onBattery(Uint8List bytes) {
    if (bytes.isEmpty) return;
    final level = bytes[0] / 100.0;
    _samplesController.add(E4Sample(signal: E4Signal.battery, timestamp: _now(), values: [level]));
  }
}
