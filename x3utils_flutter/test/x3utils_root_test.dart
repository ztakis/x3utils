import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';
import 'package:x3utils_flutter/engine/windows_ansi_path.dart';

/// One x3utils folder holds everything a run produces. These pin the parts a
/// later change could quietly undo: that every output follows the root, that
/// the default is the per-OS one, and that the old `backupFolder` preference
/// is never read again — its string meant "where dumps go", not "the parent
/// of backup/", so adopting it would move a user's backups a level down.

class _IdleRunner extends OpenOcdRunner {
  _IdleRunner() : super(OpenOcdPaths('openocd', 'scripts'));

  @override
  Future<OpenOcdResult> run(
    List<String> args,
    void Function(String line) onLine,
  ) async => OpenOcdResult(1, OpenOcdEvidence());

  @override
  Future<OpenOcdResult> runRace(
    List<String> args, {
    required void Function(String line) onLine,
    required void Function(int attempt, RaceTier tier) onAttempt,
    void Function()? onCaught,
  }) async => run(args, onLine);
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('x3utils_root');
    Firmware.setRoot(root.path);
    Firmware.bypassWindowsPathSafety = false;
  });

  tearDown(() {
    Firmware.setRoot(null);
    Firmware.bypassWindowsPathSafety = false;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('every output folder follows the root, under fixed names', () {
    final produced = <String, String>{
      'backup': Firmware.newDumpPath(),
      'compat': Firmware.newCompatPaths().$1,
      'unpacked_zip3': Firmware.unpackedBinPath('firmware.bin'),
      'packed_zip3': Firmware.packedZip3Path('pkg'),
      p.join('logs', 'dump'): Firmware.writeLog('dump', 'log body'),
    };

    produced.forEach((sub, path) {
      expect(p.dirname(path), p.join(root.path, sub), reason: sub);
    });
  });

  test('the 2nd copy stays outside the root', () {
    expect(p.isWithin(root.path, Firmware.secondCopyDir()), isFalse);
  });

  test('the default is per-OS, and blank restores it', () {
    Firmware.setRoot('   ');
    expect(Firmware.rootIsDefault, isTrue);
    expect(Firmware.root, Firmware.defaultRoot);
    if (Platform.isWindows) {
      expect(Firmware.defaultRoot, r'C:\x3utils');
    } else {
      final home = Platform.environment['HOME'] ?? Directory.current.path;
      expect(Firmware.defaultRoot, p.join(home, 'x3utils'));
    }
  });

  test('labels report the real paths and do not create anything', () {
    final fresh = Directory(p.join(root.path, 'not_yet'));
    Firmware.setRoot(fresh.path);

    expect(Firmware.backupDirLabel, p.join(fresh.path, 'backup'));
    expect(Firmware.logsDirLabel, p.join(fresh.path, 'logs'));
    expect(Firmware.rootExists, isFalse);
    expect(fresh.existsSync(), isFalse);
  });

  group('validateRootFolder', () {
    test('accepts a writable folder and leaves no probe behind', () {
      expect(Firmware.validateRootFolder(root.path).ok, isTrue);
      expect(root.listSync(), isEmpty);
    });

    test('creates a folder that does not exist yet', () {
      final fresh = p.join(root.path, 'picked');
      expect(Firmware.validateRootFolder(fresh).ok, isTrue);
      expect(Directory(fresh).existsSync(), isTrue);
    });

    test('refuses braces — OpenOCD quotes its commands with them', () {
      final check = Firmware.validateRootFolder(p.join(root.path, 'a{b}'));
      expect(check.ok, isFalse);
      expect(check.message, contains('{'));
    });

    test('refuses an empty pick', () {
      expect(Firmware.validateRootFolder('  ').ok, isFalse);
    });
  });

  group('validateOpenOcdPath', () {
    // The two halves are scoped differently ON PURPOSE, and a later change
    // could quietly re-merge them. Braces are Tcl quoting, so they break
    // everywhere. Non-ASCII is a Windows argv/codepage problem only: applying
    // it off Windows refused every dump for a user whose home carries a
    // non-ASCII name, since ~/x3utils is built from it.
    test('refuses braces on every platform', () {
      expect(Firmware.validateOpenOcdPath('/tmp/a{b}/fw.bin').ok, isFalse);
      expect(Firmware.validateOpenOcdPath('/tmp/a}b/fw.bin').ok, isFalse);
    });

    test('Windows follows its exact ACP verdict; Unix accepts non-ASCII', () {
      for (final path in [
        r'C:\Users\Jörg\Desktop\firmware.bin',
        r'C:\Users\Σοφία\Desktop\firmware.bin',
        r'C:\bins\MEMORY_G3_С45_1.5.4.bin',
      ]) {
        final expected = Platform.isWindows
            ? WindowsAnsiPath.check(path).exact
            : true;
        expect(Firmware.validateOpenOcdPath(path).ok, expected, reason: path);
      }
    });

    test('plain ASCII passes everywhere', () {
      expect(Firmware.validateOpenOcdPath('/home/a/x3utils/d.bin').ok, isTrue);
    });

    // The beta bench switch governs ONE half. Braces are a Tcl quoting rule
    // with a different cause, and letting the switch reach them would hand
    // OpenOCD a command it cannot parse — so that pairing is pinned here.
    group('bypassWindowsPathSafety (BETA3 bench switch)', () {
      tearDown(() => Firmware.bypassWindowsPathSafety = false);

      test('lets non-ASCII through when on', () {
        Firmware.bypassWindowsPathSafety = true;
        expect(
          Firmware.validateOpenOcdPath('/home/Jörg/x3utils/dump.bin').ok,
          isTrue,
        );
      });

      test('never lets braces through', () {
        Firmware.bypassWindowsPathSafety = true;
        expect(Firmware.validateOpenOcdPath('/tmp/a{b}/fw.bin').ok, isFalse);
      });

      test('defaults to off', () {
        expect(Firmware.bypassWindowsPathSafety, isFalse);
      });
    });
  });

  test('local bin validation does not inherit OpenOCD path restrictions', () {
    final offlineDir = Directory(p.join(root.path, 'Prüfung{offline}'))
      ..createSync();
    final bin = File(p.join(offlineDir.path, 'firmware.bin'))
      ..writeAsBytesSync(
        List<int>.generate(Firmware.expectedSize, (i) => i & 0xFF),
      );

    expect(Firmware.validateLocalBin(bin.path).ok, isTrue);
    expect(Firmware.validate(bin.path).ok, isFalse);
  });

  group('AppController', () {
    Future<AppController> load(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final c = AppController(runner: _IdleRunner());
      addTearDown(c.dispose);
      await Future<void>.delayed(Duration.zero); // let _loadPrefs settle
      return c;
    }

    test('a stored root is applied at startup', () async {
      final c = await load({'x3utilsRoot': root.path});
      expect(c.x3utilsRoot, root.path);
      expect(Firmware.root, root.path);
    });

    test('an old backupFolder is not adopted as the root', () async {
      final c = await load({'backupFolder': root.path});
      expect(c.x3utilsRoot, isNull);
      expect(Firmware.root, Firmware.defaultRoot);
    });

    test('BETA2 unrestricted preference is not carried into BETA3', () async {
      final c = await load({'allowNonAsciiPaths': true});

      expect(c.bypassWindowsPathSafety, isFalse);
      expect(Firmware.bypassWindowsPathSafety, isFalse);
    });

    test('BETA3 bypass preference is retired outside BETA3', () async {
      final c = await load({'beta3BypassWindowsPathSafety': true});

      expect(c.windowsPathBenchAvailable, isFalse);
      expect(c.bypassWindowsPathSafety, isFalse);
      expect(Firmware.bypassWindowsPathSafety, isFalse);
    });

    test('choosing and resetting persists', () async {
      final c = await load({});
      c.setX3utilsRoot(root.path);
      expect(Firmware.root, root.path);
      c.setX3utilsRoot(null);
      expect(c.x3utilsRoot, isNull);
      expect(Firmware.root, Firmware.defaultRoot);
    });
  });
}
