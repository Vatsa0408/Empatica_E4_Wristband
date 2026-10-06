import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves where E4 sessions are written, and builds one folder per
/// connection so an existing E4 analysis pipeline can consume it unmodified:
/// `<root>/<unixStartSeconds>_<deviceId>/`.
class SessionPaths {
  const SessionPaths();

  /// Android: app-specific external storage — visible over MTP/USB with no
  /// storage permission required. Windows: the directory containing the
  /// running executable, so `flutter run` writes into the project's build
  /// output and a built release .exe writes sessions next to itself.
  Future<Directory> sessionRoot() async {
    if (Platform.isAndroid) {
      final root = await getExternalStorageDirectory();
      if (root == null) {
        throw StateError('No session storage directory available on this platform');
      }
      return root;
    }
    return File(Platform.resolvedExecutable).parent;
  }

  Future<Directory> newSessionDirectory(String deviceId, {DateTime? startedAt}) async {
    final root = await sessionRoot();
    final unixStart = (startedAt ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final safeDeviceId = deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dir = Directory('${root.path}/${unixStart}_$safeDeviceId');
    await dir.create(recursive: true);
    return dir;
  }
}
