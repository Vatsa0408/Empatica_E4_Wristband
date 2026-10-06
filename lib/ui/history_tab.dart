import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/recording_bloc.dart';
import '../model/e4_sample.dart';
import 'breakpoint.dart';
import 'format.dart';
import 'theme/e4_colors.dart';
import 'widgets/pill_widgets.dart';

const _signalLabels = {
  E4Signal.acc: 'Accelerometer',
  E4Signal.bvp: 'BVP',
  E4Signal.eda: 'EDA',
  E4Signal.hr: 'Heart rate',
  E4Signal.ibi: 'IBI',
  E4Signal.temp: 'Temperature',
  E4Signal.tag: 'Tags',
  E4Signal.battery: 'Battery',
};

/// Copies every regular file directly inside [sourcePath] into
/// [destinationPath] (created if needed). Session folders are flat (see
/// `E4SessionWriter`), so no recursive walk is needed. Returns the number of
/// files copied.
Future<int> copySessionFiles(String sourcePath, String destinationPath) async {
  await Directory(destinationPath).create(recursive: true);
  var count = 0;
  for (final entity in Directory(sourcePath).listSync()) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    await entity.copy('$destinationPath${Platform.pathSeparator}$name');
    count++;
  }
  return count;
}

Future<void> _export(BuildContext context, RecordingBloc bloc, CompletedSession session) async {
  final destinationRoot = await FilePicker.getDirectoryPath();
  if (destinationRoot == null) return; // user cancelled — not an error

  final sessionName = session.sessionPath.split(Platform.pathSeparator).last;
  final destinationPath = '$destinationRoot${Platform.pathSeparator}$sessionName';
  try {
    final copied = await copySessionFiles(session.sessionPath, destinationPath);
    bloc.add(ExportRequested(session.sessionPath));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Exported $copied file${copied == 1 ? '' : 's'} to $destinationPath')));
  } on Object catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $error')));
  }
}

Widget _exportPill(BuildContext context, RecordingBloc bloc, CompletedSession session) {
  return PillButton(
    label: session.exported ? 'Exported' : 'Export',
    icon: session.exported ? Icons.task_alt : Icons.download,
    onPressed: () => _export(context, bloc, session),
    background: session.exported ? E4Colors.exportedBg : E4Colors.exportBg,
    foreground: session.exported ? E4Colors.exportedFg : E4Colors.exportFg,
  );
}

/// Past recording sessions. A single list on compact width; a master-detail
/// split (list + detail panel) on medium and expanded alike — the design's
/// desktop frame renders a flat table instead, but the task calls for
/// master-detail on both, which is what's implemented here.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  String? _selectedPath;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = breakpointFor(constraints.maxWidth) == Breakpoint.compact;
        return BlocBuilder<RecordingBloc, RecordingState>(
          builder: (context, state) {
            if (state.history.isEmpty) {
              return const Center(
                child: Text('No sessions recorded yet.', style: TextStyle(fontSize: 13, color: E4Colors.emptyStateText)),
              );
            }
            return compact ? _CompactHistoryList(sessions: state.history) : _MasterDetailHistory(
              sessions: state.history,
              selectedPath: _selectedPath,
              onSelect: (path) => setState(() => _selectedPath = path),
            );
          },
        );
      },
    );
  }
}

class _CompactHistoryList extends StatelessWidget {
  const _CompactHistoryList({required this.sessions});

  final List<CompletedSession> sessions;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<RecordingBloc>();
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final session = sessions[index];
        final total = session.counts.values.fold<int>(0, (a, b) => a + b);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(color: E4Colors.surfaceDim, borderRadius: BorderRadius.circular(24)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatTimestamp(session.startedAt), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      'Duration ${formatDuration(Duration(milliseconds: (session.durationSec * 1000).round()))} · $total samples',
                      style: const TextStyle(fontSize: 12, color: E4Colors.neutralText),
                    ),
                  ],
                ),
              ),
              _exportPill(context, bloc, session),
            ],
          ),
        );
      },
    );
  }
}

class _MasterDetailHistory extends StatelessWidget {
  const _MasterDetailHistory({required this.sessions, required this.selectedPath, required this.onSelect});

  final List<CompletedSession> sessions;
  final String? selectedPath;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<RecordingBloc>();
    final selected = sessions.firstWhere(
      (session) => session.sessionPath == selectedPath,
      orElse: () => sessions.first,
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 300,
            child: ListView.separated(
              itemCount: sessions.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final session = sessions[index];
                final isSelected = session.sessionPath == selected.sessionPath;
                final total = session.counts.values.fold<int>(0, (a, b) => a + b);
                return Material(
                  color: isSelected ? E4Colors.navSelectedBg : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => onSelect(session.sessionPath),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: isSelected ? E4Colors.primary : E4Colors.outline, width: isSelected ? 2 : 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(formatTimestamp(session.startedAt), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(
                            '${formatDuration(Duration(milliseconds: (session.durationSec * 1000).round()))} · $total samples',
                            style: const TextStyle(fontSize: 12, color: E4Colors.neutralText),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(color: E4Colors.surfaceDim, borderRadius: BorderRadius.circular(24)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(formatTimestamp(selected.startedAt), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(
                              'Duration ${formatDuration(Duration(milliseconds: (selected.durationSec * 1000).round()))}',
                              style: const TextStyle(fontSize: 12, color: E4Colors.neutralText),
                            ),
                          ],
                        ),
                      ),
                      _exportPill(context, bloc, selected),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(height: 1, color: E4Colors.outline),
                  const SizedBox(height: 16),
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.6,
                    children: [
                      for (final entry in selected.counts.entries)
                        if (entry.value > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _signalLabels[entry.key] ?? entry.key.name,
                                  style: const TextStyle(fontSize: 11, color: E4Colors.mutedText),
                                ),
                                const SizedBox(height: 2),
                                Text('${entry.value}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
