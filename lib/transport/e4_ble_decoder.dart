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
  double _kalmanP = 1.0;
  double _kalmanX = 0.0;
  static const double _kalmanQ = 0.01;
  static const double _kalmanR = 0.1;

  // decoded[] out of _unpack7Bit is a stream of signed 7-bit *deltas*, not
  // absolute levels — these running sums reconstruct the green/red waveform
  // levels by integrating every delta across every packet (stateful, like
  // the Kalman filter below). Filtering the raw deltas directly (the
  // previous bug) is near-flat high-frequency noise, not a waveform, which
  // is why peak detection downstream was finding a "peak" every refractory
  // window and inflating HR.
  // ponytail: unbounded running sum, but doubles carry ~15 significant
  // digits and the band-pass high-pass stage below removes slow drift
  // anyway, so this never needs resetting within a realistic session.
  double _greenLevel = 0.0;
  double _redLevel = 0.0;

  // Replaces the old third FIR stage: that was just another low-pass
  // smoothing filter (wide-band at 64Hz), not a band-pass, so baseline
  // wander and out-of-band noise survived into the peak detector. A heart
  // rate signal lives in ~0.5-4Hz (30-240bpm); this single-pole
  // high-pass->low-pass cascade confines the output to that band.
  final _OnePoleBandPass _bandPass = _OnePoleBandPass(sampleRateHz: 64.0, lowHz: 0.5, highHz: 4.0);

  /// Decodes one 20-byte BVP notification into up to 11 filtered samples.
  List<double> decode(Uint8List packet) {
    if (packet.length < 20) return const [];
    final decoded = _unpack7Bit(packet);

    final readings = <double>[];
    final pairs = decoded.length ~/ 2;
    for (var i = 0; i < pairs && i < 11; i++) {
      _greenLevel += decoded[i * 2];
      _redLevel += decoded[i * 2 + 1];

      _push(_fir1, _redLevel);
      final filteredRed = _weightedSum(_fir1);

      final weighted = (_redLevel + _greenLevel * 10.0) / 11.0;
      _push(_fir2, weighted);
      final filteredWeighted = _weightedSum(_fir2);

      final kalmanOut = _kalmanFilter(filteredRed, filteredWeighted);
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
  /// `ibi` sample when a beat is detected, immediately followed by an `hr`
  /// sample — otherwise empty).
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
            final meanIbi = _recentIbi.reduce((a, b) => a + b) / _recentIbi.length;
            if (meanIbi > 0) {
              derived.add(E4Sample(signal: E4Signal.hr, timestamp: prevTimestamp, values: [60.0 / meanIbi]));
            }
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
