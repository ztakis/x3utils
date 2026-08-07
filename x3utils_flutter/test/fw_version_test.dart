import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/fw_version.dart';

/// Build a payload with [instr] bytes planted at [at], padded with a filler
/// that is deliberately NOT a valid 32-bit Thumb-2 immediate load.
Uint8List _payloadWith(Map<int, List<int>> instrs, {int length = 60000}) {
  final b = Uint8List(length);
  for (var i = 0; i < length; i++) {
    b[i] = 0x00; // 0x0000 halfwords never match either encoding mask
  }
  instrs.forEach((at, bytes) {
    b.setRange(at, at + bytes.length, bytes);
  });
  return b;
}

/// MOVW Rd,#imm16 for imm16 <= 0xFFF (imm4 = 0).
List<int> _movw(int imm, {int rd = 0}) {
  final i = (imm >> 11) & 1;
  final imm3 = (imm >> 8) & 7;
  final imm8 = imm & 0xFF;
  final hw1 = 0xF240 | (i << 10);
  final hw2 = (imm3 << 12) | (rd << 8) | imm8;
  return [hw1 & 0xFF, hw1 >> 8, hw2 & 0xFF, hw2 >> 8];
}

/// MOV.W Rd,#const, encoding the rotated-8-bit form used by real builds.
List<int> _movwT2Rotated(int imm12, {int rd = 0}) {
  final i = (imm12 >> 11) & 1;
  final imm3 = (imm12 >> 8) & 7;
  final imm8 = imm12 & 0xFF;
  final hw1 = 0xF04F | (i << 10);
  final hw2 = (imm3 << 12) | (rd << 8) | imm8;
  return [hw1 & 0xFF, hw1 >> 8, hw2 & 0xFF, hw2 >> 8];
}

void main() {
  group('FwVersion', () {
    test('encodes one nibble per field', () {
      expect(FwVersion.parse('1.6.3')!.value, 0x163);
      expect(FwVersion.parse('1.4.11')!.value, 0x14B);
      expect(FwVersion.parse('1.5.15')!.value, 0x15F);
    });

    test('refuses fields that do not fit a nibble', () {
      expect(FwVersion.parse('1.16.0'), isNull);
      expect(FwVersion.parse('1.5.16'), isNull);
      expect(FwVersion.parse('nonsense'), isNull);
    });
  });

  group('decoding', () {
    test('reads a MOVW-encoded version', () {
      final p = _payloadWith({0x2000: _movw(0x163)});
      final id = FwVersionScanner.identify(p, model: 'g3', type: 'VCU');
      expect(id.verdict, FwVerdict.blacklisted); // g3 1.6.3 is on the list
      expect(id.version.toString(), '1.6.3');
    });

    test('reads a MOV.W-encoded version, which MOVW-only decoders miss', () {
      // 0x152 (zt3 1.5.2) is not MOVW-encodable in real builds: the assembler
      // emits the rotated form 0xA9 ror 31.
      final p = _payloadWith({0x3000: _movwT2Rotated(0xFA9)});
      final id = FwVersionScanner.identify(p, model: 'zt3', type: 'VCU');
      expect(id.verdict, FwVerdict.identified);
      expect(id.version.toString(), '1.5.2');
    });

    test('does not key on the destination register', () {
      // gt3 VCU 1.5.8 uses r1; assuming r0 would false-refuse a whole line.
      for (final rd in [0, 1, 5]) {
        final p = _payloadWith({0x2400: _movw(0x158, rd: rd)});
        final id = FwVersionScanner.identify(p, model: 'f3', type: 'VCU');
        expect(id.verdict, FwVerdict.identified, reason: 'r$rd');
        expect(id.version.toString(), '1.5.8', reason: 'r$rd');
      }
    });
  });

  group('verdicts', () {
    test('blacklist wins over identification and is checked first', () {
      final p = _payloadWith({
        0x2000: _movw(0x155), // g3 1.5.5, a known-good version
        0x2400: _movw(0x163), // g3 1.6.3, blacklisted
      });
      final id = FwVersionScanner.identify(p, model: 'g3', type: 'VCU');
      expect(id.verdict, FwVerdict.blacklisted);
      expect(id.blocked, isTrue);
      expect(id.version.toString(), '1.6.3');
    });

    test('an unlisted version is unknown, not silently allowed', () {
      // 1.9.9 is on nobody's list — the shape a future release arrives in.
      final p = _payloadWith({0x2000: _movw(0x199)});
      final id = FwVersionScanner.identify(p, model: 'zt3', type: 'VCU');
      expect(id.verdict, FwVerdict.unknown);
      expect(id.uncertain, isTrue);
      expect(id.version, isNull);
    });

    test('two distinct known versions refuse rather than pick one', () {
      final p = _payloadWith({
        0x2000: _movw(0x14B), // 1.4.11
        0x2400: _movw(0x152), // 1.5.2
      });
      final id = FwVersionScanner.identify(p, model: 'zt3', type: 'VCU');
      expect(id.verdict, FwVerdict.ambiguous);
      expect(id.matches.map((v) => v.toString()), ['1.4.11', '1.5.2']);
    });

    test('the same version twice is fine — slot 0 and slot 1 agree', () {
      final p = _payloadWith({0x2000: _movw(0x14B), 0x5000: _movw(0x14B)});
      final id = FwVersionScanner.identify(p, model: 'zt3', type: 'VCU');
      expect(id.verdict, FwVerdict.identified);
      expect(id.version.toString(), '1.4.11');
    });

    test('decoy constants are not versions and never match', () {
      // 0x147, 0x16D, 0x18F and 0x1EB appear in nearly every real build. None
      // is a released ZT3 version, so an enumerated list must ignore them —
      // a ">= 1.5.9" range check would refuse this payload.
      final p = _payloadWith({
        0x1000: _movw(0x147),
        0x2000: _movw(0x16D),
        0x3000: _movw(0x18F),
        0x4000: _movw(0x1EB),
      });
      final id = FwVersionScanner.identify(p, model: 'zt3', type: 'VCU');
      expect(id.verdict, FwVerdict.unknown);
      expect(id.matches, isEmpty);
    });
  });

  group('matrix', () {
    test('every table entry parses to a nibble-encodable version', () {
      for (final table in [FwVersionMatrix.known, FwVersionMatrix.blacklist]) {
        table.forEach((key, versions) {
          for (final v in versions) {
            expect(FwVersion.parse(v), isNotNull, reason: '$key $v');
          }
        });
      }
    });

    test('every blacklisted model/type also appears in the known list', () {
      for (final key in FwVersionMatrix.blacklist.keys) {
        expect(FwVersionMatrix.known.containsKey(key), isTrue, reason: key);
      }
    });

    test('GT3 is refused by model, independent of any version', () {
      expect(FwVersionMatrix.unsupportedModels, contains('gt3'));
      expect(FwVersionMatrix.blacklist.containsKey('gt3/VCU'), isFalse);
    });
  });

  group('real corpus (skipped when the private mirror is absent)', () {
    // The mirror is local and untracked; these rows are the ones the matrix was
    // derived from, so they pin the decoder against real firmware when present.
    const mirror = r'I:\SCOOTER\fw.jsb.by';
    const cases = <String, List<String>>{
      r'zt3\VCU\FIRM_1.4.11 (Compat).bin': ['zt3', 'VCU', '1.4.11'],
      r'zt3\VCU\FIRM_1.5.2 (Compat).bin': ['zt3', 'VCU', '1.5.2'],
      r'g3\VCU\FIRM_1.5.5 (Compat).bin': ['g3', 'VCU', '1.5.5'],
      r'g3\VCU\FIRM_1.5.8 (Compat).bin': ['g3', 'VCU', '1.5.8'],
      r'f3\VCU\FIRM_1.5.13 (Compat).bin': ['f3', 'VCU', '1.5.13'],
    };

    for (final entry in cases.entries) {
      final path = '$mirror\\${entry.key}';
      final model = entry.value[0];
      final type = entry.value[1];
      final expected = entry.value[2];
      test('identifies $model $type $expected', () {
        final f = File(path);
        if (!f.existsSync()) {
          markTestSkipped('mirror not present: $path');
          return;
        }
        final id = FwVersionScanner.identify(
          f.readAsBytesSync(),
          model: model,
          type: type,
        );
        expect(id.version?.toString(), expected);
      });
    }
  });
}
