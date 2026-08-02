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
      expect(
        Firmware.validateZip3Container(
          aboveLimit.path,
          enforceFlashSizeLimit: false,
        ).ok,
        isTrue,
      );
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

    test('flash ZIP import still rejects BLE and BMS', () {
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

    test('extraction accepts internally consistent BMS and BLE packages', () {
      for (final (type, length) in [('BMS', 64028), ('BLE', 500000)]) {
        final payload = Uint8List.fromList(
          List<int>.generate(length, (i) => (i * 31 + 7) & 0xff),
        );
        final zip = _zip3(payload, model: 'zt3', type: type);

        final unpacked = PackV3.unpackV3(zip, policy: Zip3UnpackPolicy.extract);

        expect(unpacked.model, 'zt3', reason: type);
        expect(unpacked.type, type, reason: type);
        expect(unpacked.firmware.length, greaterThanOrEqualTo(length));
      }
    });

    test('extraction rejects BMS/BLE with VCU compatible metadata', () {
      for (final type in ['BMS', 'BLE']) {
        final zip = _zip3(
          Uint8List.fromList(
            List<int>.generate(64028, (i) => (i * 31 + 7) & 0xff),
          ),
          model: 'zt3',
          type: type,
          compatible: const ['zt3_VCU_AT32'],
        );

        expect(
          () => PackV3.unpackV3(zip, policy: Zip3UnpackPolicy.extract),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Inconsistent JSON'),
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

    test('current zip3.2 shape passes both readers with exact plaintext', () {
      final payload = _payloadWithBanner('SCOOTER_VCU_xxU2');
      final zip = _zip32(payload, model: 'zt3', type: 'VCU');

      for (final policy in Zip3UnpackPolicy.values) {
        final unpacked = PackV3.unpackV3(zip, policy: policy);
        expect(unpacked.format, Zip3Format.rev2);
        expect(unpacked.model, 'zt3');
        expect(unpacked.type, 'VCU');
        expect(unpacked.source, 'FIRM.bin');
        expect(unpacked.firmware, payload);
        expect(unpacked.enforceModel, isNull);
        expect(unpacked.encryption, isNull);
      }
    });

    test('older schema2 scalar model shape remains readable', () {
      final payload = _payloadWithBanner('SCOOTER_VCU_xxU2');
      final zip = _zip32(
        payload,
        model: 'zt3',
        type: 'VCU',
        omitModels: true,
        scalarModel: 'zt3',
        enforceModel: true,
      );

      final unpacked = PackV3.unpackV3(zip);
      expect(unpacked.format, Zip3Format.rev2);
      expect(unpacked.model, 'zt3');
      expect(unpacked.enforceModel, isTrue);
      expect(unpacked.firmware, payload);
    });

    test('zip3.2 models must resolve to exactly one consistent model', () {
      final payload = _payloadWithBanner('SCOOTER_VCU_xxU2');
      for (final models in <List<String>>[
        [],
        ['zt3', 'g3'],
      ]) {
        expect(
          () => PackV3.unpackV3(
            _zip32(payload, model: 'zt3', type: 'VCU', models: models),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('exactly one model'),
            ),
          ),
        );
      }
      expect(
        () => PackV3.unpackV3(
          _zip32(
            payload,
            model: 'zt3',
            type: 'VCU',
            models: const ['zt3'],
            scalarModel: 'g3',
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('disagree'),
          ),
        ),
      );
    });

    test('zip3.2 requires plaintext-only payload and scalar MD5', () {
      final payload = _payloadWithBanner('SCOOTER_VCU_xxU2');
      expect(
        () => PackV3.unpackV3(
          _zip32(
            payload,
            model: 'zt3',
            type: 'VCU',
            md5Override: '00000000000000000000000000000000',
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('zip3.2 FIRM.bin failed its MD5'),
          ),
        ),
      );
      expect(
        () => PackV3.unpackV3(
          _zip32(payload, model: 'zt3', type: 'VCU', addEncryptedMember: true),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('must not contain encrypted'),
          ),
        ),
      );
    });

    test('archive preflight rejects excess members before extraction', () {
      final archive = Archive();
      for (var i = 0; i <= PackV3.maxArchiveMembers; i++) {
        archive.add(ArchiveFile.string('extra_$i.txt', 'x'));
      }
      final zip = Uint8List.fromList(ZipEncoder().encode(archive));
      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('the limit is ${PackV3.maxArchiveMembers}'),
          ),
        ),
      );
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
            contains('Legacy zip 3 FIRM.bin.enc failed its MD5'),
          ),
        ),
      );
      expect(
        () => PackV3.unpackV3(zip, policy: Zip3UnpackPolicy.extract),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('MD5'),
          ),
        ),
      );
    });

    test(
      'standalone Unpack inspects a valid package without writing',
      () async {
        SharedPreferences.setMockInitialValues({});
        final temp = Directory.systemTemp.createTempSync(
          'x3utils_unpack_pick_',
        );
        addTearDown(() => temp.deleteSync(recursive: true));
        final zipFile = File(p.join(temp.path, 'valid.zip'))
          ..writeAsBytesSync(
            _zip32(
              _payloadWithBanner('SCOOTER_VCU_xxU2'),
              model: 'zt3',
              type: 'VCU',
            ),
          );
        final controller = AppController();
        addTearDown(controller.dispose);

        controller.selectAction('make_zip3');
        controller.setZip3WorkspacePage(Zip3WorkspacePage.unpack);
        expect(controller.canStart, isFalse);

        final result = await controller.selectZip3ForUnpack(zipFile.path);

        expect(result.ok, isTrue);
        expect(
          result.message,
          'Ready to unpack zip 3.2 package test package (ZT3 VCU).',
        );
        expect(controller.unpackZip3Path, zipFile.path);
        expect(controller.unpackDisplayName, 'test package');
        expect(controller.unpackModel, 'zt3');
        expect(controller.unpackType, 'VCU');
        expect(controller.unpackPayloadLength, Firmware.slot0MinBytes);
        expect(controller.unpackFormatLabel, 'zip 3.2');
        expect(controller.unpackProtectionLabel, 'plaintext + MD5');
        expect(controller.unpackEnforceModel, isNull);
        expect(controller.unpackEncryption, isNull);
        expect(controller.unpackOutputName, 'zt3_vcu_valid.bin');
        expect(controller.canStart, isTrue);
        expect(temp.listSync().map((e) => p.basename(e.path)), ['valid.zip']);
      },
    );

    test('standalone Unpack accepts a large BLE package', () async {
      SharedPreferences.setMockInitialValues({});
      final temp = Directory.systemTemp.createTempSync('x3utils_unpack_ble_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final payload = Uint8List.fromList(
        List<int>.generate(500000, (i) => (i * 31 + 7) & 0xff),
      );
      final zipFile = File(p.join(temp.path, '2.1.12.zip'))
        ..writeAsBytesSync(_zip3(payload, model: 'zt3', type: 'BLE'));
      expect(zipFile.lengthSync(), greaterThan(Firmware.maxZip3Bytes));
      final controller = AppController();
      addTearDown(controller.dispose);

      controller.selectAction('make_zip3');
      controller.setZip3WorkspacePage(Zip3WorkspacePage.unpack);
      final result = await controller.selectZip3ForUnpack(zipFile.path);

      expect(result.ok, isTrue);
      expect(controller.unpackModel, 'zt3');
      expect(controller.unpackType, 'BLE');
      expect(controller.unpackPayloadLength, greaterThanOrEqualTo(500000));
      expect(controller.unpackOutputName, 'zt3_ble_2.1.12.bin');
      expect(controller.canStart, isTrue);
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
      'invalid slot bytes are rejected before an output path is created',
      () async {
        SharedPreferences.setMockInitialValues({});
        final temp = Directory.systemTemp.createTempSync(
          'x3utils_zip_prewrite_',
        );
        addTearDown(() {
          Firmware.setRoot(null);
          temp.deleteSync(recursive: true);
        });
        final payload = Uint8List.fromList(
          List<int>.generate(2000, (i) => (i * 31 + 7) & 0xff),
        );
        const banner = 'SCOOTER_VCU_xxU2';
        payload.setRange(0x400, 0x400 + banner.length, banner.codeUnits);
        final zipFile = File(p.join(temp.path, 'too-small.zip'))
          ..writeAsBytesSync(_zip32(payload, model: 'zt3', type: 'VCU'));
        final root = Directory(p.join(temp.path, 'root'))..createSync();
        final controller = AppController();
        addTearDown(controller.dispose);
        await Future<void>.delayed(Duration.zero);
        controller.setX3utilsRoot(root.path);
        controller.selectAction('flash_slot0');

        final result = await controller.loadSlotFirmwareFromZip(zipFile.path);

        expect(result.ok, isFalse);
        expect(result.message, contains('too small for Slot 0'));
        expect(controller.firmwarePath, isNull);
        expect(
          Directory(p.join(root.path, 'unpacked_zip3')).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'both slot-0 actions load zip3.2 without claiming a hardware match',
      () async {
        SharedPreferences.setMockInitialValues({});
        final temp = Directory.systemTemp.createTempSync('x3utils_zip_valid_');
        addTearDown(() => temp.deleteSync(recursive: true));
        final zipFile = File(p.join(temp.path, 'valid.zip'))
          ..writeAsBytesSync(
            _zip32(
              _payloadWithBanner('SCOOTER_VCU_xxU2'),
              model: 'zt3',
              type: 'VCU',
            ),
          );
        for (final action in ['flash_slot0', 'flash_only']) {
          final controller = AppController();
          addTearDown(() {
            final unpacked = controller.firmwarePath;
            if (unpacked != null && File(unpacked).existsSync()) {
              File(unpacked).deleteSync();
            }
            controller.dispose();
          });

          controller.selectAction(action);
          if (action == 'flash_only') {
            controller.setFlashOnlyScope(FlashOnlyScope.slot0);
          }
          final result = await controller.loadSlotFirmwareFromZip(zipFile.path);

          expect(result.ok, isTrue, reason: action);
          expect(
            result.message,
            'Loaded zip 3.2 package test package: '
            '${Firmware.slot0MinBytes} bytes. '
            'Package says: ZT3 · VCU.',
            reason: action,
          );
          expect(controller.firmwarePath, isNotNull, reason: action);
          expect(controller.firmwareInspection!.findings, isEmpty);
          expect(
            controller.heroEyebrow,
            action == 'flash_only' ? 'Compatibility warning' : 'Slot 0 only',
          );
        }
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

  test('ZIP3 Slice is strict while Pack accepts complete payload bins', () {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_zip3_split_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final fullBytes = Uint8List.fromList(
      List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
    );
    const fullBanner = 'SCOOTER_VCU_xxG3';
    fullBytes.setRange(
      0x1400,
      0x1400 + fullBanner.length,
      fullBanner.codeUnits,
    );
    final full = File(p.join(temp.path, 'full.bin'))
      ..writeAsBytesSync(fullBytes);
    final sliced = File(p.join(temp.path, 'sliced.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(58436, (i) => i & 0xff)),
      );
    final ble = File(p.join(temp.path, 'ble.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(
          List<int>.generate(1846188, (i) => (i * 17 + 3) & 0xff),
        ),
      );
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('make_zip3');
    expect(controller.zip3WorkspacePage, Zip3WorkspacePage.slice);
    expect(controller.zip3TypeOptions, ['VCU', 'MCU']);
    final rejected = controller.selectFirmwareBin(sliced.path);
    expect(rejected.ok, isFalse);
    expect(rejected.message, contains('Expected 131072 bytes'));
    expect(controller.selectFirmwareBin(full.path).ok, isTrue);

    controller.setZip3WorkspacePage(Zip3WorkspacePage.pack);
    expect(controller.firmwarePath, isNull);
    expect(controller.zip3TypeOptions, ['VCU', 'MCU', 'BMS', 'BLE']);
    final fullRejected = controller.selectFirmwareBin(full.path);
    expect(fullRejected.ok, isFalse);
    expect(fullRejected.message, contains('Use Slice instead of Pack'));
    expect(controller.selectFirmwareBin(sliced.path).ok, isTrue);
    expect(controller.selectFirmwareBin(ble.path).ok, isTrue);
    controller.setZip3Type('BLE');
    controller.setZip3Model('g3');

    controller.setZip3WorkspacePage(Zip3WorkspacePage.unpack);
    expect(controller.firmwarePath, isNull);
    expect(controller.zip3Type, isNull);
    controller.setZip3WorkspacePage(Zip3WorkspacePage.slice);
    expect(controller.zip3TypeOptions, ['VCU', 'MCU']);
  });

  test('ZIP3 Slice and Pack do not inherit OpenOCD path restrictions', () {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_zip3_paths_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final offlineDir = Directory(p.join(temp.path, 'Prüfung{offline}'))
      ..createSync();
    final full = File(p.join(offlineDir.path, 'full.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(
          List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
        ),
      );
    final payload = File(p.join(offlineDir.path, 'payload.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(58436, (i) => i & 0xff)),
      );
    final controller = AppController();
    addTearDown(controller.dispose);

    expect(Firmware.validateOpenOcdPath(full.path).ok, isFalse);
    controller.selectAction('make_zip3');
    expect(controller.selectFirmwareBin(full.path).ok, isTrue);

    controller.setZip3WorkspacePage(Zip3WorkspacePage.pack);
    expect(controller.selectFirmwareBin(payload.path).ok, isTrue);
  });

  test('ZIP3 Pack rechecks declared payload identity at Start', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_zip3_pack_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final payload = File(p.join(temp.path, 'bannerless.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(58436, (i) => i & 0xff)),
      );
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('make_zip3');
    controller.setZip3WorkspacePage(Zip3WorkspacePage.pack);
    expect(controller.selectFirmwareBin(payload.path).ok, isTrue);
    controller.setZip3Type('VCU');
    controller.setZip3Model('g3');
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(controller.heroMessage, contains('declared VCU type requires'));
  });

  test('ZIP3 Slice rechecks the 128 KB size at Start', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_zip3_resize_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final full = File(p.join(temp.path, 'full.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(
          List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
        ),
      );
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('make_zip3');
    expect(controller.selectFirmwareBin(full.path).ok, isTrue);
    controller.setZip3Type('VCU');
    controller.setZip3Model('g3');

    full.writeAsBytesSync(
      Uint8List.fromList(List<int>.generate(58436, (i) => i & 0xff)),
    );
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(controller.failureNeedsInput, isTrue);
    expect(controller.heroMessage, contains('Expected 131072 bytes'));
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
  final expectedBoard = switch (type.toUpperCase()) {
    'MCU' => 'x3_MCU_AT32',
    'BMS' => 'x3_BMS',
    'BLE' => '${model.toLowerCase()}_BLE',
    _ => '${model.toLowerCase()}_VCU_AT32',
  };
  final boards = compatible ?? [expectedBoard];
  final info = <String, dynamic>{
    'schemaVersion': 1,
    'firmware': <String, dynamic>{
      'displayName': 'test package',
      'model': model,
      'type': type,
      'enforceModel': true,
      'encryption': 'encrypted',
      'compatible': boards,
      'md5': <String, String>{'enc': md5Override ?? PackV3.md5Hex(encrypted)},
    },
  };
  final archive = Archive()
    ..add(ArchiveFile.bytes('FIRM.bin.enc', encrypted))
    ..add(ArchiveFile.string('info.json', jsonEncode(info)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _zip32(
  Uint8List payload, {
  required String model,
  required String type,
  List<String>? models,
  bool omitModels = false,
  String? scalarModel,
  bool? enforceModel,
  String? md5Override,
  bool addEncryptedMember = false,
}) {
  final expectedBoard = switch (type.toUpperCase()) {
    'MCU' => 'x3_MCU_AT32',
    'BMS' => 'x3_BMS',
    'BLE' => '${model.toLowerCase()}_BLE',
    _ => '${model.toLowerCase()}_VCU_AT32',
  };
  final firmware = <String, dynamic>{'displayName': 'test package'};
  if (!omitModels) firmware['models'] = models ?? [model];
  if (scalarModel != null) firmware['model'] = scalarModel;
  if (enforceModel != null) firmware['enforceModel'] = enforceModel;
  firmware
    ..['type'] = type.toLowerCase()
    ..['compatible'] = [expectedBoard]
    ..['md5'] = md5Override ?? PackV3.md5Hex(payload);
  final info = <String, dynamic>{'schemaVersion': 2, 'firmware': firmware};
  final archive = Archive()
    ..add(ArchiveFile.string('info.json', jsonEncode(info)))
    ..add(ArchiveFile.bytes('FIRM.bin', payload));
  if (addEncryptedMember) {
    archive.add(ArchiveFile.bytes('FIRM.bin.enc', [1, 2, 3, 4]));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
