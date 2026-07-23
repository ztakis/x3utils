import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/ninebot_tea.dart';
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';
import 'package:x3utils_flutter/models.dart';

void main() {
  group('firmware source size gates', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('x3utils_fw_'));
    tearDown(() => temp.deleteSync(recursive: true));

    File firmwareFile(String name, int length) => File(p.join(temp.path, name))
      ..writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(length, (i) => i & 0xff)),
      );

    test('full image remains exactly 128 KB', () {
      expect(
        Firmware.validate(
          firmwareFile('full.bin', Firmware.expectedSize).path,
        ).ok,
        isTrue,
      );
      expect(
        Firmware.validate(
          firmwareFile('short.bin', Firmware.expectedSize - 1).path,
        ).ok,
        isFalse,
      );
    });

    test('slot image accepts only the configured inclusive window', () {
      expect(
        Firmware.validateSlot(
          firmwareFile('min.bin', Firmware.slot0MinBytes).path,
        ).ok,
        isTrue,
      );
      expect(
        Firmware.validateSlot(
          firmwareFile('max.bin', Firmware.slot0MaxBytes).path,
        ).ok,
        isTrue,
      );
      final tooSmall = Firmware.slot0MinBytes - 1;
      final smallResult = Firmware.validateSlot(
        firmwareFile('too-small.bin', tooSmall).path,
      );
      expect(smallResult.ok, isFalse);
      expect(
        smallResult.message,
        'This file is too small for Slot 0 '
        '($tooSmall bytes; minimum ${Firmware.slot0MinBytes}).',
      );
      final tooLarge = Firmware.slot0MaxBytes + 1;
      final largeResult = Firmware.validateSlot(
        firmwareFile('too-big.bin', tooLarge).path,
      );
      expect(largeResult.ok, isFalse);
      expect(
        largeResult.message,
        'This file is too large for Slot 0 '
        '($tooLarge bytes; maximum ${Firmware.slot0MaxBytes}).',
      );
    });

    test('ZIP3 container is rejected before reading above 70 KiB', () {
      final atLimit = File(p.join(temp.path, 'limit.zip'))
        ..writeAsBytesSync(Uint8List(Firmware.maxZip3Bytes));
      final aboveLimit = File(p.join(temp.path, 'large.zip'))
        ..writeAsBytesSync(Uint8List(Firmware.maxZip3Bytes + 1));

      expect(Firmware.validateZip3Container(atLimit.path).ok, isTrue);
      final rejected = Firmware.validateZip3Container(aboveLimit.path);
      expect(rejected.ok, isFalse);
      expect(rejected.message, contains('too large'));
    });
  });

  group('ZIP3 identity policy', () {
    test('every ZIP import rejects an unsupported model', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'other',
        type: 'VCU',
      );

      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            equals(
              'This package is for OTHER. '
              'x3utils supports ZT3, G3, GT3, and F3 only.',
            ),
          ),
        ),
      );
    });

    test('every ZIP import rejects BLE and BMS', () {
      for (final type in ['BLE', 'BMS']) {
        final zip = _zip3(
          _payloadWithBanner('SCOOTER_MCU_0001'),
          model: 'zt3',
          type: type,
        );
        expect(
          () => PackV3.unpackV3(zip),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              equals(
                'This package contains $type firmware. '
                'x3utils flashes only VCU/MCU firmware.',
              ),
            ),
          ),
          reason: type,
        );
      }
    });

    test('a consistent supported package passes its internal checks', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'zt3',
        type: 'VCU',
      );

      final unpacked = PackV3.unpackV3(zip);
      expect(unpacked.model, 'zt3');
      expect(unpacked.type, 'VCU');
    });

    test('every ZIP import rejects unsupported banner codes', () {
      for (final banner in ['SCOOTER_VCU_ZZZZ', 'SCOOTER_MCU_9999']) {
        final zip = _zip3(
          _payloadWithBanner(banner),
          model: 'zt3',
          type: banner.contains('_MCU_') ? 'MCU' : 'VCU',
        );
        expect(
          () => PackV3.unpackV3(zip),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Unsupported firmware banner'),
            ),
          ),
          reason: banner,
        );
      }
    });

    test('rejects a package model that disagrees with its payload', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'g3',
        type: 'VCU',
      );

      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'The JSON says G3 VCU, but the firmware banner says ZT3 VCU.',
          ),
        ),
      );
    });

    test('rejects a JSON type that disagrees with its payload banner', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_MCU_0001'),
        model: 'zt3',
        type: 'VCU',
      );
      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'The JSON says VCU, but the firmware banner says MCU.',
          ),
        ),
      );
    });

    test('rejects a missing compatible-board list', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'zt3',
        type: 'VCU',
        compatible: const [],
      );

      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'info.json has no valid firmware.compatible list.',
          ),
        ),
      );
    });

    test('rejects a compatible board that disagrees with the model', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'zt3',
        type: 'VCU',
        compatible: const ['g3_VCU_AT32'],
      );

      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Inconsistent JSON, "model" : ZT3 VCU, '
                '"compatible" : g3_VCU_AT32.',
          ),
        ),
      );
    });

    test('MD5 integrity remains mandatory for every ZIP import', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'zt3',
        type: 'VCU',
        md5Override: '00000000000000000000000000000000',
      );

      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('MD5'),
          ),
        ),
      );
    });

    test('Flash Only controller rejects a bad ZIP before loading it', () async {
      SharedPreferences.setMockInitialValues({});
      final temp = Directory.systemTemp.createTempSync('x3utils_zip_report_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final zipFile = File(p.join(temp.path, 'mislabeled.zip'))
        ..writeAsBytesSync(
          _zip3(
            _payloadWithBanner('SCOOTER_VCU_xxU2'),
            model: 'other',
            type: 'VCU',
          ),
        );
      final controller = AppController();
      addTearDown(() {
        final unpacked = controller.firmwarePath;
        if (unpacked != null && File(unpacked).existsSync()) {
          File(unpacked).deleteSync();
        }
        controller.dispose();
      });

      controller.selectAction('flash_only');
      controller.setFlashOnlyScope(FlashOnlyScope.slot0);
      final result = await controller.loadSlotFirmwareFromZip(zipFile.path);

      expect(result.ok, isFalse);
      expect(result.message, contains('supports ZT3, G3, GT3, and F3 only'));
      expect(controller.firmwarePath, isNull);
      expect(controller.firmwareInspection, isNull);
    });

    test(
      'Flash Only loads a valid ZIP but does not claim a hardware match',
      () async {
        SharedPreferences.setMockInitialValues({});
        final temp = Directory.systemTemp.createTempSync('x3utils_zip_valid_');
        addTearDown(() => temp.deleteSync(recursive: true));
        final zipFile = File(p.join(temp.path, 'valid.zip'))
          ..writeAsBytesSync(
            _zip3(
              _payloadWithBanner('SCOOTER_VCU_xxU2'),
              model: 'zt3',
              type: 'VCU',
            ),
          );
        final controller = AppController();
        addTearDown(() {
          final unpacked = controller.firmwarePath;
          if (unpacked != null && File(unpacked).existsSync()) {
            File(unpacked).deleteSync();
          }
          controller.dispose();
        });

        controller.selectAction('flash_only');
        controller.setFlashOnlyScope(FlashOnlyScope.slot0);
        final result = await controller.loadSlotFirmwareFromZip(zipFile.path);

        expect(result.ok, isTrue);
        expect(controller.firmwarePath, isNotNull);
        expect(controller.firmwareInspection!.findings, isEmpty);
        expect(controller.heroEyebrow, 'Compatibility warning');
      },
    );
  });

  test('Flash Only scope defaults to full and clears firmware on change', () {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('flash_only');
    expect(controller.flashOnlyScope, FlashOnlyScope.fullImage);
    expect(controller.isSlotAction, isFalse);

    controller.setFirmware('selected.bin');
    controller.setFlashOnlyScope(FlashOnlyScope.slot0);
    expect(controller.isSlotAction, isTrue);
    expect(controller.firmwarePath, isNull);
    expect(controller.firmwareInspection, isNull);
  });

  test('Flash Only retains findings and switches the idle eyebrow', () {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_inspection_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final firmware = File(p.join(temp.path, 'bannerless.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(
          List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
        ),
      );
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('flash_only');
    expect(controller.selectFirmwareBin(firmware.path).ok, isTrue);

    expect(controller.heroEyebrow, 'Compatibility warning');
    expect(
      controller.firmwareInspection!.findings.map((item) => item.code),
      contains('banner_missing'),
    );
    expect(controller.firmwareInspection!.zpValue, contains('No trustworthy'));
  });

  test('Flash Only refreshes findings from the current bytes', () {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_refresh_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bytes = Uint8List.fromList(
      List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
    );
    const supported = 'SCOOTER_VCU_xxG3';
    bytes.setRange(0x1400, 0x1410, ascii.encode(supported));
    final firmware = File(p.join(temp.path, 'firmware.bin'))
      ..writeAsBytesSync(bytes);
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('flash_only');
    expect(controller.selectFirmwareBin(firmware.path).ok, isTrue);
    expect(
      controller.firmwareInspection!.findings.map((item) => item.code),
      isNot(contains('banner_unsupported')),
    );

    const unsupported = 'SCOOTER_VCU_ZZZZ';
    bytes.setRange(0x1400, 0x1410, ascii.encode(unsupported));
    firmware.writeAsBytesSync(bytes);

    expect(controller.refreshFlashOnlyInspection().ok, isTrue);
    expect(
      controller.firmwareInspection!.findings.map((item) => item.code),
      contains('banner_unsupported'),
    );
  });

  test('idle hero presents the selected firmware identity', () {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('make_zip3');
    controller.setFirmware(
      'dump.bin',
      note: 'Firmware says: G3 · VCU',
      warn: true,
    );

    expect(controller.heroTitle, 'Complete package identity');
    expect(controller.heroMessage, 'Firmware says: G3 · VCU');
    expect(controller.heroMessageWarn, isTrue);

    controller.setZip3Type('VCU');
    controller.setZip3Model('g3');
    expect(controller.heroTitle, 'Ready to start');
    expect(controller.heroMessage, 'Firmware says: G3 · VCU');
  });

  test('input failure returns to setup instead of rerunning', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_retry_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final dump = File(p.join(temp.path, 'invalid_dump.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(
          List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
        ),
      );
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('make_zip3');
    controller.setFirmware(dump.path);
    controller.setZip3Type('VCU');
    controller.setZip3Model('g3');

    await controller.start();
    expect(controller.stage, StageState.fail);
    expect(controller.failureNeedsInput, isTrue);
    expect(controller.failurePrimaryLabel, 'Change input');

    await controller.retry();
    expect(controller.stage, StageState.idle);
    expect(controller.failureNeedsInput, isFalse);
  });

  test('guarded flash rejects a file changed after selection', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_changed_fw_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bytes = Uint8List.fromList(
      List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
    );
    const banner = 'SCOOTER_VCU_xxG3';
    bytes.setRange(0x1400, 0x1400 + banner.length, banner.codeUnits);
    final firmware = File(p.join(temp.path, 'firmware.bin'))
      ..writeAsBytesSync(bytes);
    final inertRunner = OpenOcdRunner(
      OpenOcdPaths('/not-a-real-openocd', '/not-a-real-scripts'),
    );
    final controller = AppController(runner: inertRunner);
    addTearDown(controller.dispose);

    controller.selectAction('flash_backup');
    expect(controller.selectFirmwareBin(firmware.path).ok, isTrue);

    bytes[0x2000] ^= 0x01;
    firmware.writeAsBytesSync(bytes);
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(controller.failureNeedsInput, isTrue);
    expect(controller.failurePrimaryLabel, 'Change firmware');
    expect(controller.heroMessage, contains('changed on disk'));
    expect(
      controller.console.any((line) => line.contains('> openocd')),
      isFalse,
    );
  });

  testWidgets('flash eyebrow changes to Validating before the result', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_flash_eyebrow_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final firmware = File(p.join(temp.path, 'firmware.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(
          List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
        ),
      );
    final controller = AppController(runner: _SuccessfulFlashRunner());
    addTearDown(controller.dispose);

    controller.selectAction('flash_only');
    expect(controller.selectFirmwareBin(firmware.path).ok, isTrue);

    final started = controller.start();
    await tester.pump();

    expect(controller.stage, StageState.run);
    expect(controller.heroEyebrow, 'Validating');

    await tester.pump(const Duration(seconds: 3));
    await started;
    expect(controller.stage, StageState.ok);
    expect(controller.heroEyebrow, startsWith('Took '));
  });
}

class _SuccessfulFlashRunner extends OpenOcdRunner {
  _SuccessfulFlashRunner()
    : super(OpenOcdPaths('/not-a-real-openocd', '/not-a-real-scripts'));

  @override
  Future<OpenOcdResult> run(
    List<String> args,
    void Function(String line) onLine,
  ) async {
    final evidence = OpenOcdEvidence();
    for (final line in ['wrote 131072 bytes', 'verified 131072 bytes']) {
      evidence.record(line);
      onLine(line);
    }
    return OpenOcdResult(0, evidence);
  }
}

Uint8List _payloadWithBanner(String banner) {
  final bytes = Uint8List.fromList(
    List<int>.generate(Firmware.slot0MinBytes, (i) => i & 0xff),
  );
  bytes.setRange(0x400, 0x410, ascii.encode(banner));
  return bytes;
}

Uint8List _zip3(
  Uint8List payload, {
  required String model,
  required String type,
  String? md5Override,
  List<String>? compatible,
}) {
  final encrypted = NinebotTea().encrypt(payload);
  final boards =
      compatible ??
      [
        type.toUpperCase() == 'MCU'
            ? 'x3_MCU_AT32'
            : '${model.toLowerCase()}_VCU_AT32',
      ];
  final info = <String, dynamic>{
    'schemaVersion': 1,
    'firmware': <String, dynamic>{
      'displayName': 'test package',
      'model': model,
      'type': type,
      'compatible': boards,
      'md5': <String, String>{'enc': md5Override ?? PackV3.md5Hex(encrypted)},
    },
  };
  final archive = Archive()
    ..add(ArchiveFile.bytes('FIRM.bin.enc', encrypted))
    ..add(ArchiveFile.string('info.json', jsonEncode(info)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
