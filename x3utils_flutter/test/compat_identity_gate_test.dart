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

/// SHU compat used to patch whatever it dumped — its only test was that the
/// file reached 0x1430. These pin the identity gate that now runs between the
/// backup and the patch, and in particular that a refusal happens BEFORE any
/// erase/write reaches OpenOCD while the backup stays on disk.

/// Records every OpenOCD invocation and writes the bytes a real dump would
/// leave, so "nothing was written" can be asserted rather than assumed.
class _RecordingRunner extends OpenOcdRunner {
  _RecordingRunner(this.dumpBytes) : super(OpenOcdPaths('openocd', 'scripts'));

  final List<int> dumpBytes;
  final List<List<String>> calls = [];

  /// True once an erase/write actually reached the runner.
  bool get wroteFlash => calls.any(
    (a) => a.any(
      (s) =>
          s.startsWith('flash erase_address') ||
          s.startsWith('flash write_bank') ||
          s.startsWith('flash write_image'),
    ),
  );

  @override
  Future<OpenOcdResult> run(
    List<String> args,
    void Function(String line) onLine,
  ) async {
    calls.add(args);
    final dump = args.firstWhere(
      (a) => a.startsWith('dump_image'),
      orElse: () => '',
    );
    final lines = <String>['target halted due to debug-request'];
    if (dump.isNotEmpty) {
      final path = RegExp(r'\{(.+)\}').firstMatch(dump)!.group(1)!;
      File(path).writeAsBytesSync(dumpBytes);
      lines.add('dumped 131072 bytes');
    } else {
      lines
        ..add('erased 128 KiB')
        ..add('wrote 131072 bytes')
        ..add('verified 131072 bytes');
    }
    final evidence = OpenOcdEvidence();
    for (final line in lines) {
      evidence.record(line);
      onLine(line);
    }
    return OpenOcdResult(0, evidence);
  }

  @override
  Future<OpenOcdResult> runRace(
    List<String> args, {
    required void Function(String line) onLine,
    required void Function(int attempt, RaceTier tier) onAttempt,
    void Function()? onCaught,
  }) async => run(args, onLine);
}

/// A 128 KB dump that passes the completeness checks: varied bytes (never a
/// single repeated value), a real banner, and optionally a version constant
/// planted inside slot 0.
///
/// The `i % 251` filler cannot accidentally decode as a version load — its
/// consecutive bytes differ by one, so the `40 f2` / `4f f0` opcode pairs never
/// occur.
List<int> _dump({required String banner, int? versionValue}) {
  final b = List<int>.generate(131072, (i) => i % 251);
  b.setRange(
    kSlotBannerOffset,
    kSlotBannerOffset + kBannerLength,
    banner.codeUnits,
  );
  if (versionValue != null) {
    // MOVW r0,#imm — planted at a fixed spot well inside slot 0 (0x1000-0xffff).
    const at = 0x3000;
    final i = (versionValue >> 11) & 1;
    final imm3 = (versionValue >> 8) & 7;
    final imm8 = versionValue & 0xFF;
    final hw1 = 0xF240 | (i << 10);
    final hw2 = (imm3 << 12) | imm8; // Rd = r0
    b.setRange(at, at + 4, [hw1 & 0xFF, hw1 >> 8, hw2 & 0xFF, hw2 >> 8]);
  }
  return b;
}

void main() {
  late Directory rootDir;

  setUp(() => rootDir = Directory.systemTemp.createTempSync('x3utils_gate_'));
  tearDown(() {
    Firmware.setRoot(null);
    if (rootDir.existsSync()) rootDir.deleteSync(recursive: true);
  });

  Future<AppController> compatRunner(
    _RecordingRunner runner, {
    UnsurePolicy policy = UnsurePolicy.abort,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final c = AppController(runner: runner);
    addTearDown(c.dispose);
    await Future<void>.delayed(Duration.zero);
    c.setX3utilsRoot(rootDir.path);
    c.setSecondCopy(false);
    c.setCompatUnsurePolicy(policy);
    c.selectAction('flash_compat');
    return c;
  }

  List<File> compatFiles(String suffix) {
    final d = Directory(p.join(rootDir.path, 'compat'));
    if (!d.existsSync()) return [];
    return d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(suffix))
        .toList();
  }

  test(
    'a blacklisted version aborts before any write, keeping the backup',
    () async {
      // g3 VCU 1.6.3 — the build SHU compat cannot help, and whose key it would
      // overwrite for nothing.
      final runner = _RecordingRunner(
        _dump(banner: 'SCOOTER_VCU_xxG3', versionValue: 0x163),
      );
      final c = await compatRunner(runner);

      await c.start();

      expect(c.stage, StageState.fail);
      expect(c.sub, contains('1.6.3'));
      expect(c.sub, contains('Nothing was written'));
      expect(runner.wroteFlash, isFalse, reason: 'must refuse before erasing');
      expect(compatFiles('.bin'), isNotEmpty, reason: 'backup must survive');
      expect(c.resultPath, isNotNull);
    },
  );

  test('an unrecognised version aborts when the policy is abort', () async {
    // A supported banner, but no version constant we can place.
    final runner = _RecordingRunner(_dump(banner: 'SCOOTER_VCU_xxG3'));
    final c = await compatRunner(runner);

    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.sub, contains('does not recognise'));
    expect(runner.wroteFlash, isFalse);
    expect(compatFiles('.bin'), isNotEmpty);
  });

  test(
    'ask policy lets the operator continue past an unrecognised build',
    () async {
      final runner = _RecordingRunner(_dump(banner: 'SCOOTER_VCU_xxG3'));
      final c = await compatRunner(runner, policy: UnsurePolicy.ask);
      var asked = false;

      await c.start(
        confirmUnidentified: (finding) async {
          asked = true;
          expect(finding, contains('does not recognise'));
          return true;
        },
      );

      expect(asked, isTrue);
      expect(runner.wroteFlash, isTrue, reason: 'operator approved the patch');
    },
  );

  test('ask policy still stops when the operator declines', () async {
    final runner = _RecordingRunner(_dump(banner: 'SCOOTER_VCU_xxG3'));
    final c = await compatRunner(runner, policy: UnsurePolicy.ask);

    await c.start(confirmUnidentified: (_) async => false);

    expect(c.stage, StageState.fail);
    expect(runner.wroteFlash, isFalse);
  });

  test('a known good version proceeds to patch and flash', () async {
    // g3 VCU 1.5.5 — known, and not on the blacklist.
    final runner = _RecordingRunner(
      _dump(banner: 'SCOOTER_VCU_xxG3', versionValue: 0x155),
    );
    final c = await compatRunner(runner);

    await c.start();

    expect(runner.wroteFlash, isTrue);
    expect(compatFiles('_patched.bin'), isNotEmpty);
  });

  test('an unsupported banner aborts before the patch', () async {
    final runner = _RecordingRunner(_dump(banner: 'SCOOTER_VCU_xxZ9'));
    final c = await compatRunner(runner);

    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.sub, contains('not running firmware x3utils recognises'));
    expect(runner.wroteFlash, isFalse);
  });

  test('GT3 is refused whatever version it reports', () async {
    final runner = _RecordingRunner(
      _dump(banner: 'SCOOTER_VCU_xGT3', versionValue: 0x158),
    );
    final c = await compatRunner(runner);

    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.sub, contains('GT3'));
    expect(c.sub, contains('any firmware version'));
    expect(runner.wroteFlash, isFalse);
  });

  group('MCU', () {
    test('prompts for the model, and cancelling aborts', () async {
      final runner = _RecordingRunner(_dump(banner: 'SCOOTER_MCU_0001'));
      final c = await compatRunner(runner);
      List<String>? offered;

      await c.start(
        askMcuModel: (models) async {
          offered = models;
          return null; // operator cancels
        },
      );

      expect(offered, isNotNull);
      expect(offered, contains('g3'));
      expect(c.stage, StageState.fail);
      expect(c.sub, contains('does not say which model'));
      expect(runner.wroteFlash, isFalse);
    });

    test(
      'a declared model selects that list and is logged as unverified',
      () async {
        // g3 MCU 1.5.0 is a known build; declaring g3 identifies it.
        final runner = _RecordingRunner(
          _dump(banner: 'SCOOTER_MCU_0001', versionValue: 0x150),
        );
        final c = await compatRunner(runner);

        await c.start(askMcuModel: (_) async => 'g3');

        expect(runner.wroteFlash, isTrue);
        expect(
          c.console.any((l) => l.contains('declared MCU model: g3')),
          isTrue,
        );
        expect(c.console.any((l) => l.contains('not verifiable')), isTrue);
      },
    );

    test('declaring GT3 is refused like a GT3 banner', () async {
      final runner = _RecordingRunner(_dump(banner: 'SCOOTER_MCU_0001'));
      final c = await compatRunner(runner);

      await c.start(askMcuModel: (_) async => 'gt3');

      expect(c.stage, StageState.fail);
      expect(c.sub, contains('GT3'));
      expect(runner.wroteFlash, isFalse);
    });
  });
}
