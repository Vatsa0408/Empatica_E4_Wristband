import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../model/e4_sample.dart';
import '../transport/e4_transport.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class ConnectionEvent extends Equatable {
  const ConnectionEvent();

  @override
  List<Object?> get props => [];
}

class DiscoverRequested extends ConnectionEvent {
  const DiscoverRequested();
}

class ConnectRequested extends ConnectionEvent {
  const ConnectRequested(this.deviceId);

  final String deviceId;

  @override
  List<Object?> get props => [deviceId];
}

class DisconnectRequested extends ConnectionEvent {
  const DisconnectRequested();
}

/// Internal: raised from the transport's `connected` stream.
class _TransportConnectionChanged extends ConnectionEvent {
  const _TransportConnectionChanged(this.isConnected);

  final bool isConnected;

  @override
  List<Object?> get props => [isConnected];
}

/// Internal: raised from stream errors on the transport's `connected` stream.
class _TransportFailed extends ConnectionEvent {
  const _TransportFailed(this.error);

  final Object error;

  @override
  List<Object?> get props => [error];
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum ConnectionStatus { idle, discovering, connecting, connected, error }

class ConnectionState extends Equatable {
  const ConnectionState({
    this.status = ConnectionStatus.idle,
    this.devices = const [],
    this.deviceId,
    this.error,
  });

  final ConnectionStatus status;
  final List<E4Device> devices;
  final String? deviceId;
  final String? error;

  ConnectionState copyWith({
    ConnectionStatus? status,
    List<E4Device>? devices,
    String? deviceId,
    bool clearDeviceId = false,
    String? error,
    bool clearError = false,
  }) {
    return ConnectionState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      deviceId: clearDeviceId ? null : (deviceId ?? this.deviceId),
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [status, devices, deviceId, error];
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Owns the [E4Transport] connection lifecycle: discovery, connect,
/// disconnect and surfacing transport errors. Recording (§RecordingBloc)
/// listens to this bloc rather than the transport directly.
class ConnectionBloc extends Bloc<ConnectionEvent, ConnectionState> {
  ConnectionBloc(this._transport) : super(const ConnectionState()) {
    on<DiscoverRequested>(_onDiscoverRequested);
    on<ConnectRequested>(_onConnectRequested);
    on<DisconnectRequested>(_onDisconnectRequested);
    on<_TransportConnectionChanged>(_onTransportConnectionChanged);
    on<_TransportFailed>(_onTransportFailed);

    _connectionSubscription = _transport.connected.listen(
      (isConnected) => add(_TransportConnectionChanged(isConnected)),
      onError: (Object error) => add(_TransportFailed(error)),
    );
  }

  final E4Transport _transport;
  StreamSubscription<bool>? _connectionSubscription;

  E4Transport get transport => _transport;

  Future<void> _onDiscoverRequested(
    DiscoverRequested event,
    Emitter<ConnectionState> emit,
  ) async {
    emit(
      state.copyWith(status: ConnectionStatus.discovering, clearError: true),
    );
    try {
      final devices = await _transport.discover();
      emit(state.copyWith(status: ConnectionStatus.idle, devices: devices));
    } on Object catch (error) {
      emit(
        state.copyWith(status: ConnectionStatus.error, error: error.toString()),
      );
    }
  }

  Future<void> _onConnectRequested(
    ConnectRequested event,
    Emitter<ConnectionState> emit,
  ) async {
    emit(state.copyWith(status: ConnectionStatus.connecting, clearError: true));
    try {
      await _transport.connect(event.deviceId);
      emit(
        state.copyWith(
          status: ConnectionStatus.connected,
          deviceId: event.deviceId,
        ),
      );
    } on Object catch (error) {
      emit(
        state.copyWith(status: ConnectionStatus.error, error: error.toString()),
      );
    }
  }

  Future<void> _onDisconnectRequested(
    DisconnectRequested event,
    Emitter<ConnectionState> emit,
  ) async {
    try {
      await _transport.disconnect();
    } on Object catch (error) {
      emit(
        state.copyWith(status: ConnectionStatus.error, error: error.toString()),
      );
      return;
    }
    emit(state.copyWith(status: ConnectionStatus.idle, clearDeviceId: true));
  }

  void _onTransportConnectionChanged(
    _TransportConnectionChanged event,
    Emitter<ConnectionState> emit,
  ) {
    if (!event.isConnected && state.status == ConnectionStatus.connected) {
      emit(state.copyWith(status: ConnectionStatus.idle, clearDeviceId: true));
    }
  }

  void _onTransportFailed(
    _TransportFailed event,
    Emitter<ConnectionState> emit,
  ) {
    emit(
      state.copyWith(
        status: ConnectionStatus.error,
        error: event.error.toString(),
      ),
    );
  }

  @override
  Future<void> close() async {
    await _connectionSubscription?.cancel();
    return super.close();
  }
}
