import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/recording_bloc.dart';
import '../model/e4_sample.dart';

/// Live per-signal sample count and last value. `tag` is expected to stay
/// empty — no known BLE path for the E4's physical button (see CLAUDE.md).
class SignalTable extends StatelessWidget {
  const SignalTable({super.key});

  static const _units = {
    E4Signal.acc: 'raw counts, 64*g',
    E4Signal.bvp: 'a.u.',
    E4Signal.eda: 'µS',
    E4Signal.hr: 'bpm',
    E4Signal.ibi: 's',
    E4Signal.temp: '°C',
    E4Signal.tag: 's',
    E4Signal.battery: '%',
  };

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RecordingBloc, RecordingState>(
      builder: (context, state) {
        return Card(
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Signal')),
              DataColumn(label: Text('Count')),
              DataColumn(label: Text('Last value')),
            ],
            rows: E4Signal.values.map((signal) {
              final count = state.counts[signal] ?? 0;
              final latest = state.latest[signal];
              return DataRow(
                cells: [
                  DataCell(Text('${signal.name} (${_units[signal]})')),
                  DataCell(Text('$count')),
                  DataCell(Text(latest == null ? '-' : latest.values.map((v) => v.toStringAsFixed(2)).join(', '))),
                ],
              );
            }).toList(),
          ),
        );
      },
    );
  }
}
