import 'package:flutter/material.dart' hide ConnectionState;

import '../../bloc/connection_bloc.dart';
import '../theme/e4_colors.dart';

/// Icon/label/colors for a [ConnectionStatus], per the design's `connMap`.
/// Public so other widgets (Recording card, Device tab) can render the same
/// icon+label without duplicating the color mapping.
class ConnectionSpec {
  const ConnectionSpec(this.icon, this.label, this.foreground, this.background);
  final IconData icon;
  final String label;
  final Color foreground;
  final Color background;
}

ConnectionSpec connectionSpecFor(ConnectionStatus status, {bool hasResults = false}) {
  switch (status) {
    case ConnectionStatus.discovering:
      return ConnectionSpec(
        Icons.bluetooth_searching,
        hasResults ? 'Devices found' : 'Scanning…',
        E4Colors.scanningFg,
        E4Colors.scanningBg,
      );
    case ConnectionStatus.connecting:
      return const ConnectionSpec(Icons.sync, 'Connecting…', E4Colors.connectingFg, E4Colors.connectingBg);
    case ConnectionStatus.connected:
      return const ConnectionSpec(
        Icons.bluetooth_connected,
        'Connected & streaming',
        E4Colors.connectedFg,
        E4Colors.connectedBg,
      );
    case ConnectionStatus.idle:
    case ConnectionStatus.error:
      return const ConnectionSpec(
        Icons.bluetooth_disabled,
        'Disconnected',
        E4Colors.disconnectedFg,
        E4Colors.disconnectedBg,
      );
  }
}

/// Icon+label pill reflecting [ConnectionStatus], colored per the design's
/// `connMap`. Used in the top bar (tap navigates to the Device tab) and in
/// the Device tab's own status card.
class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key, required this.status, this.hasResults = false, this.onTap, this.iconSize = 16});

  final ConnectionStatus status;
  final bool hasResults;
  final VoidCallback? onTap;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final spec = connectionSpecFor(status, hasResults: hasResults);
    return Material(
      color: spec.background,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: iconSize, color: spec.foreground),
              const SizedBox(width: 6),
              Text(
                spec.label,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: spec.foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
