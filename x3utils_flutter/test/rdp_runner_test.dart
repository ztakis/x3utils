import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/rdp_runner.dart';
import 'package:x3utils_flutter/models.dart';

void main() {
  test(
    'Windows RDP passes per-run config without writing config.cmd',
    () async {
      if (!Platform.isWindows) return;

      final fixture = _makeWindowsFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));

      final expectedTargets = <ConnectionMode, String>{
        ConnectionMode.defaultSwd: r'target\at32f415xx.cfg',
        ConnectionMode.cloneC45: r'target\at32f415xx_c45.cfg',
        ConnectionMode.genuineC45: r'target\at32f415xx_nrst.cfg',
        ConnectionMode.powerRace: r'target\at32f415xx.cfg',
      };

      for (final entry in expectedTargets.entries) {
        final lines = <String>[];
        expect(
          await fixture.runner.run('Check', entry.key, 7, onLine: lines.add),
          0,
        );
        final output = lines.join('\n');
        expect(output, contains('launcher=True'));
        expect(output, contains('target=${entry.value}'));
        expect(output, contains('timeout=7'));
        expect(
          output,
          contains('logDir=${p.join(fixture.root.path, 'logs', 'rdp_check')}'),
        );
        expect(output, contains('noToolkitLog=True'));
        expect(
          output,
          contains(
            'race=${entry.key == ConnectionMode.powerRace ? 'True' : 'False'}',
          ),
        );
      }

      final config = File(p.join(fixture.rdpDir.path, 'config.cmd'));
      expect(config.existsSync(), isFalse);

      const stale = 'set "TARGET=stale.cfg"\r\nset "RACE=true"\r\n';
      config.writeAsStringSync(stale);
      final oldStamp = DateTime(2020, 1, 2, 3, 4, 5);
      config.setLastModifiedSync(oldStamp);

      final rescueLines = <String>[];
      expect(
        await fixture.runner.run(
          'Rescue',
          ConnectionMode.genuineC45,
          9,
          yes: true,
          onLine: rescueLines.add,
        ),
        0,
      );
      final rescueOutput = rescueLines.join('\n');
      expect(rescueOutput, contains('rescue=True'));
      expect(rescueOutput, contains('yes=True'));
      expect(rescueOutput, contains(r'target=target\at32f415xx_nrst.cfg'));
      expect(rescueOutput, contains('timeout=9'));
      expect(
        rescueOutput,
        contains('logDir=${p.join(fixture.root.path, 'logs', 'rdp_rescue')}'),
      );
      expect(config.readAsStringSync(), stale);
      expect(config.lastModifiedSync(), oldStamp);
    },
  );

  test('Windows bundled RDP suppresses only the GUI toolkit log', () async {
    if (!Platform.isWindows) return;

    final root = Directory.systemTemp.createTempSync(
      'x3utils_rdp_script_test_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final rdpDir = Directory(p.join(root.path, 'special', 'rdp'))
      ..createSync(recursive: true);
    final binDir = Directory(p.join(root.path, 'oocd', 'bin'))
      ..createSync(recursive: true);
    Directory(p.join(root.path, 'oocd', 'scripts')).createSync(recursive: true);

    File(
      p.join('native', 'windows', 'special', 'rdp', 'rdp.ps1'),
    ).copySync(p.join(rdpDir.path, 'rdp.ps1'));
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    File(
      p.join(systemRoot, 'System32', 'where.exe'),
    ).copySync(p.join(binDir.path, 'openocd.exe'));

    final logDir = p.join(root.path, 'toolkit_logs');
    Future<ProcessResult> invoke({required bool suppress}) =>
        Process.run('powershell', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          p.join(rdpDir.path, 'rdp.ps1'),
          '-Check',
          '-Launcher',
          '-Target',
          r'target\at32f415xx.cfg',
          '-ConnectTimeout',
          '7',
          '-LogDir',
          logDir,
          if (suppress) '-NoToolkitLog',
        ], workingDirectory: root.path).timeout(const Duration(seconds: 10));

    final guiRun = await invoke(suppress: true);
    final guiOutput = '${guiRun.stdout}\n${guiRun.stderr}';
    expect(guiRun.exitCode, 3);
    expect(guiOutput, contains('launcher A - plain'));
    expect(guiOutput, isNot(contains('Log file:')));
    expect(guiOutput, isNot(contains('Full log:')));
    expect(Directory(logDir).existsSync(), isFalse);

    final handRun = await invoke(suppress: false);
    final handOutput = '${handRun.stdout}\n${handRun.stderr}';
    expect(handRun.exitCode, 3);
    expect(handOutput, contains('Log file:'));
    expect(handOutput, contains('Full log:'));
    final toolkitLogs = Directory(logDir).listSync().whereType<File>().toList();
    expect(toolkitLogs, hasLength(1));
    expect(
      p.basename(toolkitLogs.single.path),
      startsWith('rdp_check_toolkit_'),
    );
    expect(toolkitLogs.single.lengthSync(), greaterThan(0));
  });

  test('Unix bundled RDP suppresses only the GUI toolkit log', () async {
    if (Platform.isWindows) return;

    final platformDir = Platform.isMacOS ? 'macos' : 'linux';
    final fixture = _makeUnixFixture(
      platformDir: platformDir,
      openOcdScript:
          '#!/bin/bash\n'
          'echo "0x1ffff800: ffff5aa5"\n'
          'echo "0x08000000: 20001000 08000101 00000000 00000000"\n',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final guiLines = <String>[];
    expect(
      await fixture.runner.run(
        'Check',
        ConnectionMode.defaultSwd,
        3,
        onLine: guiLines.add,
      ),
      0,
    );
    final guiOutput = guiLines.join('\n');
    expect(
      guiLines,
      contains('> bash rdp_check.sh --launcher --no-toolkit-log'),
    );
    expect(guiOutput, contains('NOT PROTECTED'));
    expect(guiOutput, isNot(contains('Log file:')));
    expect(guiOutput, isNot(contains('Full log:')));
    expect(
      Directory(p.join(fixture.root.path, 'logs', 'rdp_check')).existsSync(),
      isFalse,
    );

    final handLogDir = p.join(fixture.root.path, 'manual_toolkit_logs');
    _writeManualUnixConfig(fixture.root, platformDir, handLogDir);
    final handRun = await Process.run(
      'bash',
      [
        p.join(fixture.root.path, 'special', 'rdp', 'rdp_check.sh'),
        '--launcher',
      ],
      workingDirectory: fixture.root.path,
    ).timeout(const Duration(seconds: 10));
    final handOutput = '${handRun.stdout}\n${handRun.stderr}';
    expect(handRun.exitCode, 0);
    expect(handOutput, contains('NOT PROTECTED'));
    expect(handOutput, contains('Log file:'));
    expect(handOutput, contains('Full log:'));
    final toolkitLogs = Directory(
      handLogDir,
    ).listSync().whereType<File>().toList();
    expect(toolkitLogs, hasLength(1));
    expect(
      p.basename(toolkitLogs.single.path),
      startsWith('rdp_check_toolkit_'),
    );
    expect(toolkitLogs.single.lengthSync(), greaterThan(0));
  });

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
      expect(
        lines,
        contains('> bash rdp_check.sh --launcher --no-toolkit-log'),
      );
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

({Directory root, Directory rdpDir, RdpRunner runner}) _makeWindowsFixture() {
  final root = Directory.systemTemp.createTempSync('x3utils_rdp_test_');
  final binDir = Directory(p.join(root.path, 'oocd', 'bin'))
    ..createSync(recursive: true);
  final scriptsDir = Directory(p.join(root.path, 'oocd', 'scripts'))
    ..createSync(recursive: true);
  final rdpDir = Directory(p.join(root.path, 'special', 'rdp'))
    ..createSync(recursive: true);

  File(p.join(rdpDir.path, 'rdp.ps1')).writeAsStringSync(r'''
param(
  [switch]$Check,
  [switch]$Rescue,
  [switch]$Yes,
  [switch]$Launcher,
  [string]$Target,
  [int]$ConnectTimeout,
  [string]$LogDir,
  [switch]$Race,
  [switch]$NoToolkitLog
)
Write-Output "check=$($Check.IsPresent)"
Write-Output "rescue=$($Rescue.IsPresent)"
Write-Output "yes=$($Yes.IsPresent)"
Write-Output "launcher=$($Launcher.IsPresent)"
Write-Output "target=$Target"
Write-Output "timeout=$ConnectTimeout"
Write-Output "logDir=$LogDir"
Write-Output "race=$($Race.IsPresent)"
Write-Output "noToolkitLog=$($NoToolkitLog.IsPresent)"
exit 0
''');

  Firmware.setRoot(root.path);
  addTearDown(() => Firmware.setRoot(null));
  return (
    root: root,
    rdpDir: rdpDir,
    runner: RdpRunner(
      OpenOcdPaths(p.join(binDir.path, 'openocd.exe'), scriptsDir.path),
    ),
  );
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
    final output = lines.join('\n').toLowerCase();
    expect(output, contains('unable to open st-link'));
    expect(output, contains('press enter to retry'));
    expect(output, contains('0x1ffff800: ffff5aa5'));
    expect(
      Directory(
        p.join(
          fixture.root.path,
          'logs',
          verb == 'Rescue' ? 'rdp_rescue' : 'rdp_check',
        ),
      ).existsSync(),
      isFalse,
    );
  }
}

({Directory root, RdpRunner runner}) _makeMacFixture({
  required String openOcdScript,
}) => _makeUnixFixture(platformDir: 'macos', openOcdScript: openOcdScript);

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

  // Keep any GUI or direct-script output inside the fixture: a test must not
  // write into the real x3utils root.
  Firmware.setRoot(root.path);
  addTearDown(() => Firmware.setRoot(null));

  return (
    root: root,
    runner: RdpRunner(OpenOcdPaths(fakeOpenOcd.path, scriptsDir.path)),
  );
}

void _writeManualUnixConfig(Directory root, String platformDir, String logDir) {
  final rdpDir = p.join(root.path, 'special', 'rdp');
  final configDir = platformDir == 'macos' ? root.path : rdpDir;
  final target = platformDir == 'macos'
      ? 'target/artery/at32f4x.cfg'
      : 'target/at32f415xx.cfg';
  File(p.join(configDir, 'config.sh')).writeAsStringSync(
    'export CL_NC=""\n'
    'export CL_R=""\n'
    'export CL_G=""\n'
    'export CL_Y=""\n'
    'export CL_M=""\n'
    'export CL_C=""\n'
    'export D="============================================================"\n'
    'OPENOCD_BIN="${p.join(root.path, 'oocd', 'bin', 'openocd')}"\n'
    'SCRIPTS_DIR="${p.join(root.path, 'oocd', 'scripts')}"\n'
    'INTERFACE="interface/stlink.cfg"\n'
    'TARGET="$target"\n'
    'CONNECT_TIMEOUT=3\n'
    'X3UTILS_RDP_LOG_DIR="$logDir"\n'
    'EXPECTED_SIZE=131072\n',
  );
}
