import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/recording_bloc.dart';

/// Mode selector (continuous/manual) plus start/stop, only shown in manual
/// mode — continuous mode records automatically whenever connected.
class RecordingPanel extends StatelessWidget {
  const RecordingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RecordingBloc, RecordingState>(
      builder: (context, state) {
        final bloc = context.read<RecordingBloc>();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Recording', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<RecordingMode>(
                  segments: const [
                    ButtonSegment(value: RecordingMode.continuous, label: Text('Continuous')),
                    ButtonSegment(value: RecordingMode.manual, label: Text('Manual')),
                  ],
                  selected: {state.mode},
                  onSelectionChanged: (selection) => bloc.add(RecordingModeChanged(selection.first)),
                ),
                const SizedBox(height: 8),
                if (state.mode == RecordingMode.manual)
                  FilledButton(
                    onPressed: state.status == RecordingStatus.recording
                        ? () => bloc.add(const StopRequested())
                        : () => bloc.add(const StartRequested()),
                    child: Text(state.status == RecordingStatus.recording ? 'Stop' : 'Start'),
                  ),
                const SizedBox(height: 8),
                Text('Status: ${state.status.name}'),
                if (state.startedAt != null) Text('Started: ${state.startedAt}'),
                if (state.sessionPath != null) Text('Session: ${state.sessionPath}'),
                if (state.error != null) Text(state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        );
      },
    );
  }
}
