import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';
import 'package:x3utils_flutter/engine/zp_extract.dart';

// Deterministic in-memory dumps for the offline "Make zip3" engine. No hardware,
// no mirror files: a synthetic 128 KB image with a slot-0 payload at 0x1000, its
// banner at 0x1400, and a "ZP" length record at 0x1F800. Payload lengths are
// ≡4 (mod 8), which keeps the legacy NinebotTEA alternative byte-exact.
// Zip3.2 stores plaintext and has no modulo restriction. Package identity comes
// from the operator
// (type/model args), not from the dump — the dump only supplies the payload.

const _g3Vcu = 'SCOOTER_VCU_xxG3';
const _zt3Vcu = 'SCOOTER_VCU_xxU2';
const _mcu = 'SCOOTER_MCU_0001';
const _zpError =
    'Make zip3 stopped: this dump has no trustworthy BLE firmware-length '
    'record, so x3utils cannot safely determine the exact payload. This '
    'optional tool requires a fresh full backup taken immediately after a BLE '
    'flash, before any ST-Link firmware write, and refuses rather than guessing.';
const _shuKeyError =
    'This dump has neither the default SHU key nor a blank key. It '
    'is usually OEM/stock firmware and may not be BLE-flashable, so Make zip3 '
    'was stopped. Some older repo firmware may also be rejected by this safety '
    'check.';

/// A valid slot-0 payload length inside the window and ≡4 (mod 8).
const _len = 51204;

/// The default SHU firmware key at 0x1420 (matches CompatPatch.signature) — its
/// presence marks a repo/SHU-compatible dump, the only kind Make zip3 accepts.
final _defaultKey = <int>[
  0xFE, 0x80, 0x1C, 0xB2, 0xD1, 0xEF, 0x41, 0xA6, //
  0xA4, 0x17, 0x31, 0xF5, 0xA0, 0x68, 0x24, 0xF0,
];

Uint8List _dump({
  String? banner = _g3Vcu,
  int payloadLen = _len,
  int? encLenOverride,
  bool omitZp = false,
  List<int>? keyAt1420, // 16 bytes at 0x1420; default = the SHU key (repo fw)
  Map<int, int> extraZp = const {}, // extra ZP records: offset → encoded length
}) {
  final b = Uint8List(131072);
  // Vary the payload body so it is never a single repeated byte.
  for (var i = 0x1000; i < 0x1000 + payloadLen; i++) {
    b[i] = (i * 31 + 7) & 0xFF;
  }
  if (banner != null) {
    b.setRange(0x1400, 0x1400 + banner.length, banner.codeUnits);
  }
  // The firmware key region — repo firmware by default so the gate lets it pass.
  b.setRange(0x1420, 0x1420 + 16, keyAt1420 ?? _defaultKey);
  void zpRecord(int off, int encLen) {
    b[off] = 0x5A; // 'Z'
    b[off + 1] = 0x50; // 'P'
    final o = off + 8;
    b[o] = encLen & 0xFF;
    b[o + 1] = (encLen >> 8) & 0xFF;
    b[o + 2] = (encLen >> 16) & 0xFF;
    b[o + 3] = (encLen >> 24) & 0xFF;
  }

  if (!omitZp) {
    zpRecord(0x1F800, encLenOverride ?? (payloadLen + 4));
  }
  extraZp.forEach(zpRecord);
  return b;
}

/// The MCU banner as it appears in a sliced slot bin (same string, 0x400).
const _mcuSlot = _mcu;

/// A deterministic complete slot-0 payload with its banner at 0x400.
Uint8List _slotBin({int len = _len, String? banner = _g3Vcu}) {
  final b = Uint8List(len);
  for (var i = 0; i < len; i++) {
    b[i] = (i * 31 + 7) & 0xFF;
  }
  if (banner != null) {
    b.setRange(0x400, 0x400 + banner.length, banner.codeUnits);
  }
  return b;
}

Map<String, dynamic> _fw(Uint8List zip) {
  final a = ZipDecoder().decodeBytes(zip);
  final info = jsonDecode(utf8.decode(a.findFile('info.json')!.content));
  return (info as Map<String, dynamic>)['firmware'] as Map<String, dynamic>;
}

void main() {
  group('standalone unpack output', () {
    test('uses the package display name and adds .bin automatically', () {
      expect(
        Firmware.defaultUnpackedFilename(
          model: 'zt3',
          type: 'VCU',
          sourceFilename: '1.5.15 (Compat).zip',
        ),
        'zt3_vcu_1.5.15_Compat.bin',
      );
      expect(Firmware.normalizeUnpackedFilename('edited'), 'edited.bin');
      expect(Firmware.normalizeUnpackedFilename('edited.BIN'), 'edited.BIN');
    });

    test('refuses path components and invalid filenames', () {
      expect(Firmware.validateUnpackedFilename('firmware').ok, isTrue);
      expect(Firmware.validateUnpackedFilename('firmware.bin').ok, isTrue);
      expect(Firmware.validateUnpackedFilename('../firmware').ok, isFalse);
      expect(Firmware.validateUnpackedFilename(r'folder\firmware').ok, isFalse);
      expect(Firmware.validateUnpackedFilename('CON').ok, isFalse);
    });

    test('validates decrypted slot bytes before writing output', () {
      expect(
        Firmware.validateSlotBytes(
          List<int>.generate(_len, (i) => i & 0xFF),
        ).ok,
        isTrue,
      );
      expect(
        Firmware.validateSlotBytes(List<int>.filled(_len, 0xFF)).ok,
        isFalse,
      );
      expect(Firmware.validateSlotBytes(List<int>.filled(100, 1)).ok, isFalse);
    });
  });

  group('Zp.payloadFromDump', () {
    test('extracts the exact slot-0 payload named by the ZP record', () {
      final dump = _dump();
      final payload = Zp.payloadFromDump(dump);
      expect(payload.length, _len);
      expect(payload.first, dump[0x1000]);
      expect(payload.last, dump[0x1000 + _len - 1]);
    });

    test('fail-closed: missing ZP record', () {
      expect(
        () => Zp.payloadFromDump(_dump(omitZp: true)),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', _zpError),
        ),
      );
    });

    test('fail-closed: len=0 (naive read would be negative)', () {
      expect(
        () => Zp.payloadFromDump(_dump(encLenOverride: 0)),
        throwsFormatException,
      );
    });

    test('fail-closed: payload length not ≡4 (mod 8)', () {
      // encLen 51210 → payloadLen 51206, 51206 % 8 == 6.
      expect(
        () => Zp.payloadFromDump(_dump(encLenOverride: 51210)),
        throwsFormatException,
      );
    });

    test('fail-closed: below the slot-0 window', () {
      // encLen 51200 → payloadLen 51196 (≡4 mod 8) but < 51200.
      expect(
        () => Zp.payloadFromDump(_dump(encLenOverride: 51200)),
        throwsFormatException,
      );
    });

    test('fail-closed: above the slot-0 window', () {
      // encLen 65544 → payloadLen 65540 (≡4 mod 8) but > 65536.
      expect(
        () => Zp.payloadFromDump(_dump(encLenOverride: 65544)),
        throwsFormatException,
      );
    });

    test('fail-closed: dump smaller than a full image', () {
      expect(() => Zp.payloadFromDump(Uint8List(60000)), throwsFormatException);
    });

    test('authoritative 0x1F800 record beats an earlier plausible decoy', () {
      // Decoy at 0x1F100 names a different guard-passing length (51212); the
      // real record at 0x1F800 must win regardless of scan order.
      final dump = _dump(extraZp: {0x1F100: 51216});
      expect(Zp.payloadFromDump(dump).length, _len);
    });

    test('guard-failing decoy never interferes', () {
      // 12346 → payload 12342, 12342 % 8 == 6: the decoy fails the guards.
      final dump = _dump(extraZp: {0x1F100: 12346});
      expect(Zp.payloadFromDump(dump).length, _len);
    });

    test('a single relocated record is accepted by the scan fallback', () {
      final dump = _dump(omitZp: true, extraZp: {0x1F300: _len + 4});
      expect(Zp.payloadFromDump(dump).length, _len);
    });

    test('fail-closed: conflicting relocated records refuse', () {
      final dump = _dump(
        omitZp: true,
        extraZp: {0x1F100: 51208, 0x1F300: 51216},
      );
      expect(
        () => Zp.payloadFromDump(dump),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('conflicting ZP length records'),
          ),
        ),
      );
    });
  });

  group('PackV3.detect (dropdown preselect)', () {
    test('VCU banner preselects both type and model', () {
      final d = PackV3.detect(_dump(banner: _g3Vcu));
      expect(d.type, 'VCU');
      expect(d.model, 'g3');
    });

    test('MCU banner preselects the type but NOT the model', () {
      final d = PackV3.detect(_dump(banner: _mcu));
      expect(d.type, 'MCU');
      expect(d.model, isNull); // MCU carries no model identity
    });

    test('unknown VCU code preselects the type only', () {
      final d = PackV3.detect(_dump(banner: 'SCOOTER_VCU_ZZZZ'));
      expect(d.type, 'VCU');
      expect(d.model, isNull);
    });

    test('no banner: nothing to preselect', () {
      final d = PackV3.detect(_dump(banner: null));
      expect(d.type, isNull);
      expect(d.model, isNull);
    });
  });

  group('PackV3.buildZip3FromDump (operator-declared identity)', () {
    test('VCU: rev2 is default with the specified member/metadata shape', () {
      final r = PackV3.buildZip3FromDump(
        _dump(banner: _g3Vcu),
        type: 'VCU',
        model: 'g3',
        enforceModel: true,
      );
      expect(r.model, 'g3');
      expect(r.type, 'VCU');
      expect(r.payloadLength, _len);
      expect(r.format, Zip3Format.rev2);

      final a = ZipDecoder().decodeBytes(r.zipBytes);
      expect(a.files.map((file) => file.name), ['info.json', 'FIRM.bin']);
      expect(a.findFile('FIRM.bin.enc'), isNull);
      expect(a.findFile('info.json'), isNotNull);
      expect(a.findFile('FIRM.bin'), isNotNull);

      final fw = _fw(r.zipBytes);
      expect(fw.keys, ['displayName', 'models', 'type', 'compatible', 'md5']);
      expect(fw['models'], ['g3']);
      expect(fw['type'], 'vcu');
      expect(fw.containsKey('enforceModel'), isFalse);
      expect(fw.containsKey('encryption'), isFalse);
      expect(fw['compatible'], ['g3_VCU_AT32']);

      final plain = a.findFile('FIRM.bin')!.content as List<int>;
      expect(fw['md5'], crypto.md5.convert(plain).toString());
    });

    test('MCU: concrete operator model, generic x3_MCU_AT32 board', () {
      final r = PackV3.buildZip3FromDump(
        _dump(banner: _mcu),
        type: 'MCU',
        model: 'g3',
        enforceModel: true,
      );
      expect(r.type, 'MCU');
      expect(r.model, 'g3');
      expect(_fw(r.zipBytes)['compatible'], ['x3_MCU_AT32']);
    });

    test('legacy alternative retains enforceModel and encryption', () {
      final r = PackV3.buildZip3FromDump(
        _dump(),
        type: 'VCU',
        model: 'g3',
        enforceModel: false,
        format: Zip3Format.legacy,
      );
      final fw = _fw(r.zipBytes);
      expect(r.format, Zip3Format.legacy);
      expect(fw['enforceModel'], false);
      expect(fw['encryption'], 'encrypted');
      final unpacked = PackV3.unpackV3(r.zipBytes);
      expect(unpacked.format, Zip3Format.legacy);
      expect(unpacked.firmware, Zp.payloadFromDump(_dump()));
    });

    test('default displayName is <model>_<TYPE>', () {
      final r = PackV3.buildZip3FromDump(
        _dump(),
        type: 'VCU',
        model: 'g3',
        enforceModel: true,
      );
      expect(r.displayName, 'g3_VCU');
    });

    test('operator displayName overrides the default', () {
      final r = PackV3.buildZip3FromDump(
        _dump(),
        type: 'VCU',
        model: 'g3',
        enforceModel: true,
        displayName: '1.5.15 (Compat)',
      );
      expect(r.displayName, '1.5.15 (Compat)');
      expect(_fw(r.zipBytes)['displayName'], '1.5.15 (Compat)');
    });

    test('round-trips: unpackV3 recovers the exact packed payload', () {
      final dump = _dump(banner: _g3Vcu);
      final expected = Zp.payloadFromDump(dump);
      final r = PackV3.buildZip3FromDump(
        dump,
        type: 'VCU',
        model: 'g3',
        enforceModel: true,
      );
      final back = PackV3.unpackV3(r.zipBytes);
      expect(back.firmware, expected);
      expect(back.model, 'g3');
      expect(back.type, 'VCU');
    });

    test('rejects an unsupported type/model selection', () {
      expect(
        () => PackV3.buildZip3FromDump(
          _dump(),
          type: 'BLE',
          model: 'g3',
          enforceModel: true,
        ),
        throwsFormatException,
      );
      expect(
        () => PackV3.buildZip3FromDump(
          _dump(),
          type: 'VCU',
          model: 'nope',
          enforceModel: true,
        ),
        throwsFormatException,
      );
    });

    test('propagates the ZP fail-closed guard', () {
      expect(
        () => PackV3.buildZip3FromDump(
          _dump(omitZp: true),
          type: 'VCU',
          model: 'g3',
          enforceModel: true,
        ),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', _zpError),
        ),
      );
    });

    test('zt3 VCU packs on its own board', () {
      final r = PackV3.buildZip3FromDump(
        _dump(banner: _zt3Vcu),
        type: 'VCU',
        model: 'zt3',
        enforceModel: true,
      );
      expect(_fw(r.zipBytes)['compatible'], ['zt3_VCU_AT32']);
    });

    group('SHU key gate (repo-only)', () {
      test('default SHU key at 0x1420 packs', () {
        final r = PackV3.buildZip3FromDump(
          _dump(keyAt1420: _defaultKey),
          type: 'VCU',
          model: 'g3',
          enforceModel: true,
        );
        expect(r.payloadLength, _len);
      });

      test('blank (0xFF) 0x1420 — newer repo default — packs', () {
        final r = PackV3.buildZip3FromDump(
          _dump(keyAt1420: List.filled(16, 0xFF)),
          type: 'VCU',
          model: 'g3',
          enforceModel: true,
        );
        expect(r.payloadLength, _len);
      });

      test('OEM production key at 0x1420 is refused', () {
        expect(
          () => PackV3.buildZip3FromDump(
            _dump(keyAt1420: List.filled(16, 0xAB)),
            type: 'VCU',
            model: 'g3',
            enforceModel: true,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              _shuKeyError,
            ),
          ),
        );
      });
    });
  });

  group('PackV3.validatePayloadForPack', () {
    test('rejects a full 128 KB controller dump and points to Slice', () {
      expect(
        () => PackV3.validatePayloadForPack(_dump()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Use Slice instead of Pack'),
          ),
        ),
      );
    });

    test(
      'legacy rejects a payload that would gain NinebotTEA zero padding',
      () {
        expect(
          () => PackV3.validatePayloadForPack(
            _slotBin(len: _len + 1),
            format: Zip3Format.legacy,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('exact NinebotTEA round trip'),
            ),
          ),
        );
      },
    );

    test('rev2 accepts a payload with no NinebotTEA modulo shape', () {
      expect(
        () => PackV3.validatePayloadForPack(_slotBin(len: _len + 1)),
        returnsNormally,
      );
    });

    test('uses the detected VCU and MCU physical ceilings', () {
      final cases = [
        (
          payload: _slotBin(len: Firmware.slot0MaxPayloadVcu + 8),
          type: 'VCU',
          max: Firmware.slot0MaxPayloadVcu,
        ),
        (
          payload: _slotBin(
            len: Firmware.slot0MaxPayloadMcu + 8,
            banner: _mcuSlot,
          ),
          type: 'MCU',
          max: Firmware.slot0MaxPayloadMcu,
        ),
      ];
      for (final item in cases) {
        expect(
          () => PackV3.validatePayloadForPack(item.payload),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('${item.type} payload is'),
            ),
          ),
          reason: '${item.type} ceiling ${item.max}',
        );
      }
    });

    test('rejects unsupported, missing, and contradictory banner evidence', () {
      final cases = [
        (
          payload: _slotBin(banner: 'SCOOTER_VCU_BAD!'),
          type: null,
          model: null,
          message: 'Unsupported VCU/MCU firmware banner',
        ),
        (
          payload: _slotBin(banner: null),
          type: 'VCU',
          model: 'g3',
          message: 'declared VCU type requires',
        ),
        (
          payload: _slotBin(),
          type: 'BLE',
          model: 'g3',
          message: 'JSON says BLE',
        ),
        (
          payload: _slotBin(),
          type: 'VCU',
          model: 'zt3',
          message: 'JSON says ZT3 VCU',
        ),
      ];
      for (final item in cases) {
        expect(
          () => PackV3.validatePayloadForPack(
            item.payload,
            type: item.type,
            model: item.model,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(item.message),
            ),
          ),
          reason: item.message,
        );
      }
    });
  });

  group('PackV3.buildZip3FromPayload', () {
    test(
      'round-trips all supported component types with corpus board names',
      () {
        final cases = [
          (type: 'VCU', model: 'g3', board: 'g3_VCU_AT32', payload: _slotBin()),
          (
            type: 'MCU',
            model: 'zt3',
            board: 'x3_MCU_AT32',
            payload: _slotBin(banner: _mcuSlot),
          ),
          (
            type: 'BMS',
            model: 'gt3',
            board: 'x3_BMS',
            payload: _slotBin(banner: null),
          ),
          (
            type: 'BLE',
            model: 'f3',
            board: 'f3_BLE',
            payload: _slotBin(banner: null),
          ),
        ];

        for (final item in cases) {
          final result = PackV3.buildZip3FromPayload(
            item.payload,
            type: item.type,
            model: item.model,
            enforceModel: true,
            displayName: '${item.model}_${item.type}_test',
          );
          final metadata = _fw(result.zipBytes);
          expect(metadata['compatible'], [item.board], reason: item.type);
          expect(metadata['type'], item.type.toLowerCase(), reason: item.type);
          expect(metadata['models'], [item.model], reason: item.type);
          expect(metadata.containsKey('enforceModel'), isFalse);
          expect(metadata.containsKey('encryption'), isFalse);

          final unpacked = PackV3.unpackV3(
            result.zipBytes,
            policy: Zip3UnpackPolicy.extract,
          );
          expect(unpacked.firmware, item.payload, reason: item.type);
          expect(unpacked.format, Zip3Format.rev2, reason: item.type);
        }
      },
    );
  });

  group('slot-relative helpers', () {
    test('detect(slotBin: true) preselects from the 0x400 banner', () {
      final d = PackV3.detect(_slotBin(), slotBin: true);
      expect(d.type, 'VCU');
      expect(d.model, 'g3');
      final m = PackV3.detect(_slotBin(banner: _mcuSlot), slotBin: true);
      expect(m.type, 'MCU');
      expect(m.model, isNull);
    });
  });

  group('CompatPatch.keyState', () {
    test('the default SHU key', () {
      expect(
        CompatPatch.keyState(_dump(keyAt1420: _defaultKey)),
        FwKeyState.defaultKey,
      );
    });
    test('all 0xFF is blank', () {
      expect(
        CompatPatch.keyState(_dump(keyAt1420: List.filled(16, 0xFF))),
        FwKeyState.blank,
      );
    });
    test('anything else is oem', () {
      expect(
        CompatPatch.keyState(_dump(keyAt1420: List.filled(16, 0x00))),
        FwKeyState.oem,
      );
    });
    test('bleFlashable: key and blank yes, oem no', () {
      expect(FwKeyState.defaultKey.bleFlashable, true);
      expect(FwKeyState.blank.bleFlashable, true);
      expect(FwKeyState.oem.bleFlashable, false);
    });
  });
}
