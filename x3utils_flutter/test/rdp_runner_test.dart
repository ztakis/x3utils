import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/rdp_runner.dart';
import 'package:x3utils_flutter/models.dart';

void main() {
  test('macOS RDP check finds root config and honors A/B/C mode', () async {
    if (!Platform.isMacOS) return;

    final fixture = _makeMacFixture(
      openOcdScript:
          '#!/bin/bash\n'
          'echo "0x1ffff800: ffff5aa5"\n'
          'echo "0x08000000: 20001000 08000101 00000000 00000000"\n',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    for (final (mode, label) in <(ConnectionMode, String)>[
      (ConnectionMode.defaultSwd, 'launcher A'),
      (ConnectionMode.cloneC45, 'launcher B'),
      (ConnectionMode.genuineC45, 'launcher C'),
    ]) {
      final lines = <String>[];
      final code = await fixture.runner.run(
        'Check',
        mode,
        3,
        onLine: lines.add,
      );
      final output = lines.join('\n');

      expect(code, 0);
      expect(lines, contains('> bash rdp_check.sh --launcher'));
      expect(output, isNot(contains('Missing config.sh')));
      expect(output, contains(label));
      expect(output, contains('NOT PROTECTED'));
    }
  });

  test('macOS RDP retry prompts survive redirected stdio', () async {
    if (!Platform.isMacOS) return;

    await _expectUnixRetryPrompts('macos');
  });

  test('Linux RDP retry prompts survive redirected stdio', () async {
    if (!Platform.isLinux) return;

    await _expectUnixRetryPrompts('linux');
  });
}

Future<void> _expectUnixRetryPrompts(String platformDir) async {
  for (final (verb, yes) in <(String, bool)>[
    ('Check', false),
    ('Rescue', true),
  ]) {
    final fixture = _makeUnixFixture(
      platformDir: platformDir,
      openOcdScript:
          '#!/bin/bash\n'
          'if [[ ! -f "@STATE@" ]]; then\n'
          '  touch "@STATE@"\n'
          '  echo "Error: unable to open ST-LINK"\n'
          '  exit 1\n'
          'fi\n'
          'echo "0x1ffff800: ffff5aa5"\n'
          'echo "0x08000000: 20001000 08000101 00000000 00000000"\n',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final promptSeen = Completer<void>();
    final lines = <String>[];
    final run = fixture.runner.run(
      verb,
      ConnectionMode.defaultSwd,
      3,
      yes: yes,
      onLine: lines.add,
      onChunk: (chunk) {
        if (!promptSeen.isCompleted &&
            chunk.toLowerCase().contains('press enter to retry')) {
          promptSeen.complete();
        }
      },
    );

    await promptSeen.future.timeout(const Duration(seconds: 5));
    expect(fixture.runner.sendContinue(), isTrue);
    expect(await run.timeout(const Duration(seconds: 5)), 0);
    expect(lines.join('\n').toLowerCase(), contains('press enter to retry'));
  }
}

({Directory root, RdpRunner runner}) _makeMacFixture({
  required String openOcdScript,
}) => _makeUnixFixture(
  platformDir: 'macos',
  openOcdScript: openOcdScript,
);

({Directory root, RdpRunner runner}) _makeUnixFixture({
  required String platformDir,
  required String openOcdScript,
}) {
  final root = Directory.systemTemp.createTempSync('x3utils_rdp_test_');
  final binDir = Directory(p.join(root.path, 'oocd', 'bin'))
    ..createSync(recursive: true);
  final scriptsDir = Directory(p.join(root.path, 'oocd', 'scripts'))
    ..createSync(recursive: true);
  final rdpDir = Directory(p.join(root.path, 'special', 'rdp'))
    ..createSync(recursive: true);

  final sourceRdp = Directory(p.join('native', platformDir, 'special', 'rdp'));
  for (final entity in sourceRdp.listSync()) {
    if (entity is File) {
      entity.copySync(p.join(rdpDir.path, p.basename(entity.path)));
    }
  }

  final statePath = p.join(root.path, 'first_attempt_complete');
  final fakeOpenOcd = File(p.join(binDir.path, 'openocd'))
    ..writeAsStringSync(openOcdScript.replaceAll('@STATE@', statePath));
  Process.runSync('chmod', ['+x', fakeOpenOcd.path]);

  return (
    root: root,
    runner: RdpRunner(OpenOcdPaths(fakeOpenOcd.path, scriptsDir.path)),
  );
}
