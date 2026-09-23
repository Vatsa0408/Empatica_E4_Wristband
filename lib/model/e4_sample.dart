import 'package:equatable/equatable.dart';

/// The eight signals an Empatica E4 produces. Only [bvp], [eda], [acc] and
/// [temp] have a known BLE characteristic (see [CLAUDE.md]); [hr] and [ibi]
/// are derived offline from [bvp] (see `transport/e4_ble_decoder.dart`),
/// [battery] is a best-effort standard-GATT read, and [tag] has no known BLE
/// path at all (the physical button) so it is expected to stay empty.
enum E4Signal { acc, bvp, eda, hr, ibi, temp, tag, battery }

/// One sample of any signal. A single class covers all eight signals; the
/// writer switches on [signal] anyway, so per-signal subclasses buy nothing.
class E4Sample extends Equatable {
  const E4Sample({
    required this.signal,
    required this.timestamp,
    required this.values,
  });

  /// Unix epoch seconds, fractional.
  final double timestamp;

  final E4Signal signal;

  /// acc: [x, y, z] | tag: [] | all others: one value.
  final List<double> values;

  @override
  List<Object?> get props => [signal, timestamp, values];
}

/// A discoverable/connectable E4 wristband.
class E4Device extends Equatable {
  const E4Device({required this.id, required this.name});

  final String id;
  final String name;

  @override
  List<Object?> get props => [id, name];
}
