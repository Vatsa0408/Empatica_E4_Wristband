import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/connection_bloc.dart';

/// Discover / connect / disconnect. BLE is the only transport (see
/// CLAUDE.md), so there is no transport-mode selector.
class DevicePanel extends StatelessWidget {
  const DevicePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ConnectionBloc, ConnectionState>(
      builder: (context, state) {
        final bloc = context.read<ConnectionBloc>();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Device', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: state.status == ConnectionStatus.discovering ? null : () => bloc.add(const DiscoverRequested()),
                      child: Text(state.status == ConnectionStatus.discovering ? 'Scanning...' : 'Scan'),
                    ),
                    const SizedBox(width: 8),
                    if (state.status == ConnectionStatus.connected)
                      OutlinedButton(onPressed: () => bloc.add(const DisconnectRequested()), child: const Text('Disconnect')),
                  ],
                ),
                const SizedBox(height: 8),
                if (state.status == ConnectionStatus.connected)
                  Text('Connected: ${state.deviceId}')
                else
                  ...state.devices.map(
                    (device) => ListTile(
                      title: Text(device.name),
                      subtitle: Text(device.id),
                      trailing: FilledButton(
                        onPressed: state.status == ConnectionStatus.connecting ? null : () => bloc.add(ConnectRequested(device.id)),
                        child: const Text('Connect'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
