import 'package:flutter/material.dart' hide ConnectionState;

import '../../bloc/connection_bloc.dart';
import '../../bloc/recording_bloc.dart';
import '../format.dart';
import '../signal_ranges.dart';
import '../theme/e4_colors.dart';
import 'connection_chip.dart';
import 'pill_widgets.dart';
import 'signal_chart.dart';

IconData batteryIcon(int percent) {
  if (percent >= 90) return Icons.battery_full;
  if (percent >= 60) return Icons.battery_5_bar;
  if (percent >= 40) return Icons.battery_4_bar;
  if (percent >= 20) return Icons.battery_3_bar;
  return Icons.battery_alert;
}

Color batteryColor(int percent) => percent < 20 ? E4Colors.batteryLow : E4Colors.batteryNormal;

/// The dashboard's top control card: connection summary, Manual/Continuous
/// mode toggle, status line, and Start/Stop.
class RecordingCard extends StatelessWidget {
  const RecordingCard({
    super.key,
    required this.connectionStatus,
    required this.connectedDeviceId,
    required this.batteryPercent,
    required this.mode,
    required this.status,
    required this.startedAt,
    required this.onModeChanged,
    required this.onStart,
    required this.onStop,
  });

  final ConnectionStatus connectionStatus;
  final String? connectedDeviceId;
  final int? batteryPercent;
  final RecordingMode mode;
  final RecordingStatus status;
  final DateTime? startedAt;
  final ValueChanged<RecordingMode> onModeChanged;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final spec = connectionSpecFor(connectionStatus);
    final isConnected = connectionStatus == ConnectionStatus.connected;
    final isRecording = status == RecordingStatus.recording;
    final canStart = isConnected && !isRecording;
    final battery = batteryPercent;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: E4Colors.surfaceDim, borderRadius: BorderRadius.circular(28)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(spec.icon, size: 20, color: spec.foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(spec.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    if (isConnected && connectedDeviceId != null)
                      Text(connectedDeviceId!, style: const TextStyle(fontSize: 12, color: E4Colors.neutralText)),
                  ],
                ),
              ),
              if (isConnected && battery != null) ...[
                Icon(batteryIcon(battery), size: 18, color: batteryColor(battery)),
                const SizedBox(width: 4),
                Text(
                  '$battery%',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: batteryColor(battery)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: E4Colors.outline),
          const SizedBox(height: 14),
          SegmentedPill<RecordingMode>(
            options: const [(RecordingMode.manual, 'Manual'), (RecordingMode.continuous, 'Continuous')],
            selected: mode,
            onChanged: onModeChanged,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  isRecording ? 'Recording · ${formatDuration(DateTime.now().difference(startedAt!))}' : 'Ready',
                  style: const TextStyle(fontSize: 12, color: E4Colors.neutralText),
                ),
              ),
              if (isRecording)
                PillButton(
                  label: 'Stop',
                  icon: Icons.stop,
                  onPressed: onStop,
                  background: E4Colors.stopBg,
                  foreground: E4Colors.stopFg,
                )
              else
                PillButton(
                  label: 'Start',
                  icon: Icons.fiber_manual_record,
                  onPressed: canStart ? onStart : null,
                  background: canStart ? E4Colors.primary : E4Colors.disabledBg,
                  foreground: canStart ? Colors.white : E4Colors.disabledFg,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A raw-signal waveform card (BVP, ACC) or derived trend card (HR, EDA,
/// TEMP), unified into one widget parameterized by domain/color/fill —
/// reused for every dashboard chart except IBI's distinct horizontal layout.
class SignalCard extends StatelessWidget {
  const SignalCard({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.tint,
    required this.valueLabel,
    required this.unit,
    required this.count,
    required this.series,
    required this.rangeStatus,
    required this.rangeCaption,
    this.filled = false,
    this.chartHeight = 64,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color tint;
  final String valueLabel;
  final String unit;
  final int count;
  final List<ChartSeries> series;
  final RangeStatus rangeStatus;
  final String rangeCaption;
  final bool filled;
  final double chartHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(28)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
              Text('$count samples', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: E4Colors.neutralText)),
            ],
          ),
          const SizedBox(height: 10),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: valueLabel,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color),
                ),
                const TextSpan(text: ' '),
                TextSpan(
                  text: unit,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: E4Colors.neutralText),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          RangePill(status: rangeStatus, caption: rangeCaption),
          const SizedBox(height: 10),
          SignalChart(series: series, filled: filled, height: chartHeight),
        ],
      ),
    );
  }
}

/// Inter-beat interval's distinct horizontal layout: text on the left, a
/// small sparkline on the right.
class IbiCard extends StatelessWidget {
  const IbiCard({
    super.key,
    required this.valueLabel,
    required this.count,
    required this.values,
    required this.rangeStatus,
    required this.rangeCaption,
  });

  final String valueLabel;
  final int count;
  final List<double> values;
  final RangeStatus rangeStatus;
  final String rangeCaption;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(color: E4Colors.ibiTint, borderRadius: BorderRadius.circular(28)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.timer, size: 18, color: E4Colors.ibi),
                    SizedBox(width: 8),
                    Text('Inter-beat interval', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 8),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: valueLabel,
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: E4Colors.ibi),
                      ),
                      const TextSpan(
                        text: ' s',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: E4Colors.neutralText),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text('$count samples', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: E4Colors.neutralText)),
                const SizedBox(height: 6),
                RangePill(status: rangeStatus, caption: rangeCaption),
              ],
            ),
          ),
          SizedBox(
            width: 120,
            height: 40,
            child: SignalChart(series: [ChartSeries(values, E4Colors.ibi, min: 0.3, max: 1.3)], height: 40),
          ),
        ],
      ),
    );
  }
}

/// Onboard device battery, shown only once a real battery sample has
/// arrived — never seeded with mock data.
class BatteryCard extends StatelessWidget {
  const BatteryCard({super.key, required this.percent, required this.rangeStatus, required this.rangeCaption});

  final int percent;
  final RangeStatus rangeStatus;
  final String rangeCaption;

  @override
  Widget build(BuildContext context) {
    final color = batteryColor(percent);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(color: E4Colors.batteryTint, borderRadius: BorderRadius.circular(28)),
      child: Row(
        children: [
          Icon(batteryIcon(percent), size: 24, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Battery', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const Text('Onboard device power', style: TextStyle(fontSize: 11, color: E4Colors.neutralText)),
                const SizedBox(height: 6),
                RangePill(status: rangeStatus, caption: rangeCaption),
              ],
            ),
          ),
          Text('$percent%', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color)),
        ],
      ),
    );
  }
}
