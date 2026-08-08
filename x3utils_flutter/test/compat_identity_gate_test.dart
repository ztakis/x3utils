import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';
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
/// [zpPayloadLength] plants the device's own firmware-length record at 0x1F800
/// (`ZP`, six zeros, then the LE u32 ENCRYPTED length = payload + 4), which is
/// what the zip3 packer slices on. Without it the packer refuses, so the tests
/// that assert a package exists must ask for one.
List<int> _dump({
  required String banner,
  int? versionValue,
  int? zpPayloadLength,
}) {
  final b = List<int>.generate(131072, (i) => i % 251);
  if (zpPayloadLength != null) {
    final encLen = zpPayloadLength + 4;
    b.setRange(0x1F800, 0x1F810, [
      0x5A, 0x50, 0, 0, 0, 0, 0, 0, // "ZP" + six zeros
      encLen & 0xFF, (encLen >> 8) & 0xFF,
      (encLen >> 16) & 0xFF, (encLen >> 24) & 0xFF,
      0, 0, 0, 0,
    ]);
  }
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

  Future<AppController> compatRunner(_RecordingRunner runner) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final c = AppController(runner: runner);
    addTearDown(c.dispose);
    await Future<void>.delayed(Duration.zero);
    c.setX3utilsRoot(rootDir.path);
    c.setSecondCopy(false);
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

  test('an unrecognised version fails closed with no way to ask', () async {
    // A supported banner, but no version constant we can place — and no
    // confirmation callback, so there is no way to obtain consent. Refusing is
    // the only safe reading of silence.
    final runner = _RecordingRunner(_dump(banner: 'SCOOTER_VCU_xxG3'));
    final c = await compatRunner(runner);

    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.sub, contains('does not recognise'));
    expect(runner.wroteFlash, isFalse);
    expect(compatFiles('.bin'), isNotEmpty);
  });

  test('an unrecognised build asks, and the operator may continue', () async {
    final runner = _RecordingRunner(_dump(banner: 'SCOOTER_VCU_xxG3'));
    final c = await compatRunner(runner);
    var asked = false;

    await c.start(
      confirmUnidentified: (finding, ceiling) async {
        asked = true;
        expect(finding, contains('does not recognise'));
        // The ceiling arrives separately so the view can weight it — it is the
        // number that would have decided this, and the operator reads it first.
        expect(ceiling, contains('On G3 VCU, 1.6.3 and newer'));
        return true;
      },
    );

    expect(asked, isTrue);
    expect(runner.wroteFlash, isTrue, reason: 'operator approved the patch');
  });

  test('an unrecognised build stops when the operator declines', () async {
    final runner = _RecordingRunner(_dump(banner: 'SCOOTER_VCU_xxG3'));
    final c = await compatRunner(runner);

    await c.start(confirmUnidentified: (_, _) async => false);

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

  /// The zips of a run live in their own `<run>_zips` folder, so the two clean
  /// identity filenames can repeat across runs without collision.
  List<String> zipNames() {
    final compat = Directory(p.join(rootDir.path, 'compat'));
    if (!compat.existsSync()) return [];
    return compat
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.endsWith('_zips'))
        .expand((d) => d.listSync().whereType<File>())
        .map((f) => p.basename(f.path))
        .toList()
      ..sort();
  }

  test('each ticked format packages both the stock and patched firmware', () async {
    // 58436 ≡ 4 (mod 8): the ZP guard invariant, and the exact constraint
    // legacy NinebotTEA packing needs for an exact round trip.
    final runner = _RecordingRunner(
      _dump(
        banner: 'SCOOTER_VCU_xxG3',
        versionValue: 0x155,
        zpPayloadLength: 58436,
      ),
    );
    final c = await compatRunner(runner);
    c.setCompatMakeZip3(true);
    c.setCompatMakeZip32(true);

    await c.start();

    expect(runner.wroteFlash, isTrue);
    // The stock packages are the point: the raw backup is a 128 KB dump the BLE
    // app cannot load, so these are the only ST-Link-free way back. Every name
    // carries the version identified BEFORE the write, plus the format token a
    // 3.x user needs to pick the file their app can read.
    expect(zipNames(), [
      'g3_vcu_v1.5.5_compat_zip3.zip',
      'g3_vcu_v1.5.5_compat_zip32.zip',
      'g3_vcu_v1.5.5_stock_zip3.zip',
      'g3_vcu_v1.5.5_stock_zip32.zip',
    ]);
    expect(
      c.resultNote,
      allOf(
        contains('4 packages saved in'),
        contains('Loading a stock package restores the original key.'),
      ),
    );
  });

  test(
    'the zip3 box alone emits legacy packages a SHU 3.x app can read',
    () async {
      final runner = _RecordingRunner(
        _dump(
          banner: 'SCOOTER_VCU_xxG3',
          versionValue: 0x155,
          zpPayloadLength: 58436,
        ),
      );
      final c = await compatRunner(runner);
      c.setCompatMakeZip3(true);

      await c.start();

      expect(zipNames(), [
        'g3_vcu_v1.5.5_compat_zip3.zip',
        'g3_vcu_v1.5.5_stock_zip3.zip',
      ]);
      // schemaVersion 1 is what the 3.x app demanded; assert the built artifact
      // rather than the request, and that the payload survives the round trip.
      final dir = Directory(p.join(rootDir.path, 'compat'))
          .listSync()
          .whereType<Directory>()
          .firstWhere((d) => d.path.endsWith('_zips'));
      final bytes = File(
        p.join(dir.path, 'g3_vcu_v1.5.5_stock_zip3.zip'),
      ).readAsBytesSync();
      final pkg = PackV3.unpackV3(bytes, policy: Zip3UnpackPolicy.extract);
      expect(pkg.format, Zip3Format.legacy);
      expect(pkg.displayName, 'g3_vcu_v1.5.5_stock_zip3');
      expect(pkg.firmware, hasLength(58436));
    },
  );

  test(
    'a waved-through build is not named as though it were identified',
    () async {
      // Operator continues past a version x3utils cannot place, so
      // there is no version to put in the name.
      final runner = _RecordingRunner(
        _dump(banner: 'SCOOTER_VCU_xxG3', zpPayloadLength: 58436),
      );
      final c = await compatRunner(runner);
      c.setCompatMakeZip3(true);

      await c.start(confirmUnidentified: (_, _) async => true);

      expect(runner.wroteFlash, isTrue);
      expect(zipNames(), [
        'g3_vcu_unknownfw_compat_zip3.zip',
        'g3_vcu_unknownfw_stock_zip3.zip',
      ]);
    },
  );

  test('compat names the package it could not build', () async {
    // No ZP record, so the packer refuses both — the success screen must say
    // so rather than leave the operator assuming an undo package exists.
    final runner = _RecordingRunner(
      _dump(banner: 'SCOOTER_VCU_xxG3', versionValue: 0x155),
    );
    final c = await compatRunner(runner);
    c.setCompatMakeZip3(true);

    await c.start();

    expect(runner.wroteFlash, isTrue);
    expect(zipNames(), isEmpty);
    expect(c.resultNote ?? '', isNot(contains('zip3')));
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

    test('no MCU ceiling exists, and the prompt says so', () async {
      // The VCU prompt names the model's ceiling. MCU has no blacklist rows,
      // and the operator must be told that rather than left with a gap where
      // the VCU gets a number — an absence of data is not a clean bill.
      final runner = _RecordingRunner(_dump(banner: 'SCOOTER_MCU_0001'));
      final c = await compatRunner(runner);
      String? shown;
      String? shownCeiling;

      await c.start(
        askMcuModel: (_) async => 'zt3',
        confirmUnidentified: (finding, ceiling) async {
          shown = finding;
          shownCeiling = ceiling;
          return false;
        },
      );

      expect(shown, contains('zt3 MCU you selected'));
      expect(shownCeiling, contains('no MCU version ceiling recorded'));
      // Never a version claim we cannot support.
      expect(shownCeiling, isNot(contains('known not to work')));
      expect(runner.wroteFlash, isFalse);
    });

    test('declaring GT3 is refused like a GT3 banner', () async {
      final runner = _RecordingRunner(_dump(banner: 'SCOOTER_MCU_0001'));
      final c = await compatRunner(runner);

      await c.start(askMcuModel: (_) async => 'gt3');

      expect(c.stage, StageState.fail);
      expect(c.sub, contains('GT3'));
      expect(runner.wroteFlash, isFalse);
    });

    test('the declared model packs MCU zips named from the identity', () async {
      // g3 MCU 1.5.0 is a known build, so declaring g3 identifies it and the
      // run reaches packing. 58436 ≡ 4 (mod 8) and sits under the 59388-byte
      // MCU slot-0 ceiling.
      final runner = _RecordingRunner(
        _dump(
          banner: 'SCOOTER_MCU_0001',
          versionValue: 0x150,
          zpPayloadLength: 58436,
        ),
      );
      final c = await compatRunner(runner);
      c.setCompatMakeZip3(true);

      await c.start(askMcuModel: (_) async => 'g3');

      expect(runner.wroteFlash, isTrue);
      // Same slice and format as VCU; the operator-declared model names the
      // files, which is the whole reason an MCU run can pack now.
      expect(zipNames(), [
        'g3_mcu_v1.5.0_compat_zip3.zip',
        'g3_mcu_v1.5.0_stock_zip3.zip',
      ]);
      // Round-trip the stock package: unpackV3 checks the compatible board, so
      // this also asserts the MCU tag is the generic x3_MCU_AT32 that SHU's
      // real packages use — not a per-model VCU-style tag.
      final dir = Directory(p.join(rootDir.path, 'compat'))
          .listSync()
          .whereType<Directory>()
          .firstWhere((d) => d.path.endsWith('_zips'));
      final bytes = File(
        p.join(dir.path, 'g3_mcu_v1.5.0_stock_zip3.zip'),
      ).readAsBytesSync();
      final pkg = PackV3.unpackV3(bytes, policy: Zip3UnpackPolicy.extract);
      expect(pkg.normalizedType, 'MCU');
      expect(pkg.format, Zip3Format.legacy);
      expect(pkg.firmware, hasLength(58436));
    });
  });
}
