import 'dart:async';
import 'dart:io';

import '../model/e4_sample.dart';

/// Physical sample rate (Hz) for each positional (rate-based) signal, per
/// Empatica's own export layout. IBI/tags/battery are event-based instead —
/// see the writer methods below.
const Map<E4Signal, double> _rateHz = {
  E4Signal.acc: 32.0,
  E4Signal.bvp: 64.0,
  E4Signal.eda: 4.0,
  E4Signal.hr: 1.0,
  E4Signal.temp: 4.0,
};

const Map<E4Signal, String> _fileNames = {
  E4Signal.acc: 'ACC.csv',
  E4Signal.bvp: 'BVP.csv',
  E4Signal.eda: 'EDA.csv',
  E4Signal.hr: 'HR.csv',
  E4Signal.temp: 'TEMP.csv',
  E4Signal.ibi: 'IBI.csv',
  E4Signal.tag: 'tags.csv',
  E4Signal.battery: 'BAT.csv',
};

class _RateSignalFile {
  _RateSignalFile(this.sink, this.t0);
  final IOSink sink;
  final double t0;
  int rowsWritten = 0;
}

class _EventSignalFile {
  _EventSignalFile(this.sink, this.t0);
  final IOSink sink;
  final double t0;
}

/// Writes E4 samples into Empatica's own session export layout (one CSV per
/// signal). t0 is always the first-received-sample timestamp *per signal*,
/// never wall-clock, and rows are positional: row n means `t0 + n/rate`. A
/// dropped packet is gap-padded (and logged to a sidecar file) rather than
/// silently shifting every later row.
class E4SessionWriter {
  E4SessionWriter(this.sessionDir);

  final Directory sessionDir;

  final Map<E4Signal, _RateSignalFile> _rateFiles = {};
  final Map<E4Signal, _EventSignalFile> _eventFiles = {};
  IOSink? _dropLog;
  Timer? _flushTimer;
  bool _closed = false;

  /// Writes one sample. Opens the signal's file (and writes its header)
  /// lazily on that signal's first sample. I/O failures propagate to the
  /// caller — never swallowed, per CLAUDE.md.
  Future<void> write(E4Sample sample) async {
    _flushTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => flush());

    final rate = _rateHz[sample.signal];
    if (rate != null) {
      await _writeRateSample(sample, rate);
      return;
    }
    switch (sample.signal) {
      case E4Signal.ibi:
        await _writeEventSample(E4Signal.ibi, 'IBI', sample);
      case E4Signal.battery:
        await _writeEventSample(E4Signal.battery, 'BAT', sample);
      case E4Signal.tag:
        await _writeTag(sample);
      default:
        throw StateError('Unhandled signal ${sample.signal}');
    }
  }

  Future<void> _writeRateSample(E4Sample sample, double rate) async {
    var file = _rateFiles[sample.signal];
    if (file == null) {
      final sink = _openSink(sample.signal);
      sink.writeln(sample.timestamp.toStringAsFixed(6));
      sink.writeln(
        sample.signal == E4Signal.acc
            ? '${rate.toStringAsFixed(6)}, ${rate.toStringAsFixed(6)}, ${rate.toStringAsFixed(6)}'
            : rate.toStringAsFixed(6),
      );
      file = _RateSignalFile(sink, sample.timestamp);
      _rateFiles[sample.signal] = file;
    }

    final expected = ((sample.timestamp - file.t0) * rate).round();
    if (expected < file.rowsWritten) {
      await _logDrop('${_fileNames[sample.signal]}: out-of-order sample at row $expected (already wrote ${file.rowsWritten} rows) — dropped');
      return;
    }
    for (var row = file.rowsWritten; row < expected; row++) {
      file.sink.writeln(sample.signal == E4Signal.acc ? ',,' : '');
      await _logDrop('${_fileNames[sample.signal]}: gap-padded row $row');
    }
    file.sink.writeln(sample.values.map((v) => v.toStringAsFixed(6)).join(','));
    file.rowsWritten = expected + 1;
  }

  Future<void> _writeEventSample(E4Signal signal, String label, E4Sample sample) async {
    var file = _eventFiles[signal];
    if (file == null) {
      final sink = _openSink(signal);
      sink.writeln('${sample.timestamp.toStringAsFixed(6)}, $label');
      file = _EventSignalFile(sink, sample.timestamp);
      _eventFiles[signal] = file;
    }
    final elapsed = sample.timestamp - file.t0;
    file.sink.writeln('${elapsed.toStringAsFixed(6)},${sample.values.single.toStringAsFixed(6)}');
  }

  Future<void> _writeTag(E4Sample sample) async {
    var file = _eventFiles[E4Signal.tag];
    if (file == null) {
      file = _EventSignalFile(_openSink(E4Signal.tag), sample.timestamp);
      _eventFiles[E4Signal.tag] = file;
    }
    file.sink.writeln(sample.timestamp.toStringAsFixed(6));
  }

  IOSink _openSink(E4Signal signal) => File('${sessionDir.path}/${_fileNames[signal]}').openWrite();

  Future<void> _logDrop(String message) async {
    _dropLog ??= File('${sessionDir.path}/e4_integrator_log.txt').openWrite(mode: FileMode.append);
    _dropLog!.writeln('${DateTime.now().toUtc().toIso8601String()} $message');
  }

  /// Writes the (static) explainer file Empatica ships in its own export
  /// ZIP, plus a header documenting which streams are self-derived/unverified.
  Future<void> writeInfo({required String deviceId, required String transportDescription}) async {
    final file = File('${sessionDir.path}/info.txt');
    await file.writeAsString('''
Empatica E4 session recorded by e4_integrator.

Device: $deviceId
Transport: $transportDescription
Recorded (UTC): ${DateTime.now().toUtc().toIso8601String()}

Caveats (see project CLAUDE.md for full provenance):
- BVP.csv is a filtered approximation of Empatica's proprietary BVP
  algorithm, reverse-engineered from a third-party project, NOT a
  byte-identical decode. UNVERIFIED against a real Empatica export.
- HR.csv and IBI.csv are derived OFFLINE from BVP in this app via naive peak
  detection, not computed on-device by the E4 the way Empatica's own exports
  are.
- BAT.csv is not part of Empatica's export format; it is a documented
  extension, written IBI-style (`<t0>, BAT` header, then `<elapsed>,<0..1>`
  rows). The underlying Battery Service (0x180F) read is itself unconfirmed
  on this hardware.
- tags.csv has no known BLE path (the E4's physical button) and is expected
  to stay empty.
''');
  }

  Future<void> flush() async {
    for (final file in _rateFiles.values) {
      await file.sink.flush();
    }
    for (final file in _eventFiles.values) {
      await file.sink.flush();
    }
    await _dropLog?.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    for (final file in _rateFiles.values) {
      await file.sink.flush();
      await file.sink.close();
    }
    for (final file in _eventFiles.values) {
      await file.sink.flush();
      await file.sink.close();
    }
    await _dropLog?.flush();
    await _dropLog?.close();
  }
}
