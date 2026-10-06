/// Small formatting helpers shared by the dashboard's elapsed-time label and
/// the history tab's start/duration labels. No `intl` dependency — the E4
/// Integrator app only ever needs `mm:ss` and a fixed `yyyy-MM-dd HH:mm:ss`.
String formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatTimestamp(DateTime dateTime) {
  final local = dateTime.toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${pad(local.month)}-${pad(local.day)} '
      '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
}
