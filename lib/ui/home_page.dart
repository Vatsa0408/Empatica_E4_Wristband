import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/connection_bloc.dart';
import 'breakpoint.dart';
import 'dashboard_tab.dart';
import 'device_tab.dart';
import 'history_tab.dart';
import 'widgets/connection_chip.dart';

enum _Tab { dashboard, device, history }

const _destinations = [
  (tab: _Tab.dashboard, icon: Icons.space_dashboard, label: 'Dashboard'),
  (tab: _Tab.device, icon: Icons.watch, label: 'Device'),
  (tab: _Tab.history, icon: Icons.history, label: 'History'),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Tab _tab = _Tab.dashboard;

  static const _tabs = [DashboardTab(), DeviceTab(), HistoryTab()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Empatica Data Collector'),
        actions: [
          BlocBuilder<ConnectionBloc, ConnectionState>(
            builder: (context, state) => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: ConnectionChip(
                status: state.status,
                hasResults: state.devices.isNotEmpty,
                onTap: () => setState(() => _tab = _Tab.device),
              ),
            ),
          ),
        ],
      ),
      body: BlocListener<ConnectionBloc, ConnectionState>(
        listenWhen: (previous, current) => current.status == ConnectionStatus.error && current.error != previous.error,
        listener: (context, state) {
          final error = state.error;
          if (error != null) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
          }
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final breakpoint = breakpointFor(constraints.maxWidth);
            final content = _tabs[_Tab.values.indexOf(_tab)];

            if (breakpoint == Breakpoint.compact) {
              return Column(
                children: [
                  Expanded(child: content),
                  NavigationBar(
                    selectedIndex: _Tab.values.indexOf(_tab),
                    onDestinationSelected: (index) => setState(() => _tab = _destinations[index].tab),
                    destinations: [
                      for (final d in _destinations) NavigationDestination(icon: Icon(d.icon), label: d.label),
                    ],
                  ),
                ],
              );
            }

            return Row(
              children: [
                NavigationRail(
                  // `extended: true` shows labels itself; `labelType: none`
                  // is required alongside it and gives an icon-only rail on
                  // medium width, matching the design's unlabeled tablet rail.
                  extended: breakpoint == Breakpoint.expanded,
                  labelType: NavigationRailLabelType.none,
                  selectedIndex: _Tab.values.indexOf(_tab),
                  onDestinationSelected: (index) => setState(() => _tab = _destinations[index].tab),
                  destinations: [
                    for (final d in _destinations)
                      NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            );
          },
        ),
      ),
    );
  }
}
