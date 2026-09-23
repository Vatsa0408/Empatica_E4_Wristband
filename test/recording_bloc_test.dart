import 'dart:async';
import 'dart:io';

import 'package:e4_integrator/bloc/connection_bloc.dart';
import 'package:e4_integrator/bloc/recording_bloc.dart';
import 'package:e4_integrator/model/e4_sample.dart';
import 'package:e4_integrator/storage/session_paths.dart';
import 'package:e4_integrator/transport/e4_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockE4Transport extends Mock implements E4Transport {}

/// Avoids path_provider (no plugin bindings in a bare unit test) by pointing
/// every session at a subdirectory of a real temp directory.
class _FixedSessionPaths implements SessionPaths {
  _FixedSessionPaths(this.root);
  final Directory root;

  @override
  Future<Directory> sessionRoot() async => root;

  @override
  Future<Directory> newSessionDirectory(String deviceId, {DateTime? startedAt}) async {
    final dir = Directory('${root.path}/${deviceId}_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    return dir;
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late MockE4Transport transport;
  late StreamController<bool> connectedController;
  late StreamController<E4Sample> samplesController;
  late Directory tempDir;

  setUp(() async {
    transport = MockE4Transport();
    connectedController = StreamController<bool>.broadcast();
    samplesController = StreamController<E4Sample>.broadcast();
    when(() => transport.connected).thenAnswer((_) => connectedController.stream);
    when(() => transport.samples).thenAnswer((_) => samplesController.stream);
    when(() => transport.connect(any())).thenAnswer((_) async {});
    tempDir = await Directory.systemTemp.createTemp('recording_bloc_test_');
  });

  tearDown(() async {
    await connectedController.close();
    await samplesController.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // `ConnectionBloc` only reacts to the transport's `connected` stream to
  // detect a *spontaneous* drop while already connected — becoming connected
  // in the first place goes through `ConnectRequested`. Drive both bloc and
  // fake transport the same way the app does.
  ({RecordingBloc recording, ConnectionBloc connection}) build() {
    final connectionBloc = ConnectionBloc(transport);
    final recordingBloc = RecordingBloc(transport, connectionBloc, sessionPaths: _FixedSessionPaths(tempDir));
    return (recording: recordingBloc, connection: connectionBloc);
  }

  Future<void> connect(ConnectionBloc connectionBloc, {String deviceId = 'device-1'}) async {
    connectionBloc.add(ConnectRequested(deviceId));
    await _settle();
  }

  test('continuous mode: connecting opens a session, disconnecting closes it', () async {
    final blocs = build();
    final bloc = blocs.recording;
    bloc.add(const RecordingModeChanged(RecordingMode.continuous));
    await _settle();

    await connect(blocs.connection);
    expect(bloc.state.status, RecordingStatus.recording);
    expect(bloc.state.sessionPath, isNotNull);
    expect(await File('${bloc.state.sessionPath}/info.txt').exists(), isTrue);

    connectedController.add(false); // spontaneous drop, detected via the transport stream
    await _settle();
    expect(bloc.state.status, RecordingStatus.idle);
    expect(bloc.state.sessionPath, isNull);

    await bloc.close();
    await blocs.connection.close();
  });

  test('manual mode: connecting stays idle; Start/Stop drive recording explicitly', () async {
    final blocs = build();
    final bloc = blocs.recording;
    await connect(blocs.connection);
    expect(bloc.state.status, RecordingStatus.idle);

    bloc.add(const StartRequested());
    await _settle();
    expect(bloc.state.status, RecordingStatus.recording);

    bloc.add(const StopRequested());
    await _settle();
    expect(bloc.state.status, RecordingStatus.idle);
    expect(bloc.state.sessionPath, isNull);

    await bloc.close();
    await blocs.connection.close();
  });

  test('StartRequested without a connection surfaces an error, never crashes', () async {
    final bloc = build().recording;
    bloc.add(const StartRequested());
    await _settle();
    expect(bloc.state.status, RecordingStatus.error);
    expect(bloc.state.error, isNotNull);
    await bloc.close();
  });

  test('a disconnect while manually recording closes the session and surfaces an error', () async {
    final blocs = build();
    final bloc = blocs.recording;
    await connect(blocs.connection);
    bloc.add(const StartRequested());
    await _settle();
    expect(bloc.state.status, RecordingStatus.recording);

    connectedController.add(false);
    await _settle();
    expect(bloc.state.status, RecordingStatus.error);
    expect(bloc.state.error, isNotNull);
    expect(bloc.state.sessionPath, isNull);

    await bloc.close();
    await blocs.connection.close();
  });

  test('samples arriving while idle update counts/latest but write nothing to disk', () async {
    final blocs = build();
    final bloc = blocs.recording;
    await connect(blocs.connection);
    expect(bloc.state.status, RecordingStatus.idle); // manual mode by default

    samplesController.add(const E4Sample(signal: E4Signal.hr, timestamp: 1.0, values: [70.0]));
    await Future<void>.delayed(const Duration(milliseconds: 300)); // let the 250ms tick fire
    expect(bloc.state.counts[E4Signal.hr], 1);
    expect(bloc.state.latest[E4Signal.hr]?.values, [70.0]);
    expect(bloc.state.sessionPath, isNull);

    await bloc.close();
    await blocs.connection.close();
  });

  test('a mode change while recording closes the old session first', () async {
    final blocs = build();
    final bloc = blocs.recording;
    await connect(blocs.connection);
    bloc.add(const StartRequested());
    await _settle();
    expect(bloc.state.sessionPath, isNotNull);

    // Switching mode does not silently keep the old writer open, nor does it
    // auto-resume a new session on its own — it only closes the current one.
    bloc.add(const RecordingModeChanged(RecordingMode.continuous));
    await _settle();
    expect(bloc.state.mode, RecordingMode.continuous);
    expect(bloc.state.status, RecordingStatus.idle);
    expect(bloc.state.sessionPath, isNull);

    await bloc.close();
    await blocs.connection.close();
  });
}
