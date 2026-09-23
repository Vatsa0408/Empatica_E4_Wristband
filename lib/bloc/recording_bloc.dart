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

class RecordingState extends Equatable {
  const RecordingState({
    this.mode = RecordingMode.manual,
    this.status = RecordingStatus.idle,
    this.sessionPath,
    this.startedAt,
    this.counts = const {},
    this.latest = const {},
    this.error,
  });

  final RecordingMode mode;
  final RecordingStatus status;
  final String? sessionPath;
  final DateTime? startedAt;
  final Map<E4Signal, int> counts;
  final Map<E4Signal, E4Sample> latest;
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
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [mode, status, sessionPath, startedAt, counts, latest, error];
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
    _counts[event.sample.signal] = (_counts[event.sample.signal] ?? 0) + 1;
    _latest[event.sample.signal] = event.sample;
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
    emit(state.copyWith(counts: Map.of(_counts), latest: Map.of(_latest)));
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
    emit(state.copyWith(status: RecordingStatus.idle, clearSessionPath: true, clearStartedAt: true));
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
