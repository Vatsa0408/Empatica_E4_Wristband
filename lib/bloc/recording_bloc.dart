import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../model/e4_sample.dart';
import '../storage/e4_session_writer.dart';
import '../storage/session_paths.dart';
import '../transport/e4_transport.dart';
import 'connection_bloc.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class RecordingEvent extends Equatable {
  const RecordingEvent();

  @override
  List<Object?> get props => [];
}

class RecordingModeChanged extends RecordingEvent {
  const RecordingModeChanged(this.mode);

  final RecordingMode mode;

  @override
  List<Object?> get props => [mode];
}

class StartRequested extends RecordingEvent {
  const StartRequested();
}

class StopRequested extends RecordingEvent {
  const StopRequested();
}

/// Marks a past session (identified by its on-disk folder) as exported. The
/// data is already on disk continuously as it's recorded (see
/// `E4SessionWriter`); this only flips a UI-facing flag in [RecordingState].
class ExportRequested extends RecordingEvent {
  const ExportRequested(this.sessionPath);

  final String sessionPath;

  @override
  List<Object?> get props => [sessionPath];
}

/// Internal: raised from the transport's `samples` stream.
class _SampleArrived extends RecordingEvent {
  const _SampleArrived(this.sample);

  final E4Sample sample;

  @override
  List<Object?> get props => [sample];
}

/// Internal: raised from [ConnectionBloc]'s state stream.
class _ConnectionChanged extends RecordingEvent {
  const _ConnectionChanged(this.isConnected, this.deviceId);

  final bool isConnected;
  final String? deviceId;

  @override
  List<Object?> get props => [isConnected, deviceId];
}

/// Internal: raised on a session-writer I/O failure.
class _WriteFailed extends RecordingEvent {
  const _WriteFailed(this.error);

  final Object error;

  @override
  List<Object?> get props => [error];
}

/// Internal: 250ms UI-throttle tick. Every sample is still written to disk
/// immediately in [_onSampleArrived]; only the *state emission* (and
/// therefore widget rebuilds) is throttled.
class _Tick extends RecordingEvent {
  const _Tick();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum RecordingMode { continuous, manual }

enum RecordingStatus { idle, recording, error }

/// A finished recording session, kept in memory only (no new persistence
/// layer — the CSVs are already on disk; this just drives the History tab).
class CompletedSession extends Equatable {
  const CompletedSession({
    required this.startedAt,
    required this.durationSec,
    required this.counts,
    required this.sessionPath,
    this.exported = false,
  });

  final DateTime startedAt;
  final double durationSec;
  final Map<E4Signal, int> counts;
  final String sessionPath;
  final bool exported;

  CompletedSession copyWith({bool? exported}) => CompletedSession(
    startedAt: startedAt,
    durationSec: durationSec,
    counts: counts,
    sessionPath: sessionPath,
    exported: exported ?? this.exported,
  );

  @override
  List<Object?> get props => [startedAt, durationSec, counts, sessionPath, exported];
}

class RecordingState extends Equatable {
  const RecordingState({
    this.mode = RecordingMode.manual,
    this.status = RecordingStatus.idle,
    this.sessionPath,
    this.startedAt,
    this.counts = const {},
    this.latest = const {},
    this.bvp = const [],
    this.accX = const [],
    this.accY = const [],
    this.accZ = const [],
    this.hr = const [],
    this.eda = const [],
    this.temp = const [],
    this.ibi = const [],
    this.history = const [],
    this.error,
  });

  final RecordingMode mode;
  final RecordingStatus status;
  final String? sessionPath;
  final DateTime? startedAt;
  final Map<E4Signal, int> counts;
  final Map<E4Signal, E4Sample> latest;

  /// Rolling buffers of recent raw values, for the dashboard's live charts.
  /// Filled from every arriving sample regardless of recording status (see
  /// [RecordingBloc] docs), capped at a fixed length per signal.
  final List<double> bvp;
  final List<double> accX;
  final List<double> accY;
  final List<double> accZ;
  final List<double> hr;
  final List<double> eda;
  final List<double> temp;
  final List<double> ibi;

  /// Past recording sessions, most recent first.
  final List<CompletedSession> history;

  final String? error;

  RecordingState copyWith({
    RecordingMode? mode,
    RecordingStatus? status,
    String? sessionPath,
    bool clearSessionPath = false,
    DateTime? startedAt,
    bool clearStartedAt = false,
    Map<E4Signal, int>? counts,
    Map<E4Signal, E4Sample>? latest,
    List<double>? bvp,
    List<double>? accX,
    List<double>? accY,
    List<double>? accZ,
    List<double>? hr,
    List<double>? eda,
    List<double>? temp,
    List<double>? ibi,
    List<CompletedSession>? history,
    String? error,
    bool clearError = false,
  }) {
    return RecordingState(
      mode: mode ?? this.mode,
      status: status ?? this.status,
      sessionPath: clearSessionPath ? null : (sessionPath ?? this.sessionPath),
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      counts: counts ?? this.counts,
      latest: latest ?? this.latest,
      bvp: bvp ?? this.bvp,
      accX: accX ?? this.accX,
      accY: accY ?? this.accY,
      accZ: accZ ?? this.accZ,
      hr: hr ?? this.hr,
      eda: eda ?? this.eda,
      temp: temp ?? this.temp,
      ibi: ibi ?? this.ibi,
      history: history ?? this.history,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [
    mode,
    status,
    sessionPath,
    startedAt,
    counts,
    latest,
    bvp,
    accX,
    accY,
    accZ,
    hr,
    eda,
    temp,
    ibi,
    history,
    error,
  ];
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Owns the [E4SessionWriter] lifecycle and both recording modes:
/// - [RecordingMode.continuous]: a session opens on connect and closes on
///   disconnect, automatically.
/// - [RecordingMode.manual]: sessions open/close only on [StartRequested] /
///   [StopRequested]; a mid-recording disconnect still closes the session
///   (never leaves a half-written one) and surfaces an error.
///
/// Every sample is written to disk as it arrives regardless of mode — a
/// sample arriving while idle only updates the live counts/latest-value
/// table, nothing is written until recording starts.
class RecordingBloc extends Bloc<RecordingEvent, RecordingState> {
  RecordingBloc(this._transport, ConnectionBloc connectionBloc, {SessionPaths sessionPaths = const SessionPaths()})
    // The field is private and the ctor param is public on purpose
    // (`sessionPaths:` is part of the test seam), so they can't share a name.
    // ignore: prefer_initializing_formals
    : _sessionPaths = sessionPaths,
      super(const RecordingState()) {
    on<RecordingModeChanged>(_onModeChanged);
    on<StartRequested>(_onStartRequested);
    on<StopRequested>(_onStopRequested);
    on<ExportRequested>(_onExportRequested);
    on<_SampleArrived>(_onSampleArrived);
    on<_ConnectionChanged>(_onConnectionChanged);
    on<_WriteFailed>(_onWriteFailed);
    on<_Tick>(_onTick);

    _sampleSubscription = _transport.samples.listen(
      (sample) => add(_SampleArrived(sample)),
      onError: (Object error) => add(_WriteFailed(error)),
    );
    _connectionSubscription = connectionBloc.stream.listen(
      (connectionState) => add(
        _ConnectionChanged(connectionState.status == ConnectionStatus.connected, connectionState.deviceId),
      ),
    );
    _throttle = Timer.periodic(const Duration(milliseconds: 250), (_) => add(const _Tick()));
  }

  final E4Transport _transport;
  final SessionPaths _sessionPaths;

  StreamSubscription<E4Sample>? _sampleSubscription;
  StreamSubscription<ConnectionState>? _connectionSubscription;
  Timer? _throttle;

  E4SessionWriter? _writer;
  String? _connectedDeviceId;
  bool _dirty = false;
  Map<E4Signal, int> _counts = {};
  Map<E4Signal, E4Sample> _latest = {};
  List<CompletedSession> _history = [];

  // Rolling chart buffers — filled from every arriving sample regardless of
  // recording status, capped at a fixed length per signal (see
  // `RecordingState.bvp` etc. docs).
  final List<double> _bvp = [];
  final List<double> _accX = [];
  final List<double> _accY = [];
  final List<double> _accZ = [];
  final List<double> _hr = [];
  final List<double> _eda = [];
  final List<double> _temp = [];
  final List<double> _ibi = [];

  static const _bvpMax = 60;
  static const _accMax = 60;
  static const _trendMax = 40;
  static const _ibiMax = 20;

  void _pushBuffer(List<double> buffer, double value, int max) {
    buffer.add(value);
    if (buffer.length > max) buffer.removeAt(0);
  }

  Future<void> _onModeChanged(RecordingModeChanged event, Emitter<RecordingState> emit) async {
    if (_writer != null) {
      await _stopSession(emit);
    }
    emit(state.copyWith(mode: event.mode));
  }

  Future<void> _onStartRequested(StartRequested event, Emitter<RecordingState> emit) async {
    if (_writer != null) return;
    final deviceId = _connectedDeviceId;
    if (deviceId == null) {
      emit(state.copyWith(status: RecordingStatus.error, error: 'Cannot start recording: not connected'));
      return;
    }
    await _startSession(deviceId, emit);
  }

  Future<void> _onStopRequested(StopRequested event, Emitter<RecordingState> emit) async {
    await _stopSession(emit);
  }

  Future<void> _onSampleArrived(_SampleArrived event, Emitter<RecordingState> emit) async {
    final sample = event.sample;
    _counts[sample.signal] = (_counts[sample.signal] ?? 0) + 1;
    _latest[sample.signal] = sample;
    switch (sample.signal) {
      case E4Signal.bvp:
        _pushBuffer(_bvp, sample.values.single, _bvpMax);
      case E4Signal.acc:
        _pushBuffer(_accX, sample.values[0], _accMax);
        _pushBuffer(_accY, sample.values[1], _accMax);
        _pushBuffer(_accZ, sample.values[2], _accMax);
      case E4Signal.hr:
        _pushBuffer(_hr, sample.values.single, _trendMax);
      case E4Signal.eda:
        _pushBuffer(_eda, sample.values.single, _trendMax);
      case E4Signal.temp:
        _pushBuffer(_temp, sample.values.single, _trendMax);
      case E4Signal.ibi:
        _pushBuffer(_ibi, sample.values.single, _ibiMax);
      case E4Signal.tag:
      case E4Signal.battery:
        break;
    }
    _dirty = true;

    final writer = _writer;
    if (writer == null) return;
    try {
      await writer.write(event.sample);
    } on Object catch (error) {
      add(_WriteFailed(error));
    }
  }

  Future<void> _onConnectionChanged(_ConnectionChanged event, Emitter<RecordingState> emit) async {
    _connectedDeviceId = event.isConnected ? event.deviceId : null;

    if (event.isConnected) {
      if (state.mode == RecordingMode.continuous && event.deviceId != null) {
        await _startSession(event.deviceId!, emit);
      }
      return;
    }

    if (_writer != null) {
      final wasManual = state.mode == RecordingMode.manual;
      await _stopSession(emit);
      if (wasManual) {
        emit(state.copyWith(status: RecordingStatus.error, error: 'Device disconnected while recording; session closed'));
      }
    }
  }

  void _onWriteFailed(_WriteFailed event, Emitter<RecordingState> emit) {
    emit(state.copyWith(status: RecordingStatus.error, error: event.error.toString()));
  }

  void _onTick(_Tick event, Emitter<RecordingState> emit) {
    if (!_dirty) return;
    _dirty = false;
    emit(
      state.copyWith(
        counts: Map.of(_counts),
        latest: Map.of(_latest),
        bvp: List.of(_bvp),
        accX: List.of(_accX),
        accY: List.of(_accY),
        accZ: List.of(_accZ),
        hr: List.of(_hr),
        eda: List.of(_eda),
        temp: List.of(_temp),
        ibi: List.of(_ibi),
      ),
    );
  }

  void _onExportRequested(ExportRequested event, Emitter<RecordingState> emit) {
    _history = [
      for (final session in _history)
        session.sessionPath == event.sessionPath ? session.copyWith(exported: true) : session,
    ];
    emit(state.copyWith(history: List.of(_history)));
  }

  Future<void> _startSession(String deviceId, Emitter<RecordingState> emit) async {
    try {
      final dir = await _sessionPaths.newSessionDirectory(deviceId);
      final writer = E4SessionWriter(dir);
      await writer.writeInfo(
        deviceId: deviceId,
        transportDescription: 'Direct BLE (universal_ble), reverse-engineered E4 GATT characteristics — see CLAUDE.md',
      );
      _writer = writer;
      _counts = {};
      _latest = {};
      emit(
        state.copyWith(
          status: RecordingStatus.recording,
          sessionPath: dir.path,
          startedAt: DateTime.now(),
          counts: const {},
          latest: const {},
          clearError: true,
        ),
      );
    } on Object catch (error) {
      emit(state.copyWith(status: RecordingStatus.error, error: error.toString()));
    }
  }

  Future<void> _stopSession(Emitter<RecordingState> emit) async {
    final writer = _writer;
    _writer = null;
    if (writer == null) {
      emit(state.copyWith(status: RecordingStatus.idle));
      return;
    }
    try {
      await writer.close();
    } on Object catch (error) {
      emit(state.copyWith(status: RecordingStatus.error, error: error.toString()));
      return;
    }
    final startedAt = state.startedAt;
    final sessionPath = state.sessionPath;
    if (startedAt != null && sessionPath != null) {
      _history = [
        CompletedSession(
          startedAt: startedAt,
          durationSec: DateTime.now().difference(startedAt).inMilliseconds / 1000,
          counts: Map.of(_counts),
          sessionPath: sessionPath,
        ),
        ..._history,
      ];
    }
    emit(
      state.copyWith(
        status: RecordingStatus.idle,
        clearSessionPath: true,
        clearStartedAt: true,
        history: List.of(_history),
      ),
    );
  }

  @override
  Future<void> close() async {
    _throttle?.cancel();
    await _sampleSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _writer?.close();
    return super.close();
  }
}
