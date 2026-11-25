import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../model/e4_sample.dart';

/// Calibration offset (degC) added to the decoded skin temperature. Exposed as
/// a parameter — never baked in silently — because a real thermistor never
/// matches real skin. Default 0.0: the old 0.46 was tuned to the previous
/// (`raw*0.02-276`) formula, not to `raw/500`; re-tune against a thermometer.
const double defaultTempCalibration = 0.0;

/// EDA/GSR (`0x3EA8`): 20-byte notification, six samples of
/// (uint16 big-endian value + constant `0xAC` flag byte) = 18 bytes, then
/// byte 18 (always 0) and an 8-bit packet counter in byte 19. Returns **raw ADC counts** (~3500-7000 at
/// rest), NOT µS: the µS factor is firmware-internal and needs a calibration
/// resistor. Layout is reverse-engineered, **unverified** — see CLAUDE.md.
List<double> decodeEda(Uint8List packet) {
  if (packet.length < 20) return const [];
  final readings = <double>[];
  for (var i = 0; i < 18; i += 3) {
    readings.add(((packet[i] << 8) | packet[i + 1]).toDouble()); // packet[i + 2] = flag
  }
  return readings;
}

/// EDA 8-bit packet counter (byte 19), or null for a short packet. Cycles
/// 1..255 and skips 0 (byte 18 is always 0 in the 2026-11-02 capture; 255 -> 1).
int? edaCounter(Uint8List packet) => packet.length < 20 ? null : packet[19];

/// Skin temperature (`0x3EA6`): 20-byte notification, eight little-endian
/// uint16 samples (bytes 0-15), then a 4-byte big-endian counter.
/// `degC = raw / 500` (empirical, **unverified**) `+ calibration`.
List<double> decodeTemp(
  Uint8List packet, {
  double calibration = defaultTempCalibration,
}) {
  if (packet.length < 20) return const [];
  final readings = <double>[];
  for (var i = 0; i < 16; i += 2) {
    final raw = packet[i] | (packet[i + 1] << 8);
    readings.add(raw / 500.0 + calibration);
  }
  return readings;
}

/// Temp 4-byte big-endian counter (bytes 16-19), or null for a short packet.
int? tempCounter(Uint8List packet) =>
    packet.length < 20 ? null : (packet[16] << 24) | (packet[17] << 16) | (packet[18] << 8) | packet[19];

/// Accelerometer (`0x3EA3`): signed-byte (x, y, z) triples, raw `64 * g`
/// ints — the same units Empatica's own `ACC.csv` export uses, so callers
/// store these values directly without further scaling. A full packet is six
/// triples (bytes 0-17); byte 18 varies 0x85-0x8B (meaning unknown), byte 19 is a packet
/// counter cycling 1..255 (0 skipped).
List<List<int>> decodeAcc(Uint8List packet) {
  final readings = <List<int>>[];
  for (var i = 0; i + 3 <= packet.length; i += 3) {
    readings.add([_toInt8(packet[i]), _toInt8(packet[i + 1]), _toInt8(packet[i + 2])]);
  }
  return readings;
}

/// ACC packet counter (byte 19, 1..255, 0 skipped), or null for a short packet.
int? accCounter(Uint8List packet) => packet.length < 20 ? null : packet[19];

int _toInt8(int byte) => byte > 127 ? byte - 256 : byte;

/// BVP samples per 20-byte notification: 5.818 packets/s x 11 = 64.0 Hz exactly
/// (2026-11-02 capture).
const int bvpSamplesPerPacket = 11;

/// BVP packet counter: low 6 bits of byte 19, cycling 1..63 (0 skipped), or
/// null for a short packet. The 2 high bits of byte 19 are sample data.
int? bvpCounter(Uint8List packet) => packet.length < 20 ? null : packet[19] & 0x3F;

/// Tag/button (`0x3EB2`, service `0x3EB0`): byte 0 = 0x01, bytes 1-4 = u32
/// little-endian counter, bytes 5-8 = the same counter repeated. Returns
/// the counter (`counter / 64` = seconds since the BVP stream started, verified
/// within 0.06 s against 3 button presses), or null if the packet isn't a tag.
int? decodeTagCounter(Uint8List packet) {
  if (packet.length < 9 || packet[0] != 0x01) return null;
  final data = ByteData.sublistView(packet);
  final counter = data.getUint32(1, Endian.little);
  return counter == data.getUint32(5, Endian.little) ? counter : null;
}

/// Battery (`0x3EB3`, service `0x3EB0`, GATT label "Battery"): 20-byte
/// notification, ~1 per 280 s. Bytes 0..17 hold fourteen unsigned 10-bit
/// fields packed MSB-first (140 bits), then 4 zero pad bits (low nibble of
/// byte 17), then a big-endian u16 per-connection packet counter (bytes
/// 18-19, starts at 1). Layout verified on 11 real packets
/// (docs/plan/e4-battery-decoding.md). Fields read ~983-996 on a near-full
/// cell and fall while streaming: taken as raw battery-voltage ADC samples
/// (UNVERIFIED scaling).
@visibleForTesting
List<int> unpackBattery10Bit(Uint8List packet) {
  final fields = <int>[];
  var acc = 0;
  var bits = 0;
  for (var i = 0; i < 18 && fields.length < 14; i++) {
    acc = (acc << 8) | packet[i];
    bits += 8;
    while (bits >= 10 && fields.length < 14) {
      bits -= 10;
      fields.add((acc >> bits) & 0x3FF);
      acc &= (1 << bits) - 1;
    }
  }
  return fields;
}

/// Lowest plausible median: ~2.95 V under the provisional 4.217 mV/count
/// scaling, below the Li-ion protection cutoff, so the E4 could not be running.
const int _batteryMinPlausibleCounts = 700;

/// Median (upper, sorted[7]) of the 14 battery fields, or null if the packet
/// is short, the pad nibble is non-zero (layout changed), or the value is
/// implausible. Median, not mean: single fields dip 6-9 counts under load.
int? decodeBatteryCounts(Uint8List packet) {
  if (packet.length < 20 || (packet[17] & 0x0F) != 0) return null;
  final fields = unpackBattery10Bit(packet)..sort();
  final median = fields[fields.length ~/ 2];
  return median < _batteryMinPlausibleCounts ? null : median;
}

/// Whether [batteryCountsCurve] has been calibrated against a full-discharge
/// capture. The UI shows "Calibrating" instead of a percentage while false;
/// flip to true after replacing the curve (docs/plan/e4-battery-decoding.md s9).
const bool batteryCurveCalibrated = false;

/// Counts -> 0..1 state-of-charge, piecewise linear, descending counts.
/// ponytail: PROVISIONAL. Assumes counts are proportional to volts with
/// 996 ~ 4.20 V (4.217 mV/count); points = 4.20 V/1.0, 3.95 V/0.94,
/// 3.55 V/0.0625, 3.40 V/0.0 (Adafruit + Zephyr LiPo curves). Replace rows
/// with measured (counts, fraction) pairs from a full-discharge capture —
/// this table is the only calibration knob.
const List<(int, double)> batteryCountsCurve = [(996, 1.0), (937, 0.94), (842, 0.0625), (806, 0.0)];

double batteryFraction(int counts, {List<(int, double)> curve = batteryCountsCurve}) {
  if (counts >= curve.first.$1) return curve.first.$2;
  for (var i = 1; i < curve.length; i++) {
    final (hiCounts, hiFraction) = curve[i - 1];
    final (loCounts, loFraction) = curve[i];
    if (counts >= loCounts) {
      return loFraction + (counts - loCounts) / (hiCounts - loCounts) * (hiFraction - loFraction);
    }
  }
  return curve.last.$2;
}

const List<double> _firCoefficients = [0.05, 0.1, 0.2, 0.3, 0.2, 0.1, 0.05];
const double _bvpScaleFactor = 10.0;

/// Whether the even 7-bit BVP fields are signed *deltas* (integrated into a
/// running level) or already raw levels. UNSETTLED: both show the pulse in the
/// captures (docs/plan/activity-log.md, "BVP investigation"); flip this one
/// flag to switch.
const bool bvpEvenFieldsAreDeltas = true;

/// BVP/PPG (`0x3EA1`) decoder. Stateful (FIR + Kalman filter chain carried
/// across packets), so — unlike the other three decoders — this is a class,
/// not a pure function. It is the single place the filter chain lives,
/// swappable wholesale once a real Empatica streaming-server recording is
/// available to validate against.
///
/// **UNVERIFIED**: this is a filtered approximation of Empatica's own
/// proprietary BVP algorithm, not a byte-identical decode. Only the EVEN 7-bit
/// field of each pair is used (one per sample); the ODD field is discarded and
/// its meaning is unknown. A pulse at ~85-90 bpm was observed in two captures,
/// but there is no ground-truth reference. See CLAUDE.md.
class BvpDecoder {
  final Queue<double> _fir = Queue.of(List.filled(_firCoefficients.length, 0.0));
  double _kalmanP = 1.0;
  double _kalmanX = 0.0;
  static const double _kalmanQ = 0.01;
  static const double _kalmanR = 0.1;

  // Running sum of the even fields when [bvpEvenFieldsAreDeltas] is true.
  // ponytail: unbounded running sum, but doubles carry ~15 significant
  // digits and the band-pass high-pass stage below removes slow drift
  // anyway, so this never needs resetting within a realistic session.
  double _level = 0.0;

  // A heart rate signal lives in ~0.5-4Hz (30-240bpm); this single-pole
  // high-pass->low-pass cascade confines the output to that band.
  final _OnePoleBandPass _bandPass = _OnePoleBandPass(sampleRateHz: 64.0, lowHz: 0.5, highHz: 4.0);

  /// Decodes one 20-byte BVP notification into [bvpSamplesPerPacket] (11)
  /// filtered samples: 154 sample bits = bytes 0-18 plus the top 2 bits of
  /// byte 19 (its low 6 bits are the packet counter) = 22 seven-bit values,
  /// two per sample.
  ///
  /// UNVERIFIED: only the even field (index 0, 2, ..., 20) of each pair is
  /// used; the odd field is discarded (meaning unknown, no pulse seen in it).
  List<double> decode(Uint8List packet) {
    if (packet.length < 20) return const [];
    final decoded = _unpack7Bit(packet);

    final readings = <double>[];
    for (var i = 0; i < bvpSamplesPerPacket; i++) {
      final field = decoded[i * 2];
      final input = bvpEvenFieldsAreDeltas ? (_level += field) : field.toDouble();
      _push(_fir, input);
      final filtered = _weightedSum(_fir);

      final kalmanOut = _kalmanFilter(filtered, filtered);
      final bandPassed = _bandPass.apply(kalmanOut);

      readings.add(_roundTo2(-bandPassed * _bvpScaleFactor));
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

  /// 7-bit unpacking of the 154 sample bits (bytes 0-18 + top 2 bits of byte
  /// 19) into 22 signed values, MSB-first. The bit layout is from a
  /// reverse-engineered third-party port; what the values mean is UNVERIFIED
  /// (see CLAUDE.md).
  @visibleForTesting
  static List<int> unpack7Bit(Uint8List data) => _unpack7Bit(data);

  static List<int> _unpack7Bit(Uint8List data) {
    final decoded = <int>[];
    var acc = 0;
    var bits = 0;
    for (var i = 0; i < 20; i++) {
      final width = i < 19 ? 8 : 2;
      acc = (acc << width) | (i < 19 ? data[i] : data[19] >> 6);
      bits += width;
      while (bits >= 7) {
        bits -= 7;
        decoded.add(_signExtend7((acc >> bits) & 0x7F));
      }
      acc &= (1 << bits) - 1;
    }
    return decoded;
  }

  static int _signExtend7(int value) {
    var v = value & 0x7F;
    if (v & 0x40 != 0) v |= 0x80;
    if (v > 127) v -= 256;
    return v;
  }
}

/// A minimal single-pole high-pass -> single-pole low-pass cascade, i.e. a
/// cheap band-pass filter. Plain stdlib math, no FFT/filter-design package —
/// the two cutoffs below are tuned for a 0.5-4Hz (30-240bpm) heart-rate band
/// at a fixed 64Hz BVP sample rate.
class _OnePoleBandPass {
  _OnePoleBandPass({required double sampleRateHz, required double lowHz, required double highHz})
      : _alphaHp = _rc(lowHz) / (_rc(lowHz) + 1 / sampleRateHz),
        _alphaLp = (1 / sampleRateHz) / (_rc(highHz) + 1 / sampleRateHz);

  static double _rc(double cutoffHz) => 1 / (2 * math.pi * cutoffHz);

  final double _alphaHp;
  final double _alphaLp;
  double _hpPrevIn = 0.0;
  double _hpPrevOut = 0.0;
  double _lpPrevOut = 0.0;

  double apply(double x) {
    final hp = _alphaHp * (_hpPrevOut + x - _hpPrevIn);
    _hpPrevIn = x;
    _hpPrevOut = hp;
    _lpPrevOut += _alphaLp * (hp - _lpPrevOut);
    return _lpPrevOut;
  }
}

/// Derives heartbeat intervals (IBI) and heart rate (HR) offline from a
/// stream of already-decoded BVP samples, via local-maximum peak detection
/// with a refractory period and an adaptive amplitude threshold. This is the
/// documented fallback (plan §3.2/CLAUDE.md): no BLE characteristic for
/// HR/IBI has been found, but Empatica computes HR from IBI the same way —
/// a rolling mean over the last [hrWindow] intervals.
///
/// ponytail: the amplitude threshold is a simple decaying-max envelope
/// follower, not a full Pan-Tompkins-style pipeline. Upgrade if HR/IBI
/// accuracy against real hardware proves insufficient (see plan step 9).
class HrIbiPeakDetector {
  HrIbiPeakDetector({this.minPeakIntervalSeconds = 0.4, this.hrWindow = 10});

  /// Refractory period between accepted peaks; 0.4s caps derived HR at 150bpm.
  final double minPeakIntervalSeconds;

  /// Number of trailing IBIs averaged into each HR sample.
  final int hrWindow;

  double? _prevValue;
  double? _prevPrevValue;
  double? _prevTimestamp;
  double? _lastPeakTimestamp;
  double? _hrT0;
  int _lastHrRow = -1;
  final Queue<double> _recentIbi = Queue<double>();

  // Decaying-max envelope of the (rectified) signal: a candidate peak only
  // counts as a beat if it clears a fraction of the recently-seen
  // amplitude, so flat/noisy stretches can't trip the detector on their own
  // — this, not the refractory period alone, is what keeps noise from being
  // read as a 150-200bpm heart rate.
  //
  // Tuned for fast recovery after a motion artifact: a wrist movement can
  // swing the integrated BVP signal (see BvpDecoder above) into the
  // thousands, dwarfing a normal cardiac peak (tens of units). At the old
  // 0.999/sample decay (~11s half-life at 64Hz) one spike kept the 30%
  // threshold elevated for 15-19s, silently rejecting every real beat in
  // that window and starving _recentIbi down to a couple of huge intervals
  // (-> 4-5s "IBI", 12-13bpm "HR"). 0.995/sample (~2-3s half-life) recovers
  // fast enough that a few seconds of bad data can't poison tens of seconds
  // of HR.
  double _envelope = 0.0;
  static const double _envelopeDecayPerSample = 0.995;
  static const double _peakThresholdFraction = 0.3;
  static const double _envelopeFloor = 1.0;

  // A sample far above the recent (decay-only, not yet touched by this
  // sample) envelope is a motion artifact, not part of the cardiac
  // waveform — tuned, not derived from a device spec. It is dropped
  // entirely (envelope just keeps decaying, the sample never becomes
  // `_prevValue`/`_prevPrevValue`) rather than merely capped: a capped
  // value still ratchets the envelope upward on every spike sample, so a
  // sustained burst (not just one isolated outlier) would otherwise still
  // blow the envelope up and keep the threshold elevated for many seconds.
  static const double _artifactRejectionMultiple = 2.5;

  // A gap this large between accepted peaks means beats were missed (e.g.
  // across a run of dropped artifact samples above), not that the heart
  // truly paused for that long — averaging across it would drag the
  // rolling HR down for `hrWindow` more beats. Sits inside the documented
  // 1.5-2s "treat as reset" range (CLAUDE.md) and well above the 0.4s
  // refractory period, so it only ever fires on a genuine gap.
  static const double _maxPlausibleIntervalSeconds = 1.8;

  /// Feed one decoded BVP sample; returns any samples derived from it (an
  /// `ibi` sample when a beat is detected, and an `hr` sample at most once per
  /// whole second — otherwise empty).
  List<E4Sample> addBvpSample(double timestamp, double value) {
    final derived = <E4Sample>[];

    final decayedEnvelope = _envelope * _envelopeDecayPerSample;
    final artifactFloor = math.max(decayedEnvelope, _envelopeFloor) * _artifactRejectionMultiple;
    if (value.abs() > artifactFloor) {
      _envelope = decayedEnvelope;
      return derived;
    }
    _envelope = math.max(value, decayedEnvelope);

    final prevValue = _prevValue;
    final prevPrevValue = _prevPrevValue;
    final prevTimestamp = _prevTimestamp;

    if (prevValue != null && prevPrevValue != null && prevTimestamp != null) {
      final isLocalMax = prevValue > prevPrevValue && prevValue > value;
      final abovePeakThreshold = prevValue >= _envelope * _peakThresholdFraction;
      final lastPeak = _lastPeakTimestamp;
      final sinceLastPeak = lastPeak == null ? double.infinity : prevTimestamp - lastPeak;

      if (isLocalMax && abovePeakThreshold && sinceLastPeak >= minPeakIntervalSeconds) {
        if (lastPeak != null) {
          final interval = prevTimestamp - lastPeak;
          if (interval > _maxPlausibleIntervalSeconds) {
            // Gap too large to trust: discard it and the averaging window
            // rather than let one inflated interval drag HR down for the
            // next `hrWindow` beats.
            _recentIbi.clear();
          } else {
            derived.add(E4Sample(signal: E4Signal.ibi, timestamp: prevTimestamp, values: [interval]));

            _recentIbi.addLast(interval);
            while (_recentIbi.length > hrWindow) {
              _recentIbi.removeFirst();
            }
          }
        }
        _lastPeakTimestamp = prevTimestamp;
      }
    }

    _prevPrevValue = _prevValue;
    _prevValue = value;
    _prevTimestamp = timestamp;

    // HR is 1 Hz (Empatica's HR.csv is positional at 1 Hz): one sample per
    // whole second. Seconds with no IBI window (after a gap reset) are skipped
    // and the writer gap-pads them as "HR unknown".
    //
    // The grid is anchored at the first emitted HR (= HR.csv's t0) and every
    // sample is stamped exactly on it (t0 + row), NOT at the BVP sample time:
    // the writer places rows at round(ts - t0), so a sample resuming mid-second
    // after a gap landed a row early, was padded, and the next on-time sample
    // collided with it and was dropped as "out-of-order".
    final t0 = _hrT0 ?? timestamp;
    final row = ((timestamp - t0)).floor();
    if (row > _lastHrRow && _recentIbi.isNotEmpty) {
      final meanIbi = _recentIbi.reduce((a, b) => a + b) / _recentIbi.length;
      if (meanIbi > 0) {
        _hrT0 = t0;
        _lastHrRow = row;
        derived.add(E4Sample(signal: E4Signal.hr, timestamp: t0 + row, values: [60.0 / meanIbi]));
      }
    }
    return derived;
  }
}
