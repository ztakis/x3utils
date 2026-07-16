import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/rdp_runner.dart';
import 'package:x3utils_flutter/models.dart';

void main() {
  test('macOS RDP check finds root config and honors A/B/C mode', () async {
    if (!Platform.isMacOS) return;

    final root = Directory.systemTemp.createTempSync('x3utils_rdp_test_');
    addTearDown(() => root.deleteSync(recursive: true));

    final binDir = Directory(p.join(root.path, 'oocd', 'bin'))
      ..createSync(recursive: true);
    final scriptsDir = Directory(p.join(root.path, 'oocd', 'scripts'))
      ..createSync(recursive: true);
    final rdpDir = Directory(p.join(root.path, 'special', 'rdp'))
      ..createSync(recursive: true);

    final sourceRdp = Directory(p.join('native', 'macos', 'special', 'rdp'));
    for (final entity in sourceRdp.listSync()) {
      if (entity is File) {
        entity.copySync(p.join(rdpDir.path, p.basename(entity.path)));
      }
    }

    final fakeOpenOcd = File(p.join(binDir.path, 'openocd'))
      ..writeAsStringSync(
        '#!/bin/bash\n'
        'echo "0x1ffff800: ffff5aa5"\n'
        'echo "0x08000000: 20001000 08000101 00000000 00000000"\n',
      );
    Process.runSync('chmod', ['+x', fakeOpenOcd.path]);

    final runner = RdpRunner(OpenOcdPaths(fakeOpenOcd.path, scriptsDir.path));

    for (final (mode, label) in <(ConnectionMode, String)>[
      (ConnectionMode.defaultSwd, 'launcher A'),
      (ConnectionMode.cloneC45, 'launcher B'),
      (ConnectionMode.genuineC45, 'launcher C'),
    ]) {
      final lines = <String>[];
      final code = await runner.run('Check', mode, 3, onLine: lines.add);
      final output = lines.join('\n');

      expect(code, 0);
      expect(lines, contains('> bash rdp_check.sh --launcher'));
      expect(output, isNot(contains('Missing config.sh')));
      expect(output, contains(label));
      expect(output, contains('NOT PROTECTED'));
    }
  });
}
