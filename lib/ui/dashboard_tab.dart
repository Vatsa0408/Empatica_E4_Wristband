import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/connection_bloc.dart';
import '../bloc/recording_bloc.dart';
import '../model/e4_sample.dart';
import 'breakpoint.dart';
import 'signal_ranges.dart';
import 'theme/e4_colors.dart';
import 'widgets/dashboard_cards.dart';
import 'widgets/signal_chart.dart';

/// Recording controls, then the raw BVP/ACC waveform cards (full width), then
/// a responsive grid of the derived trend cards (HR/EDA/TEMP/IBI) plus
/// Battery when available. One layout for every breakpoint — only the trend
/// card column count (1/2/3) changes.
class DashboardTab extends StatelessWidget {
  const DashboardTab({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = switch (breakpointFor(constraints.maxWidth)) {
          Breakpoint.compact => 1,
          Breakpoint.medium => 2,
          Breakpoint.expanded => 3,
        };
        return BlocBuilder<ConnectionBloc, ConnectionState>(
          builder: (context, connectionState) {
            return BlocBuilder<RecordingBloc, RecordingState>(
              builder: (context, recordingState) => _DashboardBody(
                connectionState: connectionState,
                recordingState: recordingState,
                columns: columns,
                availableWidth: constraints.maxWidth,
              ),
            );
          },
        );
      },
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({
    required this.connectionState,
    required this.recordingState,
    required this.columns,
    required this.availableWidth,
  });

  final ConnectionState connectionState;
  final RecordingState recordingState;
  final int columns;
  final double availableWidth;

  static const _gap = 16.0;
  static const _horizontalPadding = 16.0;

  String _last(List<double> values, int decimals) => values.isEmpty ? '--' : values.last.toStringAsFixed(decimals);

  RangeStatus _status(E4Signal signal, List<double> values) =>
      rangeStatusFor(signal, values.isEmpty ? null : values.last);

  String _caption(E4Signal signal) => signalRangeSpecs[signal]!.caption;

  @override
  Widget build(BuildContext context) {
    final recordingBloc = context.read<RecordingBloc>();
    final batteryPercent = recordingState.latest[E4Signal.battery]?.values.single.round();

    final trendCards = <Widget>[
      SignalCard(
        icon: Icons.monitor_heart,
        label: 'Heart rate',
        color: E4Colors.hr,
        tint: E4Colors.hrTint,
        valueLabel: _last(recordingState.hr, 0),
        unit: 'bpm',
        count: recordingState.counts[E4Signal.hr] ?? 0,
        series: [ChartSeries(recordingState.hr, E4Colors.hr, min: 45, max: 120)],
        rangeStatus: _status(E4Signal.hr, recordingState.hr),
        rangeCaption: _caption(E4Signal.hr),
        filled: true,
        chartHeight: 56,
      ),
      SignalCard(
        icon: Icons.bolt,
        label: 'Electrodermal activity',
        color: E4Colors.eda,
        tint: E4Colors.edaTint,
        valueLabel: _last(recordingState.eda, 2),
        unit: 'µS',
        count: recordingState.counts[E4Signal.eda] ?? 0,
        series: [ChartSeries(recordingState.eda, E4Colors.eda, min: 0, max: 1.8)],
        rangeStatus: _status(E4Signal.eda, recordingState.eda),
        rangeCaption: _caption(E4Signal.eda),
        filled: true,
        chartHeight: 56,
      ),
      SignalCard(
        icon: Icons.device_thermostat,
        label: 'Skin temperature',
        color: E4Colors.temp,
        tint: E4Colors.tempTint,
        valueLabel: _last(recordingState.temp, 2),
        unit: '°C',
        count: recordingState.counts[E4Signal.temp] ?? 0,
        series: [ChartSeries(recordingState.temp, E4Colors.temp, min: 30, max: 36)],
        rangeStatus: _status(E4Signal.temp, recordingState.temp),
        rangeCaption: _caption(E4Signal.temp),
        filled: true,
        chartHeight: 56,
      ),
      IbiCard(
        valueLabel: _last(recordingState.ibi, 2),
        count: recordingState.counts[E4Signal.ibi] ?? 0,
        values: recordingState.ibi,
        rangeStatus: _status(E4Signal.ibi, recordingState.ibi),
        rangeCaption: _caption(E4Signal.ibi),
      ),
      if (batteryPercent != null)
        BatteryCard(
          percent: batteryPercent,
          rangeStatus: rangeStatusFor(E4Signal.battery, batteryPercent.toDouble()),
          rangeCaption: _caption(E4Signal.battery),
        ),
    ];

    final itemWidth = (availableWidth - _horizontalPadding * 2 - _gap * (columns - 1)) / columns;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(_horizontalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RecordingCard(
            connectionStatus: connectionState.status,
            connectedDeviceId: connectionState.deviceId,
            batteryPercent: batteryPercent,
            mode: recordingState.mode,
            status: recordingState.status,
            startedAt: recordingState.startedAt,
            onModeChanged: (mode) => recordingBloc.add(RecordingModeChanged(mode)),
            onStart: () => recordingBloc.add(const StartRequested()),
            onStop: () => recordingBloc.add(const StopRequested()),
          ),
          const SizedBox(height: _gap),
          SignalCard(
            icon: Icons.water_drop,
            label: 'Blood volume pulse',
            color: E4Colors.bvp,
            tint: E4Colors.bvpTint,
            valueLabel: _last(recordingState.bvp, 2),
            unit: 'a.u.',
            count: recordingState.counts[E4Signal.bvp] ?? 0,
            series: [ChartSeries(recordingState.bvp, E4Colors.bvp, min: -4, max: 4)],
            rangeStatus: _status(E4Signal.bvp, recordingState.bvp),
            rangeCaption: _caption(E4Signal.bvp),
          ),
          const SizedBox(height: _gap),
          SignalCard(
            icon: Icons.directions_run,
            label: 'Accelerometer',
            color: E4Colors.acc,
            tint: E4Colors.accTint,
            valueLabel: _last(recordingState.accX, 2),
            unit: 'raw ×64/g',
            count: recordingState.counts[E4Signal.acc] ?? 0,
            series: [
              ChartSeries(recordingState.accX, E4Colors.acc, min: -30, max: 30),
              ChartSeries(recordingState.accY, E4Colors.acc, min: 20, max: 100, opacity: 0.55),
              ChartSeries(recordingState.accZ, E4Colors.acc, min: -25, max: 25, opacity: 0.32),
            ],
            rangeStatus: _status(E4Signal.acc, recordingState.accX),
            rangeCaption: _caption(E4Signal.acc),
          ),
          const SizedBox(height: _gap),
          Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: [for (final card in trendCards) SizedBox(width: itemWidth, child: card)],
          ),
        ],
      ),
    );
  }
}
