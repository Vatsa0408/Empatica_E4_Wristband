import 'dart:io';

import 'package:e4_integrator/model/e4_sample.dart';
import 'package:e4_integrator/storage/e4_session_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late E4SessionWriter writer;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('e4_session_writer_test_');
    writer = E4SessionWriter(tempDir);
  });

  tearDown(() async {
    await writer.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('ACC.csv: two-row header + gap-padded positional rows', () async {
    const rate = 32.0;
    const t0 = 1000.0;
    await writer.write(const E4Sample(signal: E4Signal.acc, timestamp: t0, values: [1, 2, 3]));
    // Skip rows 1 and 2 (simulates two dropped packets) before row 3.
    await writer.write(const E4Sample(signal: E4Signal.acc, timestamp: t0 + 3 / rate, values: [4, 5, 6]));
    await writer.close();

    final lines = await File('${tempDir.path}/ACC.csv').readAsLines();
    expect(lines, [
      t0.toStringAsFixed(6),
      '32.000000, 32.000000, 32.000000',
      '1.000000,2.000000,3.000000',
      ',,',
      ',,',
      '4.000000,5.000000,6.000000',
    ]);

    final log = await File('${tempDir.path}/e4_integrator_log.txt').readAsLines();
    expect(log, hasLength(2)); // one line logged per gap-padded row
  });

  test('EDA.csv: single-column positional rows with a gap', () async {
    const rate = 4.0;
    const t0 = 2000.0;
    await writer.write(const E4Sample(signal: E4Signal.eda, timestamp: t0, values: [0.5]));
    await writer.write(const E4Sample(signal: E4Signal.eda, timestamp: t0 + 2 / rate, values: [0.7]));
    await writer.close();

    final lines = await File('${tempDir.path}/EDA.csv').readAsLines();
    expect(lines, [t0.toStringAsFixed(6), '4.000000', '0.500000', '', '0.700000']);
  });

  test('IBI.csv: "<t0>, IBI" header, elapsed-time rows, no rate row', () async {
    const t0 = 3000.0;
    await writer.write(const E4Sample(signal: E4Signal.ibi, timestamp: t0, values: [0.8]));
    await writer.write(const E4Sample(signal: E4Signal.ibi, timestamp: t0 + 2.5, values: [0.75]));
    await writer.close();

    final lines = await File('${tempDir.path}/IBI.csv').readAsLines();
    expect(lines, ['${t0.toStringAsFixed(6)}, IBI', '0.000000,0.800000', '2.500000,0.750000']);
  });

  test('tags.csv: lowercase filename, bare timestamps, no header', () async {
    await writer.write(const E4Sample(signal: E4Signal.tag, timestamp: 4000.123456, values: []));
    await writer.write(const E4Sample(signal: E4Signal.tag, timestamp: 4010.5, values: []));
    await writer.close();

    final lines = await File('${tempDir.path}/tags.csv').readAsLines();
    expect(lines, ['4000.123456', '4010.500000']);
  });

  test('BAT.csv: documented IBI-style extension, not part of Empatica\'s format', () async {
    const t0 = 5000.0;
    await writer.write(const E4Sample(signal: E4Signal.battery, timestamp: t0, values: [0.9]));
    await writer.close();

    final lines = await File('${tempDir.path}/BAT.csv').readAsLines();
    expect(lines, ['${t0.toStringAsFixed(6)}, BAT', '0.000000,0.900000']);
  });

  test('a signal that never produced a sample never gets a file', () async {
    await writer.write(const E4Sample(signal: E4Signal.tag, timestamp: 1.0, values: []));
    await writer.close();
    expect(await File('${tempDir.path}/HR.csv').exists(), isFalse);
  });

  test('writeInfo() records device id, transport and the derived-data caveats', () async {
    await writer.writeInfo(deviceId: 'abc-123', transportDescription: 'Direct BLE (universal_ble)');
    final info = await File('${tempDir.path}/info.txt').readAsString();
    expect(info, contains('abc-123'));
    expect(info, contains('Direct BLE (universal_ble)'));
    expect(info, contains('UNVERIFIED'));
  });

  test('close() is idempotent', () async {
    await writer.write(const E4Sample(signal: E4Signal.hr, timestamp: 1.0, values: [70.0]));
    await writer.close();
    await writer.close(); // must not throw
  });

  test('a write failure (e.g. missing session directory) propagates, not swallowed', () async {
    final brokenWriter = E4SessionWriter(Directory('${tempDir.path}/does_not_exist'));
    await brokenWriter.write(const E4Sample(signal: E4Signal.hr, timestamp: 1.0, values: [70.0]));
    await expectLater(brokenWriter.close(), throwsA(isA<Object>()));
  });
}
