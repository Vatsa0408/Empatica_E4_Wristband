import '../model/e4_sample.dart';

/// Platform-agnostic connection to an E4 wristband. The rest of the app
/// (parsing, storage, UI) depends only on this interface, never on the
/// concrete transport, so it doesn't care which platform it runs on.
///
/// BLE (`transport/ble_transport.dart`) is currently the only implementation
/// on both Android and Windows — Empatica's Windows E4 Streaming Server is
/// permanently inoperative post-sunset (see `CLAUDE.md`).
abstract class E4Transport {
  /// Scans for nearby E4 wristbands. Returns once scanning stops.
  Future<List<E4Device>> discover();

  /// Connects to a device previously returned by [discover].
  Future<void> connect(String deviceId);

  Future<void> disconnect();

  /// Broadcast stream of decoded samples. Errors (dropped connection,
  /// decode failure) surface as stream errors, never silently swallowed.
  Stream<E4Sample> get samples;

  /// Broadcast stream of connection status.
  Stream<bool> get connected;
}
