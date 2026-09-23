import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/e4_sample.dart';

/// Calibration offset applied to the raw skin-temperature reading. The ideal
/// Kelvin->Celsius formula (`raw*0.02 - 273.15`) will never match a real
/// thermistor against real skin, so this is exposed as a parameter — never
/// baked in silently — rather than a constant.
const double defaultTempCalibration = 0.46;

/// EDA/GSR (`0x3EA8`): 20-byte notification, six 24-bit big-endian samples
/// (18 bytes), last 2 bytes are a packet counter. µS = 1e6 / raw.
///
/// Formula and packet layout are reverse-engineered, **unverified** against
/// a real Empatica export — see CLAUDE.md.
List<double> decodeEda(Uint8List packet) {
  if (packet.length < 20) return const [];
  final readings = <double>[];
  for (var i = 0; i + 3 <= packet.length - 2; i += 3) {
    final raw = (packet[i] << 16) | (packet[i + 1] << 8) | packet[i + 2];
    readings.add(raw == 0 ? 0.0 : 1000000.0 / raw);
  }
  return readings;
}

/// Skin temperature (`0x3EA6`): 12-byte notification, four little-endian
/// uint16 samples (8 bytes), remaining 4 bytes unused/unknown.
List<double> decodeTemp(
  Uint8List packet, {
  double calibration = defaultTempCalibration,
}) {
  if (packet.length < 12) return const [];
  final readings = <double>[];
  for (var i = 0; i < 8; i += 2) {
    final raw = packet[i] | (packet[i + 1] << 8);
    readings.add((raw * 0.02) - 276.0 + calibration);
  }
  return readings;
}

/// Accelerometer (`0x3EA3`): signed-byte (x, y, z) triples, raw `64 * g`
/// ints — the same units Empatica's own `ACC.csv` export uses, so callers
/// store these values directly without further scaling.
List<List<int>> decodeAcc(Uint8List packet) {
  final readings = <List<int>>[];
  for (var i = 0; i + 3 <= packet.length; i += 3) {
    readings.add([_toInt8(packet[i]), _toInt8(packet[i + 1]), _toInt8(packet[i + 2])]);
  }
  return readings;
}

int _toInt8(int byte) => byte > 127 ? byte - 256 : byte;

const List<double> _firCoefficients = [0.05, 0.1, 0.2, 0.3, 0.2, 0.1, 0.05];
const double _bvpScaleFactor = 10.0;

/// BVP/PPG (`0x3EA1`) decoder. Stateful (FIR + Kalman filter chain carried
/// across packets), so — unlike the other three decoders — this is a class,
/// not a pure function. It is the single place the filter chain lives,
/// swappable wholesale once a real Empatica streaming-server recording is
/// available to validate against.
///
/// **UNVERIFIED**: this is a filtered approximation of Empatica's own
/// proprietary BVP algorithm, not a byte-identical decode. See CLAUDE.md.
class BvpDecoder {
  final Queue<double> _fir1 = Queue.of(List.filled(_firCoefficients.length, 0.0));
  final Queue<double> _fir2 = Queue.of(List.filled(_firCoefficients.length, 0.0));
  final Queue<double> _fir3 = Queue.of(List.filled(_firCoefficients.length, 0.0));
  double _kalmanP = 1.0;
  double _kalmanX = 0.0;
  static const double _kalmanQ = 0.01;
  static const double _kalmanR = 0.1;

  /// Decodes one 20-byte BVP notification into up to 11 filtered samples.
  List<double> decode(Uint8List packet) {
    if (packet.length < 20) return const [];
    final decoded = _unpack7Bit(packet);

    final readings = <double>[];
    final pairs = decoded.length ~/ 2;
    for (var i = 0; i < pairs && i < 11; i++) {
      final green = decoded[i * 2].toDouble();
      final red = decoded[i * 2 + 1].toDouble();

      _push(_fir1, red);
      final filteredRed = _weightedSum(_fir1);

      final weighted = (red + green * 10.0) / 11.0;
      _push(_fir2, weighted);
      final filteredWeighted = _weightedSum(_fir2);

      final kalmanOut = _kalmanFilter(filteredRed, filteredWeighted);

      _push(_fir3, kalmanOut);
      final filteredKalman = _weightedSum(_fir3);

      readings.add(_roundTo2(-filteredKalman * _bvpScaleFactor));
    }
    return readings;
  }

  double _kalmanFilter(double m1, double m2) {
    final measurement = (m1 + m2) / 2.0;
    final pPred = _kalmanP + _kalmanQ;
    final gain = pPred / (pPred + _kalmanR);
    _kalmanX += gain * (measurement - _kalmanX);
    _kalmanP = (1 - gain) * pPred;
    final diff = (m1 - m2).abs();
    _kalmanP = diff > 20 ? math.min(_kalmanP * 1.2, 10.0) : math.max(_kalmanP * 0.95, 0.01);
    return _kalmanX;
  }

  static void _push(Queue<double> buffer, double value) {
    buffer.removeFirst();
    buffer.addLast(value);
  }

  static double _weightedSum(Queue<double> buffer) {
    var sum = 0.0;
    var i = 0;
    for (final sample in buffer) {
      sum += _firCoefficients[i] * sample;
      i++;
    }
    return sum;
  }

  static double _roundTo2(double v) => (v * 100).round() / 100;

  /// 7-bit packed delta unpacking — a direct port of the reverse-engineered
  /// packet layout. The bit manipulation is unexplained even by its own
  /// author (decompiled from Empatica's binary); see CLAUDE.md's source.
  static List<int> _unpack7Bit(Uint8List data) {
    final decoded = <int>[];
    var acc = 0;
    for (var i = 0; i < 0x14; i++) {
      final byte = data[i];
      final bitIndex = i % 7;
      final shift = bitIndex + 1;

      acc = (byte >> shift) | acc;
      decoded.add(_signExtend7(acc));

      final mask = (1 << shift) - 1;
      acc = ((byte & mask) << (6 - bitIndex)) & 0xFF;

      if (shift == 7) {
        decoded.add(_signExtend7(acc));
        acc = 0;
      }
    }
    var finalVal = data[0x13] & 0x3F;
    if (finalVal & 0x20 != 0) finalVal |= 0xC0;
    if (finalVal > 127) finalVal -= 256;
    decoded.add(finalVal);
    return decoded;
  }

  static int _signExtend7(int value) {
    var v = value & 0x7F;
    if (v & 0x40 != 0) v |= 0x80;
    if (v > 127) v -= 256;
    return v;
  }
}

/// Derives heartbeat intervals (IBI) and heart rate (HR) offline from a
/// stream of already-decoded BVP samples, via naive local-maximum peak
/// detection with a refractory period. This is the documented fallback
/// (plan §3.2/CLAUDE.md): no BLE characteristic for HR/IBI has been found,
/// but Empatica computes HR from IBI the same way — a rolling mean over the
/// last [hrWindow] intervals.
///
/// ponytail: naive fixed-refractory peak detector, no amplitude threshold or
/// artifact rejection. Upgrade to adaptive thresholding if HR/IBI accuracy
/// against real hardware proves insufficient (see plan step 9).
class HrIbiPeakDetector {
  HrIbiPeakDetector({this.minPeakIntervalSeconds = 0.3, this.hrWindow = 10});

  /// Refractory period between accepted peaks; 0.3s caps derived HR at 200bpm.
  final double minPeakIntervalSeconds;

  /// Number of trailing IBIs averaged into each HR sample.
  final int hrWindow;

  double? _prevValue;
  double? _prevPrevValue;
  double? _prevTimestamp;
  double? _lastPeakTimestamp;
  final Queue<double> _recentIbi = Queue<double>();

  /// Feed one decoded BVP sample; returns any samples derived from it (an
  /// `ibi` sample when a beat is detected, immediately followed by an `hr`
  /// sample — otherwise empty).
  List<E4Sample> addBvpSample(double timestamp, double value) {
    final derived = <E4Sample>[];
    final prevValue = _prevValue;
    final prevPrevValue = _prevPrevValue;
    final prevTimestamp = _prevTimestamp;

    if (prevValue != null && prevPrevValue != null && prevTimestamp != null) {
      final isLocalMax = prevValue > prevPrevValue && prevValue > value;
      final lastPeak = _lastPeakTimestamp;
      final sinceLastPeak = lastPeak == null ? double.infinity : prevTimestamp - lastPeak;

      if (isLocalMax && sinceLastPeak >= minPeakIntervalSeconds) {
        if (lastPeak != null) {
          final interval = prevTimestamp - lastPeak;
          derived.add(E4Sample(signal: E4Signal.ibi, timestamp: prevTimestamp, values: [interval]));

          _recentIbi.addLast(interval);
          while (_recentIbi.length > hrWindow) {
            _recentIbi.removeFirst();
          }
          final meanIbi = _recentIbi.reduce((a, b) => a + b) / _recentIbi.length;
          if (meanIbi > 0) {
            derived.add(E4Sample(signal: E4Signal.hr, timestamp: prevTimestamp, values: [60.0 / meanIbi]));
          }
        }
        _lastPeakTimestamp = prevTimestamp;
      }
    }

    _prevPrevValue = _prevValue;
    _prevValue = value;
    _prevTimestamp = timestamp;
    return derived;
  }
}
