import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:e4_integrator/model/e4_sample.dart';
import 'package:e4_integrator/storage/e4_session_writer.dart';
import 'package:e4_integrator/transport/ble_transport.dart';
import 'package:e4_integrator/transport/e4_ble_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('decodeEda', () {
    test('20-byte packet decodes six uint16 BE raw samples, skipping 0xAC flag', () {
      const rawValues = [3500, 7000, 0, 65535, 4660, 100];
      final packet = <int>[];
      for (final raw in rawValues) {
        packet.addAll([(raw >> 8) & 0xFF, raw & 0xFF, 0xAC]);
      }
      packet.addAll([0x00, 0x02]); // byte 18 always 0, byte 19 = counter

      expect(decodeEda(_bytes(packet)), rawValues.map((v) => v.toDouble()).toList());
      expect(edaCounter(_bytes(packet)), 2);
    });

    test('short packet returns empty list, never throws', () {
      expect(decodeEda(_bytes(List.filled(5, 0))), isEmpty);
      expect(edaCounter(_bytes(List.filled(5, 0))), isNull);
    });
  });

  group('decodeTemp', () {
    test('20-byte packet decodes eight LE uint16 samples as raw/500', () {
      const rawValues = [15400, 15450, 15500, 15550, 15600, 15650, 15700, 15750];
      final packet = <int>[];
      for (final raw in rawValues) {
        packet.addAll([raw & 0xFF, (raw >> 8) & 0xFF]);
      }
      packet.addAll([0, 0, 0x01, 0x02]); // trailing 4-byte BE counter

      final readings = decodeTemp(_bytes(packet));

      expect(readings, hasLength(8));
      for (var i = 0; i < rawValues.length; i++) {
        expect(readings[i], closeTo(rawValues[i] / 500.0 + defaultTempCalibration, 1e-9));
      }
      expect(tempCounter(_bytes(packet)), 0x0102);
    });

    test('calibration constant is a parameter, not baked in', () {
      final packet = _bytes([0xE8, 0x3C, ...List.filled(18, 0)]); // first sample raw 0x3CE8 = 15592
      final defaultReading = decodeTemp(packet).first;
      final customReading = decodeTemp(packet, calibration: 1.0).first;
      expect(customReading - defaultReading, closeTo(1.0 - defaultTempCalibration, 1e-9));
    });

    test('short packet returns empty list, never throws', () {
      expect(decodeTemp(_bytes(List.filled(12, 0))), isEmpty);
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

  group('accCounter', () {
    test('reads byte 19; null for a short packet', () {
      expect(accCounter(_bytes([...List.filled(19, 0), 200])), 200);
      expect(accCounter(_bytes(List.filled(6, 0))), isNull);
    });
  });

  group('BvpDecoder', () {
    test('short packet returns empty list, never throws', () {
      expect(BvpDecoder().decode(Uint8List(10)), isEmpty);
    });

    test('all-zero packet decodes deterministically to 11 zero samples', () {
      final readings = BvpDecoder().decode(Uint8List(20));
      expect(readings, hasLength(bvpSamplesPerPacket));
      for (final v in readings) {
        expect(v, closeTo(0.0, 1e-9));
      }
    });

    test('captured real packets decode to finite, bounded readings', () {
      // Three consecutive 20-byte BVP notifications captured from a real E4,
      // fed through one decoder instance (stateful, so order matters). Not
      // enough samples here (~0.5s) for a full cardiac cycle, so this only
      // guards against the regression (raw deltas read as absolute levels)
      // blowing up into NaN/Infinity or a wrong samples/packet count
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
        expect(readings, hasLength(11));
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

  group('BvpDecoder even-field decode (UNVERIFIED model)', () {
    // 2000 consecutive 0x3EA1 packets (~5.7 min) from capture_2026-11-02_b.
    List<Uint8List> loadPackets() => File('test/fixtures/bvp_capture2_packets.txt')
        .readAsLinesSync()
        .where((l) => l.length == 40)
        .map((l) => _bytes([for (var i = 0; i < 40; i += 2) int.parse(l.substring(i, i + 2), radix: 16)]))
        .toList();

    List<double> decodeAll(List<Uint8List> packets) {
      final decoder = BvpDecoder();
      return [for (final p in packets) ...decoder.decode(p)];
    }

    test('emits exactly 11 samples per real packet', () {
      final packets = loadPackets();
      expect(packets, hasLength(2000));
      final decoder = BvpDecoder();
      for (final p in packets.take(50)) {
        expect(decoder.decode(p), hasLength(11));
      }
    });

    test('odd 7-bit fields do not influence the output', () {
      final packets = loadPackets().take(300).toList();
      // Odd field k (k = 1,3,..,21) occupies bit positions 7k..7k+6 MSB-first.
      final scrambled = packets.map((p) {
        final q = Uint8List.fromList(p);
        for (var k = 1; k < 22; k += 2) {
          for (var b = 7 * k; b < 7 * k + 7; b++) {
            q[b ~/ 8] ^= 0x80 >> (b % 8); // flip every bit of the odd field
          }
        }
        return q;
      }).toList();
      expect(scrambled.first, isNot(equals(packets.first)));
      expect(decodeAll(scrambled), decodeAll(packets));
    });

    test('real capture: most 40 s windows peak at ~1.35-1.6 Hz within 0.8-2.6 Hz', () {
      // Windows with wrist motion/drift peak at the band edge instead, so
      // assert a clear majority (6 of 8 in the capture), not every window.
      final signal = decodeAll(loadPackets());
      const window = 64 * 40;
      var total = 0;
      var inBand = 0;
      for (var w = 0; w + window <= signal.length; w += window) {
        final seg = signal.sublist(w, w + window);
        final mean = seg.reduce((a, b) => a + b) / seg.length;
        var bestHz = 0.0;
        var bestPower = -1.0;
        for (var hz = 0.8; hz <= 2.6; hz += 0.025) {
          var re = 0.0;
          var im = 0.0;
          for (var n = 0; n < seg.length; n++) {
            final phase = 2 * math.pi * hz * n / 64.0;
            re += (seg[n] - mean) * math.cos(phase);
            im += (seg[n] - mean) * math.sin(phase);
          }
          if (re * re + im * im > bestPower) {
            bestPower = re * re + im * im;
            bestHz = hz;
          }
        }
        total++;
        if (bestHz >= 1.35 && bestHz <= 1.6) inBand++;
      }
      expect(total, 8);
      expect(inBand, greaterThanOrEqualTo(5));
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
      final tail = hrSamples.skip(hrSamples.length - 3).toList();
      for (final sample in tail) {
        expect(sample.values.single, closeTo(72.0, 5.0));
      }
      // HR resumes at 1 Hz after the gap reset.
      expect(tail[1].timestamp.floor() - tail[0].timestamp.floor(), 1);
      expect(tail[2].timestamp.floor() - tail[1].timestamp.floor(), 1);
    });

    test('HR is 1 Hz and writes no out-of-order/dropped HR.csv rows (B1)', () async {
      const periodSeconds = 1 / 1.2; // 72 bpm
      const rateHz = 64.0;
      final detector = HrIbiPeakDetector();
      final derived = <E4Sample>[];
      for (var i = 0; i < (10.0 * rateHz).round(); i++) {
        final t = i / rateHz;
        derived.addAll(detector.addBvpSample(t, math.sin(2 * math.pi * t / periodSeconds)));
      }

      final hr = derived.where((s) => s.signal == E4Signal.hr).toList();
      expect(hr, isNotEmpty);
      for (var i = 1; i < hr.length; i++) {
        expect(hr[i].timestamp.floor() - hr[i - 1].timestamp.floor(), 1);
      }
      for (final s in hr) {
        expect(s.values.single, closeTo(72.0, 5.0));
      }

      final dir = await Directory.systemTemp.createTemp('e4_hr_1hz_test_');
      final writer = E4SessionWriter(dir);
      try {
        for (final s in derived) {
          await writer.write(s);
        }
        await writer.close();
        final logFile = File('${dir.path}/e4_integrator_log.txt');
        final log = await logFile.exists() ? await logFile.readAsString() : '';
        expect(log, isNot(contains('HR.csv')));
        final rows = await File('${dir.path}/HR.csv').readAsLines();
        expect(rows.skip(2).where((l) => l.isEmpty), isEmpty); // no gap-padded rows
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('HR resuming mid-second after a gap is not padded then dropped', () async {
      // Regression: HR was emitted on the absolute floor(second) grid but
      // HR.csv rows are round((ts - t0)) from a fractional t0, so a late-in-
      // the-second emission after a gap landed one row ahead, got padded, and
      // the next on-time sample collided with it and was dropped.
      const periodSeconds = 1 / 1.2;
      const rateHz = 64.0;
      final detector = HrIbiPeakDetector();
      final hr = <E4Sample>[];
      var t = 1000.37; // fractional start so t0 is off the whole-second grid
      void feed(double seconds, double Function(double) f) {
        for (var i = 0; i < (seconds * rateHz).round(); i++) {
          hr.addAll(detector.addBvpSample(t, f(t)).where((s) => s.signal == E4Signal.hr));
          t += 1 / rateHz;
        }
      }

      double pulse(double x) => math.sin(2 * math.pi * x / periodSeconds);
      for (var k = 0; k < 6; k++) {
        feed(6.0, pulse);
        feed(2.5, (_) => 0.0); // blackout: IBI window resets, HR resumes mid-second
      }
      feed(6.0, pulse);
      expect(hr.length, greaterThan(10));

      final dir = await Directory.systemTemp.createTemp('e4_hr_gap_test_');
      final writer = E4SessionWriter(dir);
      try {
        for (final s in hr) {
          await writer.write(s);
        }
        await writer.close();
        final logFile = File('${dir.path}/e4_integrator_log.txt');
        final log = await logFile.exists() ? await logFile.readAsString() : '';
        expect(log, isNot(contains('out-of-order')));
        // Every emitted sample got its own row: nothing dropped.
        final rows = await File('${dir.path}/HR.csv').readAsLines();
        expect(rows.skip(2).where((l) => l.isNotEmpty), hasLength(hr.length));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('BVP packet evidence', () {
    // Same three consecutive real packets as 'captured real packets' above.
    final packets = [
      _bytes([0xff, 0xfc, 0x0f, 0xff, 0xe0, 0x00, 0x82, 0xfe, 0x04, 0x0f, 0xcf, 0xe0, 0x00, 0x03, 0x03, 0xf7, 0xf8, 0x20, 0x1f, 0xed]),
      _bytes([0x00, 0x0c, 0x1f, 0xef, 0xe0, 0x3f, 0xfc, 0x04, 0x17, 0xff, 0xf0, 0x00, 0x3f, 0x7e, 0x04, 0x07, 0xf0, 0x0f, 0xe0, 0x2e]),
      _bytes([0x03, 0xfc, 0x00, 0x00, 0x20, 0x3f, 0x82, 0x07, 0xfc, 0x00, 0x1f, 0xdf, 0xc0, 0x7e, 0x02, 0x0f, 0xef, 0xf0, 0x40, 0x6f]),
    ];

    test('7-bit unpack of real packet 1 starts [-1,-1,1,-1,-1,0,1,2] (pins decode vs 12-bit model)', () {
      expect(BvpDecoder.unpack7Bit(packets[0]).take(8).toList(), [-1, -1, 1, -1, -1, 0, 1, 2]);
    });

    test('unpacks 154 bits (bytes 0-18 + top 2 bits of byte 19) into 22 seven-bit values', () {
      final packet = Uint8List(20)..[19] = 0xC0; // only the 2 high bits set
      final values = BvpDecoder.unpack7Bit(packet);
      expect(values, hasLength(22));
      expect(values.take(21), everyElement(0));
      expect(values.last, 3); // 5 zero bits of byte 18 + the two high bits of byte 19
      expect(BvpDecoder.unpack7Bit(_bytes(List.filled(20, 0xFF))), everyElement(-1));
    });

    test('byte 19 low 6 bits of 3 consecutive real packets count 45, 46, 47 (Q2: mod-64 counter hypothesis)', () {
      expect(packets.map((p) => p[19] & 0x3F).toList(), [45, 46, 47]);
      expect(packets.map(bvpCounter).toList(), [45, 46, 47]);
      expect(bvpCounter(Uint8List(5)), isNull);
    });
  });

  group('decodeTagCounter (0x3EB2)', () {
    // Real packets from the 2026-11-02 capture (3 button presses).
    List<int> tag(List<int> head) => [...head, ...List.filled(20 - head.length, 0)];
    final presses = {
      8540: tag([0x01, 0x5c, 0x21, 0x00, 0x00, 0x5c, 0x21, 0x00, 0x00, 0xc3, 0x48, 0xc3, 0x48]),
      13737: tag([0x01, 0xa9, 0x35, 0x00, 0x00, 0xa9, 0x35, 0x00, 0x00, 0xb4, 0xf6, 0xb4, 0xf6]),
      20027: tag([0x01, 0x3b, 0x4e, 0x00, 0x00, 0x3b, 0x4e, 0x00, 0x00, 0xa7, 0x1b, 0xa7, 0x1b]),
    };

    test('decodes the u32 LE counter of the three real presses', () {
      presses.forEach((counter, bytes) => expect(decodeTagCounter(_bytes(bytes)), counter));
      expect(8540 / 64, closeTo(133.4375, 1e-9)); // seconds since BVP stream start
    });

    test('rejects non-tag packets: short, wrong opcode, counter/repeat mismatch', () {
      expect(decodeTagCounter(Uint8List(5)), isNull);
      expect(decodeTagCounter(_bytes([0x02, ...presses[8540]!.skip(1)])), isNull);
      expect(decodeTagCounter(_bytes([...presses[8540]!]..[5] = 0)), isNull);
    });

    test('through E4SessionWriter: timestamp = bvpStart + counter/64 lands in tags.csv', () async {
      const bvpStart = 1793615878.528;
      final dir = await Directory.systemTemp.createTemp('e4_tag_test_');
      final writer = E4SessionWriter(dir);
      try {
        for (final bytes in presses.values) {
          final counter = decodeTagCounter(_bytes(bytes))!;
          await writer.write(E4Sample(signal: E4Signal.tag, timestamp: bvpStart + counter / 64.0, values: const []));
        }
        await writer.close();
        expect(await File('${dir.path}/tags.csv').readAsLines(), [
          (bvpStart + 8540 / 64).toStringAsFixed(6),
          (bvpStart + 13737 / 64).toStringAsFixed(6),
          (bvpStart + 20027 / 64).toStringAsFixed(6),
        ]);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('SeqClock (EDA/TEMP counter timestamps)', () {
    test('consecutive counters are contiguous; a missed packet is gap-padded; duplicate is empty', () {
      final clock = SeqClock(modulus: 65536);
      final a = clock.stamp(1, 100.0, 4, 4.0)!;
      final b = clock.stamp(2, 100.9, 4, 4.0)!; // arrival jitter ignored
      final c = clock.stamp(4, 101.5, 4, 4.0)!; // counter 3 missed
      expect(b.first - a.last, closeTo(0.25, 1e-9));
      expect(c.first - b.last, closeTo(0.25 * 5, 1e-9)); // 4 padded samples
      expect(clock.stamp(4, 102.0, 4, 4.0), isEmpty);
      expect(clock.stamp(null, 102.0, 4, 4.0), isNull);
    });

    test('wraps modulo the counter width without a false gap', () {
      final clock = SeqClock(modulus: 65536);
      final a = clock.stamp(65535, 0.0, 6, 4.0)!;
      final b = clock.stamp(0, 0.0, 6, 4.0)!;
      expect(b.first - a.last, closeTo(0.25, 1e-9));
      final t = SeqClock(modulus: 4294967296);
      final x = t.stamp(4294967295, 0.0, 8, 4.0)!;
      final y = t.stamp(0, 0.0, 8, 4.0)!;
      expect(y.first - x.last, closeTo(0.25, 1e-9));
    });

    test('skipZero: 255 -> 1 (ACC/EDA 8-bit) and 63 -> 1 (BVP 6-bit) wrap without a false gap', () {
      for (final (modulus, max, count, rate) in [(256, 255, 6, 32.0), (256, 255, 6, 4.0), (64, 63, 11, 64.0)]) {
        final clock = SeqClock(modulus: modulus, skipZero: true);
        final a = clock.stamp(max, 0.0, count, rate)!;
        final b = clock.stamp(1, 0.0, count, rate)!;
        expect(b.first - a.last, closeTo(1 / rate, 1e-9), reason: 'modulus $modulus');
      }
    });

    test('skipZero still detects a real gap across the wrap', () {
      final clock = SeqClock(modulus: 64, skipZero: true);
      final a = clock.stamp(62, 0.0, 11, 64.0)!;
      final b = clock.stamp(2, 0.0, 11, 64.0)!; // 63 and 1 missed
      expect(b.first - a.last, closeTo((1 + 2 * 11) / 64.0, 1e-9));
    });

    test('without skipZero the same 255 -> 1 wrap IS (wrongly) a 1-packet gap', () {
      final clock = SeqClock(modulus: 256);
      final a = clock.stamp(255, 0.0, 6, 32.0)!;
      final b = clock.stamp(1, 0.0, 6, 32.0)!;
      expect(b.first - a.last, closeTo((1 + 6) / 32.0, 1e-9));
    });

    test('reset() re-anchors to the next arrival', () {
      final clock = SeqClock(modulus: 256)..stamp(1, 10.0, 1, 4.0);
      clock.reset();
      expect(clock.stamp(200, 500.0, 1, 4.0), [500.0]);
    });

    test('through E4SessionWriter: a missed EDA packet gap-pads rows, a duplicate adds none', () async {
      final dir = await Directory.systemTemp.createTemp('e4_seqclock_test_');
      final writer = E4SessionWriter(dir);
      final clock = SeqClock(modulus: 65536);
      try {
        for (final counter in [1, 2, 4, 4]) {
          final stamps = clock.stamp(counter, 1000.0, 6, 4.0)!;
          for (var i = 0; i < stamps.length; i++) {
            await writer.write(E4Sample(signal: E4Signal.eda, timestamp: stamps[i], values: [i.toDouble()]));
          }
        }
        await writer.close();
        final rows = (await File('${dir.path}/EDA.csv').readAsLines()).skip(2).toList();
        expect(rows, hasLength(6 * 4)); // 3 packets + 1 padded packet; duplicate adds none
        expect(rows.where((l) => l.isEmpty), hasLength(6));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
