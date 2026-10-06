import 'dart:io';

import 'package:e4_integrator/ui/history_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('copySessionFiles copies flat files and skips subdirectories', () async {
    final source = await Directory.systemTemp.createTemp('e4_export_src_');
    final dest = await Directory.systemTemp.createTemp('e4_export_dst_');
    addTearDown(() async {
      if (await source.exists()) await source.delete(recursive: true);
      if (await dest.exists()) await dest.delete(recursive: true);
    });

    await File('${source.path}/BVP.csv').writeAsString('1,2,3');
    await File('${source.path}/info.txt').writeAsString('hello');
    await Directory('${source.path}/nested').create();

    final destSession = Directory('${dest.path}/session');
    final copied = await copySessionFiles(source.path, destSession.path);

    expect(copied, 2);
    expect(await File('${destSession.path}/BVP.csv').readAsString(), '1,2,3');
    expect(await File('${destSession.path}/info.txt').readAsString(), 'hello');
    expect(Directory('${destSession.path}/nested').existsSync(), isFalse);
  });
}
