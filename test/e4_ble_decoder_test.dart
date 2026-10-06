import 'dart:math' as math;
import 'dart:typed_data';

import 'package:e4_integrator/model/e4_sample.dart';
import 'package:e4_integrator/transport/e4_ble_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('decodeEda', () {
    test('20-byte packet decodes six 24-bit big-endian µS samples', () {
      const rawValues = [500000, 1000000, 250000, 0, 2000000, 100000];
      final packet = <int>[];
      for (final raw in rawValues) {
        packet.addAll([(raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF]);
      }
      packet.addAll([0x00, 0x01]); // trailing packet-counter bytes

      final readings = decodeEda(_bytes(packet));

      expect(readings, hasLength(6));
      expect(readings[0], closeTo(2.0, 1e-9));
      expect(readings[1], closeTo(1.0, 1e-9));
      expect(readings[2], closeTo(4.0, 1e-9));
      expect(readings[3], closeTo(0.0, 1e-9)); // raw == 0 => 0 µS, not a divide-by-zero
      expect(readings[4], closeTo(0.5, 1e-9));
      expect(readings[5], closeTo(10.0, 1e-9));
    });

    test('short packet returns empty list, never throws', () {
      expect(decodeEda(_bytes(List.filled(5, 0))), isEmpty);
    });
  });

  group('decodeTemp', () {
    test('12-byte packet decodes four little-endian uint16 samples', () {
      const rawValues = [15400, 15450, 15500, 15550];
      final packet = <int>[];
      for (final raw in rawValues) {
        packet.addAll([raw & 0xFF, (raw >> 8) & 0xFF]);
      }
      packet.addAll([0, 0, 0, 0]); // unused trailing bytes

      final readings = decodeTemp(_bytes(packet));

      expect(readings, hasLength(4));
      for (var i = 0; i < rawValues.length; i++) {
        expect(readings[i], closeTo((rawValues[i] * 0.02) - 276.0 + defaultTempCalibration, 1e-9));
      }
    });

    test('calibration constant is a parameter, not baked in', () {
      final packet = _bytes([0xE8, 0x3C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]); // first sample raw 0x3CE8 = 15592
      final defaultReading = decodeTemp(packet).first;
      final customReading = decodeTemp(packet, calibration: 1.0).first;
      expect(customReading - defaultReading, closeTo(1.0 - defaultTempCalibration, 1e-9));
    });

    test('short packet returns empty list, never throws', () {
      expect(decodeTemp(_bytes(List.filled(4, 0))), isEmpty);
    });
  });

  group('decodeAcc', () {
    test('signed-byte x/y/z triples, negatives preserved', () {
      // -64, 64, -1  |  0, 127, -128
      final packet = _bytes([0xC0, 0x40, 0xFF, 0x00, 0x7F, 0x80]);
      final readings = decodeAcc(packet);
      expect(readings, [
        [-64, 64, -1],
        [0, 127, -128],
      ]);
    });

    test('trailing partial triple is dropped, not read out of bounds', () {
      final packet = _bytes([1, 2, 3, 4, 5]); // 5 bytes: one full triple + 2 leftover
      expect(decodeAcc(packet), [
        [1, 2, 3],
      ]);
    });
  });

  group('BvpDecoder', () {
    test('short packet returns empty list, never throws', () {
      expect(BvpDecoder().decode(Uint8List(10)), isEmpty);
    });

    test('all-zero packet decodes deterministically to 11 zero samples', () {
      final readings = BvpDecoder().decode(Uint8List(20));
      expect(readings, hasLength(11));
      for (final v in readings) {
        expect(v, closeTo(0.0, 1e-9));
      }
    });

    test('captured real packets decode to finite, bounded readings', () {
      // Three consecutive 20-byte BVP notifications captured from a real E4,
      // fed through one decoder instance (stateful, so order matters). Not
      // enough samples here (~0.5s) for a full cardiac cycle, so this only
      // guards against the regression (raw deltas read as absolute levels)
      // blowing up into NaN/Infinity or producing more than 11 samples/packet
      // — not a real HR assertion.
      final packets = [
        _bytes([0xff, 0xfc, 0x0f, 0xff, 0xe0, 0x00, 0x82, 0xfe, 0x04, 0x0f, 0xcf, 0xe0, 0x00, 0x03, 0x03, 0xf7, 0xf8, 0x20, 0x1f, 0xed]),
        _bytes([0x00, 0x0c, 0x1f, 0xef, 0xe0, 0x3f, 0xfc, 0x04, 0x17, 0xff, 0xf0, 0x00, 0x3f, 0x7e, 0x04, 0x07, 0xf0, 0x0f, 0xe0, 0x2e]),
        _bytes([0x03, 0xfc, 0x00, 0x00, 0x20, 0x3f, 0x82, 0x07, 0xfc, 0x00, 0x1f, 0xdf, 0xc0, 0x7e, 0x02, 0x0f, 0xef, 0xf0, 0x40, 0x6f]),
      ];

      final decoder = BvpDecoder();
      final detector = HrIbiPeakDetector();
      var t = 0.0;
      for (final packet in packets) {
        final readings = decoder.decode(packet);
        expect(readings.length, lessThanOrEqualTo(11));
        for (final value in readings) {
          expect(value.isFinite, isTrue);
          for (final sample in detector.addBvpSample(t, value)) {
            expect(sample.values.single.isFinite, isTrue);
          }
          t += 1 / 64.0;
        }
      }
    });
  });

  group('HrIbiPeakDetector', () {
    test('derives plausible IBI/HR from a synthetic periodic BVP signal', () {
      const periodSeconds = 0.8; // 75 bpm
      const rateHz = 64.0;
      const durationSeconds = 6.0;

      final detector = HrIbiPeakDetector();
      final ibiSamples = <E4Sample>[];
      final hrSamples = <E4Sample>[];

      final sampleCount = (durationSeconds * rateHz).round();
      for (var i = 0; i < sampleCount; i++) {
        final t = i / rateHz;
        final value = math.sin(2 * math.pi * t / periodSeconds);
        for (final sample in detector.addBvpSample(t, value)) {
          (sample.signal == E4Signal.ibi ? ibiSamples : hrSamples).add(sample);
        }
      }

      expect(ibiSamples, isNotEmpty);
      expect(hrSamples, isNotEmpty);
      // First interval is skipped (no prior peak); every detected interval
      // afterwards should land close to the true 0.8s period.
      for (final sample in ibiSamples) {
        expect(sample.values.single, closeTo(periodSeconds, 0.05));
      }
      for (final sample in hrSamples) {
        expect(sample.values.single, closeTo(60.0 / periodSeconds, 5.0));
      }
    });

    test('regression: ~1.2Hz pulse yields ~72bpm, not the old >120-130bpm', () {
      const periodSeconds = 1 / 1.2; // 72 bpm
      const rateHz = 64.0;
      const durationSeconds = 8.0;

      final detector = HrIbiPeakDetector();
      final ibiSamples = <E4Sample>[];
      final hrSamples = <E4Sample>[];

      final sampleCount = (durationSeconds * rateHz).round();
      for (var i = 0; i < sampleCount; i++) {
        final t = i / rateHz;
        final value = math.sin(2 * math.pi * t / periodSeconds);
        for (final sample in detector.addBvpSample(t, value)) {
          (sample.signal == E4Signal.ibi ? ibiSamples : hrSamples).add(sample);
        }
      }

      expect(ibiSamples, isNotEmpty);
      expect(hrSamples, isNotEmpty);
      for (final sample in ibiSamples) {
        expect(sample.values.single, closeTo(periodSeconds, 0.05));
      }
      for (final sample in hrSamples) {
        expect(sample.values.single, closeTo(72.0, 5.0));
      }
    });

    test('regression: motion-artifact spike recovers to ~72bpm, not stuck at 12-13bpm', () {
      const periodSeconds = 1 / 1.2; // 72 bpm
      const rateHz = 64.0;

      final detector = HrIbiPeakDetector();
      final hrSamples = <E4Sample>[];
      var t = 0.0;

      void feed(double value) {
        for (final sample in detector.addBvpSample(t, value)) {
          if (sample.signal == E4Signal.hr) hrSamples.add(sample);
        }
        t += 1 / rateHz;
      }

      // A few seconds of clean pulse to establish a normal envelope.
      for (var i = 0; i < (2.0 * rateHz).round(); i++) {
        feed(math.sin(2 * math.pi * t / periodSeconds));
      }

      // Motion artifact: BVP swings far outside any physiological range
      // (~10000, per CLAUDE.md/plan doc) for ~0.2s.
      for (var i = 0; i < (0.2 * rateHz).round(); i++) {
        feed(i.isEven ? 10000.0 : -10000.0);
      }

      // Resume the same clean pulse for several seconds.
      for (var i = 0; i < (8.0 * rateHz).round(); i++) {
        feed(math.sin(2 * math.pi * t / periodSeconds));
      }

      expect(hrSamples, isNotEmpty);
      // Only the tail is asserted: the beat(s) spanning the spike's
      // recovery window are expected to be reset/discarded (no HR emitted
      // for an implausible gap), not asserted on here.
      for (final sample in hrSamples.skip(hrSamples.length - 3)) {
        expect(sample.values.single, closeTo(72.0, 5.0));
      }
    });
  });
}
