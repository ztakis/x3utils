import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';
import 'package:x3utils_flutter/models.dart';

/// A dump that never becomes a backup must not be able to occupy a real backup
/// name, and the two ways a dump can fail are opposite findings: a broken read
/// of a working chip, and a complete read of a protected one. These tests pin
/// both, with the trash move itself stubbed out — moving files to the real
/// Recycle Bin from a unit test is not something a test may do.

/// Replays scripted OpenOCD output AND writes the bytes a real dump would
/// leave at the path in the command line, so the staging/rename behavior can be
/// exercised without hardware.
class _DumpingRunner extends OpenOcdRunner {
  _DumpingRunner({required this.lines, required this.exitCode, this.bytes})
    : super(OpenOcdPaths('openocd', 'scripts'));

  final List<String> lines;
  final int exitCode;
  final List<int>? bytes; // null = OpenOCD wrote no file at all
  String? dumpPath;

  @override
  Future<OpenOcdResult> run(
    List<String> args,
    void Function(String line) onLine,
  ) async {
    final dump = args.firstWhere(
      (a) => a.startsWith('dump_image'),
      orElse: () => '',
    );
    if (dump.isNotEmpty && bytes != null) {
      dumpPath = RegExp(r'\{(.+)\}').firstMatch(dump)!.group(1)!;
      File(dumpPath!).writeAsBytesSync(bytes!);
    }
    final evidence = OpenOcdEvidence();
    for (final line in lines) {
      evidence.record(line);
      onLine(line);
    }
    return OpenOcdResult(exitCode, evidence);
  }

  @override
  Future<OpenOcdResult> runRace(
    List<String> args, {
    required void Function(String line) onLine,
    required void Function(int attempt, RaceTier tier) onAttempt,
    void Function()? onCaught,
  }) async => run(args, onLine);
}

List<int> _image(int length, {int? fill}) => List<int>.generate(
  length,
  (i) => fill ?? (i % 251), // varied: not a single repeated byte
);

void main() {
  late Directory backupDir;

  setUp(() {
    backupDir = Directory.systemTemp.createTempSync('x3utils_backup_test');
  });

  tearDown(() {
    if (backupDir.existsSync()) backupDir.deleteSync(recursive: true);
  });

  List<File> filesIn(Directory d, String suffix) => d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith(suffix))
      .toList();

  group('Firmware.inspectDump', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('x3utils_dump_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(List<int> bytes) {
      final path = p.join(dir.path, 'dump.bin.part');
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    test('a full varied image is a backup', () {
      final c = Firmware.inspectDump(write(_image(131072)));
      expect(c.verdict, DumpVerdict.ok);
      expect(c.ok, isTrue);
    });

    test('a short read is incomplete, not a degraded backup', () {
      final c = Firmware.inspectDump(write(_image(32768)));
      expect(c.verdict, DumpVerdict.incomplete);
      expect(c.isJunk, isTrue);
      expect(c.isEvidence, isFalse);
      expect(c.message, contains('32768 of 131072'));
    });

    test('a zero-byte file is incomplete too', () {
      expect(
        Firmware.inspectDump(write(<int>[])).verdict,
        DumpVerdict.incomplete,
      );
    });

    test('no file at all is missing', () {
      final c = Firmware.inspectDump(p.join(dir.path, 'nothing.bin.part'));
      expect(c.verdict, DumpVerdict.missing);
      expect(c.isJunk, isFalse); // there is nothing to offer to bin
    });

    test(
      'full-size all zeros is the protection signature, kept as evidence',
      () {
        final c = Firmware.inspectDump(write(_image(131072, fill: 0x00)));
        expect(c.verdict, DumpVerdict.masked);
        expect(c.isEvidence, isTrue);
        expect(c.isJunk, isFalse);
        expect(c.message, contains('Check protection'));
      },
    );

    test('full-size all 0xFF is a blank chip, kept as evidence', () {
      final c = Firmware.inspectDump(write(_image(131072, fill: 0xFF)));
      expect(c.verdict, DumpVerdict.blank);
      expect(c.isEvidence, isTrue);
    });

    test('any other repeated byte is junk, not evidence', () {
      final c = Firmware.inspectDump(write(_image(131072, fill: 0x5A)));
      expect(c.verdict, DumpVerdict.uniform);
      expect(c.isJunk, isTrue);
      expect(c.message, contains('0x5A'));
    });
  });

  group('staging', () {
    test('staged path is the backup name plus .part', () {
      final staged = Firmware.stagedDumpPath(r'C:\b\dump_x.bin');
      expect(staged, r'C:\b\dump_x.bin.part');
      expect(Firmware.isStagedDump(staged), isTrue);
    });

    test('promote renames to the real backup name', () {
      final dir = Directory.systemTemp.createTempSync('x3utils_promote_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final finalPath = p.join(dir.path, 'dump_x.bin');
      final staged = Firmware.stagedDumpPath(finalPath);
      File(staged).writeAsBytesSync(_image(131072));

      expect(Firmware.promoteDump(staged), finalPath);
      expect(File(finalPath).existsSync(), isTrue);
      expect(File(staged).existsSync(), isFalse);
    });
  });

  group('Backup action', () {
    Future<AppController> controller(_DumpingRunner runner) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0, // keep the fail screen still for assertions
      });
      final c = AppController(runner: runner);
      addTearDown(c.dispose);
      await Future<void>.delayed(Duration.zero); // let _loadPrefs settle
      c.setBackupFolder(backupDir.path);
      c.setSecondCopy(false); // never touch the real 2nd-copy folder in a test
      c.selectAction('dump');
      return c;
    }

    const dumped = [
      'target halted due to debug-request',
      'dumped 131072 bytes',
    ];

    test('a good read is promoted to a .bin backup', () async {
      final c = await controller(
        _DumpingRunner(lines: dumped, exitCode: 0, bytes: _image(131072)),
      );
      await c.start();

      expect(c.stage, StageState.ok);
      expect(filesIn(backupDir, '.bin').length, 1);
      expect(filesIn(backupDir, '.part'), isEmpty);
      expect(c.resultPath, endsWith('.bin'));
    });

    test(
      'a short read never gets a .bin name and offers the cleanup',
      () async {
        final c = await controller(
          _DumpingRunner(lines: dumped, exitCode: 0, bytes: _image(32768)),
        );
        String? offeredPath;
        String? offeredTitle;
        String? offeredReason;
        await c.start(
          confirmTrash: (path, title, reason) async {
            offeredPath = path;
            offeredTitle = title;
            offeredReason = reason;
            return false; // "Keep it"
          },
        );

        expect(c.stage, StageState.fail);
        expect(filesIn(backupDir, '.bin'), isEmpty);
        expect(filesIn(backupDir, '.part').length, 1);
        expect(offeredPath, endsWith('.bin.part'));
        expect(offeredTitle, 'This file is not a backup');
        expect(offeredReason, contains('Incomplete read'));
        // Declining leaves the file exactly where it is.
        expect(File(offeredPath!).existsSync(), isTrue);
        expect(c.resultPath, offeredPath);
      },
    );

    test(
      'a protected chip is offered too, but never called a failed read',
      () async {
        final c = await controller(
          _DumpingRunner(
            lines: dumped,
            exitCode: 0,
            bytes: _image(131072, fill: 0x00),
          ),
        );
        String? offeredTitle;
        String? offeredReason;
        await c.start(
          confirmTrash: (path, title, reason) async {
            offeredTitle = title;
            offeredReason = reason;
            return false; // never move a file to the real trash from a test
          },
        );

        expect(c.stage, StageState.fail);
        expect(filesIn(backupDir, '.bin'), isEmpty);
        expect(filesIn(backupDir, '.part').length, 1);
        // The offer appears, but the wording carries the difference: this was a
        // complete, correct read of a protected chip.
        expect(offeredTitle, 'This read is a finding, not a backup');
        expect(offeredReason, contains('not a bad read'));
        expect(c.sub, contains('Check protection'));
        // Not a contact fault, so it must not offer the re-seat retry loop —
        // and there is no input to go back and change either.
        expect(c.failureNeedsInput, isTrue);
        expect(c.failurePrimaryLabel, 'Dismiss');
      },
    );

    test('a failed connect writes nothing and offers nothing', () async {
      final c = await controller(
        _DumpingRunner(
          lines: ['Error: init mode failed (unable to connect to the target)'],
          exitCode: 1,
          bytes: null,
        ),
      );
      var offered = false;
      await c.start(
        confirmTrash: (path, title, reason) async {
          offered = true;
          return true;
        },
      );

      expect(c.stage, StageState.fail);
      expect(offered, isFalse);
      expect(backupDir.listSync(), isEmpty);
      expect(c.resultPath, isNull);
    });
  });

  group('Backup + Flash', () {
    test('an invalid pre-flash backup aborts before any write', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final runner = _DumpingRunner(
        lines: ['target halted due to debug-request', 'dumped 131072 bytes'],
        exitCode: 0,
        bytes: _image(32768),
      );
      final c = AppController(runner: runner);
      addTearDown(c.dispose);
      await Future<void>.delayed(Duration.zero);
      c.setBackupFolder(backupDir.path);
      c.setSecondCopy(false);
      c.selectAction('flash_backup');

      // A banner-valid full image: the guarded flash path checks firmware
      // identity before it takes the backup, and this test is about what
      // happens AFTER that, when the backup itself comes back short.
      final image = _image(131072);
      image.setRange(
        kSlotBannerOffset,
        kSlotBannerOffset + 16,
        'SCOOTER_VCU_xxG3'.codeUnits,
      );
      final fw = File(p.join(backupDir.parent.path, 'fw_test.bin'))
        ..writeAsBytesSync(image);
      addTearDown(() => fw.existsSync() ? fw.deleteSync() : null);
      c.setFirmware(fw.path);

      await c.start(confirmTrash: (path, title, reason) async => false);

      expect(c.stage, StageState.fail);
      expect(c.sub, contains('nothing was written'));
      expect(filesIn(backupDir, '.bin'), isEmpty);
      expect(filesIn(backupDir, '.part').length, 1);
    });
  });
}
