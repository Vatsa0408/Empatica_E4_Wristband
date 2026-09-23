import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:e4_integrator/bloc/connection_bloc.dart';
import 'package:e4_integrator/model/e4_sample.dart';
import 'package:e4_integrator/transport/e4_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockE4Transport extends Mock implements E4Transport {}

void main() {
  late MockE4Transport transport;
  late StreamController<bool> connectedController;

  setUp(() {
    transport = MockE4Transport();
    connectedController = StreamController<bool>.broadcast();
    when(() => transport.connected).thenAnswer((_) => connectedController.stream);
  });

  tearDown(() => connectedController.close());

  group('ConnectionBloc', () {
    blocTest<ConnectionBloc, ConnectionState>(
      'DiscoverRequested emits discovering then idle with the found devices',
      setUp: () => when(() => transport.discover()).thenAnswer(
        (_) async => const [E4Device(id: 'abc', name: 'Empatica E4')],
      ),
      build: () => ConnectionBloc(transport),
      act: (bloc) => bloc.add(const DiscoverRequested()),
      expect: () => const [
        ConnectionState(status: ConnectionStatus.discovering),
        ConnectionState(status: ConnectionStatus.idle, devices: [E4Device(id: 'abc', name: 'Empatica E4')]),
      ],
    );

    blocTest<ConnectionBloc, ConnectionState>(
      'a discover() failure surfaces as an error state, not a silent drop',
      setUp: () => when(() => transport.discover()).thenThrow(Exception('scan failed')),
      build: () => ConnectionBloc(transport),
      act: (bloc) => bloc.add(const DiscoverRequested()),
      expect: () => [
        const ConnectionState(status: ConnectionStatus.discovering),
        isA<ConnectionState>().having((s) => s.status, 'status', ConnectionStatus.error),
      ],
    );

    blocTest<ConnectionBloc, ConnectionState>(
      'ConnectRequested success sets status connected with the device id',
      setUp: () => when(() => transport.connect(any())).thenAnswer((_) async {}),
      build: () => ConnectionBloc(transport),
      act: (bloc) => bloc.add(const ConnectRequested('abc')),
      expect: () => const [
        ConnectionState(status: ConnectionStatus.connecting),
        ConnectionState(status: ConnectionStatus.connected, deviceId: 'abc'),
      ],
    );

    blocTest<ConnectionBloc, ConnectionState>(
      'a connect() failure surfaces as an error state',
      setUp: () => when(() => transport.connect(any())).thenThrow(Exception('boom')),
      build: () => ConnectionBloc(transport),
      act: (bloc) => bloc.add(const ConnectRequested('abc')),
      expect: () => [
        const ConnectionState(status: ConnectionStatus.connecting),
        isA<ConnectionState>().having((s) => s.status, 'status', ConnectionStatus.error),
      ],
    );

    blocTest<ConnectionBloc, ConnectionState>(
      'DisconnectRequested clears status and device id',
      setUp: () => when(() => transport.disconnect()).thenAnswer((_) async {}),
      build: () => ConnectionBloc(transport),
      seed: () => const ConnectionState(status: ConnectionStatus.connected, deviceId: 'abc'),
      act: (bloc) => bloc.add(const DisconnectRequested()),
      expect: () => const [ConnectionState(status: ConnectionStatus.idle)],
    );

    blocTest<ConnectionBloc, ConnectionState>(
      'an unsolicited transport disconnect resets a connected state to idle',
      build: () => ConnectionBloc(transport),
      seed: () => const ConnectionState(status: ConnectionStatus.connected, deviceId: 'abc'),
      act: (bloc) => connectedController.add(false),
      expect: () => const [ConnectionState(status: ConnectionStatus.idle)],
    );
  });
}
