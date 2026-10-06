import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/connection_bloc.dart';
import 'breakpoint.dart';
import 'theme/e4_colors.dart';
import 'widgets/connection_chip.dart';
import 'widgets/pill_widgets.dart';

/// Scan / connect / disconnect. Device rows show name + id only — the
/// design's 4-bar RSSI indicator needs signal-strength data `E4Device`
/// doesn't carry (adding it would mean touching the out-of-scope BLE
/// transport), so it's dropped rather than faked.
class DeviceTab extends StatelessWidget {
  const DeviceTab({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final breakpoint = breakpointFor(constraints.maxWidth);
        return BlocBuilder<ConnectionBloc, ConnectionState>(
          builder: (context, state) {
            final bloc = context.read<ConnectionBloc>();
            final hasResults = state.devices.isNotEmpty;
            final content = breakpoint == Breakpoint.compact
                ? _CompactDeviceList(state: state, bloc: bloc)
                : _GridDeviceList(state: state, bloc: bloc, columns: breakpoint == Breakpoint.medium ? 2 : 3);
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusCard(state: state, bloc: bloc),
                  const SizedBox(height: 16),
                  if (!hasResults && breakpoint != Breakpoint.compact) const Expanded(child: _EmptyState()) else Expanded(child: content),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, required this.bloc});

  final ConnectionState state;
  final ConnectionBloc bloc;

  @override
  Widget build(BuildContext context) {
    final spec = connectionSpecFor(state.status);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: E4Colors.surfaceDim, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(spec.icon, size: 22, color: spec.foreground),
              const SizedBox(width: 10),
              Text(spec.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          if (state.status == ConnectionStatus.connected && state.deviceId != null) ...[
            const SizedBox(height: 4),
            Text(state.deviceId!, style: const TextStyle(fontSize: 12, color: E4Colors.neutralText)),
          ],
          const SizedBox(height: 12),
          _actionFor(state, bloc),
        ],
      ),
    );
  }

  Widget _actionFor(ConnectionState state, ConnectionBloc bloc) {
    switch (state.status) {
      case ConnectionStatus.idle:
      case ConnectionStatus.error:
        return SizedBox(
          width: double.infinity,
          child: PillButton(
            label: 'Scan for devices',
            onPressed: () => bloc.add(const DiscoverRequested()),
            background: E4Colors.primary,
            foreground: Colors.white,
          ),
        );
      case ConnectionStatus.discovering:
        return const _StatusPill(label: 'Scanning…', background: E4Colors.segmentTrack, foreground: E4Colors.neutralText);
      case ConnectionStatus.connecting:
        return const _StatusPill(label: 'Connecting…', background: E4Colors.segmentTrack, foreground: E4Colors.primary);
      case ConnectionStatus.connected:
        return SizedBox(
          width: double.infinity,
          child: PillButton(
            label: 'Disconnect',
            onPressed: () => bloc.add(const DisconnectRequested()),
            background: E4Colors.cardOutline,
            foreground: E4Colors.neutralText,
            outlined: true,
          ),
        );
    }
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.background, required this.foreground});

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: foreground)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_searching, size: 40, color: E4Colors.emptyStateText),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Tap "Scan for devices" to discover nearby wristbands.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: E4Colors.emptyStateText),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.name, required this.id, required this.onTap});

  final String name;
  final String id;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: E4Colors.outline)),
          child: Row(
            children: [
              const Icon(Icons.watch, size: 20, color: E4Colors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(id, style: const TextStyle(fontSize: 11, color: E4Colors.mutedText)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20, color: E4Colors.mutedText),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactDeviceList extends StatelessWidget {
  const _CompactDeviceList({required this.state, required this.bloc});

  final ConnectionState state;
  final ConnectionBloc bloc;

  @override
  Widget build(BuildContext context) {
    if (state.devices.isEmpty) return const SizedBox.shrink();
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'NEARBY DEVICES',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: E4Colors.neutralText, letterSpacing: 0.6),
          ),
        ),
        for (final device in state.devices) ...[
          _DeviceRow(name: device.name, id: device.id, onTap: () => bloc.add(ConnectRequested(device.id))),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _GridDeviceList extends StatelessWidget {
  const _GridDeviceList({required this.state, required this.bloc, required this.columns});

  final ConnectionState state;
  final ConnectionBloc bloc;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: columns,
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      childAspectRatio: 3,
      children: [
        for (final device in state.devices)
          _DeviceRow(name: device.name, id: device.id, onTap: () => bloc.add(ConnectRequested(device.id))),
      ],
    );
  }
}
