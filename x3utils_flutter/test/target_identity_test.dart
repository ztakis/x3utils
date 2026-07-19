import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/device_spec.dart';

// Deterministic in-memory images (no scratch harness — these are the committed
// replacement for the never-committed 2026-07 serial-guard tests, with the
// REAL offsets: banner 0x1400 full / 0x400 slot, serial 0x1F020 + 0x1F420).

const _zt3Banner = 'SCOOTER_VCU_xxU2';
const _g3Banner = 'SCOOTER_VCU_xxG3';
const _mcuBanner = 'SCOOTER_MCU_0001';

Uint8List _fullImage({
  String? banner,
  String? serial,
  String? serialBackup,
  bool garbageSerialRegions = false,
  int fill = 0x00,
}) {
  final b = Uint8List(131072)..fillRange(0, 131072, fill);
  if (garbageSerialRegions) {
    for (final off in const [kSerialOffset, kSerialBackupOffset]) {
      for (var i = 0; i < kSerialLength; i++) {
        b[off + i] = (i * 7 + 3) & 0xFF; // non-uniform, non-alnum
      }
    }
  }
  void put(String? s, int off) {
    if (s == null) return;
    b.setRange(off, off + s.length, s.codeUnits);
  }

  put(banner, kSlotBannerOffset);
  put(serial, kSerialOffset);
  put(serialBackup ?? serial, kSerialBackupOffset);
  return b;
}

Uint8List _slotBin({String? banner}) {
  final b = Uint8List(57344)..fillRange(0, 57344, 0x00);
  if (banner != null) {
    b.setRange(kBannerOffset, kBannerOffset + banner.length, banner.codeUnits);
  }
  return b;
}

void main() {
  // Bench-confirmed real/generic pairs (14 chars — the on-flash length).
  const realZt3 = '1K1EA2510P1673';
  const realG3 = '1CGCC9926C8115';
  const genericZt3 = '1K1E0000000001';
  const genericG3 = '1CGC0000000001';

  group('readSerial classification', () {
    test('shape-valid non-generic serial is real with a decoded model', () {
      final s = DeviceSpec.readSerial(_fullImage(serial: realZt3));
      expect(s.state, SerialState.real);
      expect(s.text, realZt3);
      expect(s.model, 'zt3');
    });

    test('known factory strings are generic, still model-decoded', () {
      final s = DeviceSpec.readSerial(_fullImage(serial: genericZt3));
      expect(s.state, SerialState.generic);
      expect(s.text, genericZt3);
      expect(s.model, 'zt3');
      final g = DeviceSpec.readSerial(_fullImage(serial: genericG3));
      expect(g.state, SerialState.generic);
      expect(g.model, 'g3');
    });

    test('a stray byte after the 14 chars does not affect the read', () {
      // The bench artifact that mis-sized the serial to 15: the byte after
      // the serial is unrelated data and must not leak into the text.
      final img = _fullImage(serial: genericZt3);
      img[kSerialOffset + kSerialLength] = 0x52; // 'R'
      img[kSerialBackupOffset + kSerialLength] = 0x52;
      final s = DeviceSpec.readSerial(img);
      expect(s.state, SerialState.generic);
      expect(s.text, genericZt3);
    });

    test('backup copy is used when the primary is garbage', () {
      final img = _fullImage(garbageSerialRegions: true);
      img.setRange(
        kSerialBackupOffset,
        kSerialBackupOffset + kSerialLength,
        realG3.codeUnits,
      );
      final s = DeviceSpec.readSerial(img);
      expect(s.state, SerialState.real);
      expect(s.model, 'g3');
    });

    test('both copies blank (0x00 or 0xFF) is cleared', () {
      expect(DeviceSpec.readSerial(_fullImage()).state, SerialState.cleared);
      expect(
        DeviceSpec.readSerial(_fullImage(fill: 0xFF)).state,
        SerialState.cleared,
      );
    });

    test('garbage in both copies is none, not cleared', () {
      final s = DeviceSpec.readSerial(_fullImage(garbageSerialRegions: true));
      expect(s.state, SerialState.none);
    });

    test('unknown prefix stays real with no model', () {
      final s = DeviceSpec.readSerial(_fullImage(serial: 'ZZZ12345678901'));
      expect(s.state, SerialState.real);
      expect(s.model, isNull);
    });
  });

  group('checkTargetMatch is banner-only', () {
    test('banner model swap still blocks (hardware-validated case)', () {
      final tm = DeviceSpec.checkTargetMatch(
        dump: _fullImage(banner: _zt3Banner, serial: realZt3),
        firmware: _fullImage(banner: _g3Banner, serial: realG3),
        incomingIsSlotBin: false,
      );
      expect(tm.blocked, isTrue);
    });

    test('banner type swap still blocks', () {
      final tm = DeviceSpec.checkTargetMatch(
        dump: _fullImage(banner: _zt3Banner),
        firmware: _slotBin(banner: _mcuBanner),
        incomingIsSlotBin: true,
      );
      expect(tm.blocked, isTrue);
    });

    test('serial disagreement no longer blocks (enforcement retired)', () {
      // Target contradicting itself (g3 serial under a zt3 banner) and an
      // incoming image with a different serial: banners agree → pass.
      final tm = DeviceSpec.checkTargetMatch(
        dump: _fullImage(banner: _zt3Banner, serial: realG3),
        firmware: _fullImage(banner: _zt3Banner, serial: realZt3),
        incomingIsSlotBin: false,
      );
      expect(tm.blocked, isFalse);
    });

    test('nothing readable is allowed with a skipped note', () {
      final tm = DeviceSpec.checkTargetMatch(
        dump: _fullImage(),
        firmware: _fullImage(),
        incomingIsSlotBin: false,
      );
      expect(tm.blocked, isFalse);
      expect(tm.note, isNotNull);
    });

    test('agreeing banners pass without a note', () {
      final tm = DeviceSpec.checkTargetMatch(
        dump: _fullImage(banner: _zt3Banner),
        firmware: _fullImage(banner: _zt3Banner),
        incomingIsSlotBin: false,
      );
      expect(tm.blocked, isFalse);
      expect(tm.note, isNull);
    });
  });

  group('checkIncomingBin selection gate', () {
    test('mainstream rejects a bannerless full image toward Flash Only', () {
      final gate = DeviceSpec.checkIncomingBin(
        _fullImage(serial: realZt3),
        slotBin: false,
        enforceBanner: true,
      );
      expect(gate.ok, isFalse);
      expect(gate.message, contains('Flash Only'));
    });

    test('mainstream accepts bannered full and slot bins', () {
      expect(
        DeviceSpec.checkIncomingBin(
          _fullImage(banner: _zt3Banner),
          slotBin: false,
          enforceBanner: true,
        ).ok,
        isTrue,
      );
      expect(
        DeviceSpec.checkIncomingBin(
          _slotBin(banner: _mcuBanner),
          slotBin: true,
          enforceBanner: true,
        ).ok,
        isTrue,
      );
    });

    test('mainstream rejects a bannerless slot bin', () {
      expect(
        DeviceSpec.checkIncomingBin(
          _slotBin(),
          slotBin: true,
          enforceBanner: true,
        ).ok,
        isFalse,
      );
    });

    test('flash_only stays permissive (no banner required)', () {
      expect(
        DeviceSpec.checkIncomingBin(
          _fullImage(),
          slotBin: false,
          enforceBanner: false,
        ).ok,
        isTrue,
      );
    });
  });

  group('describeBin display facts', () {
    test('real serial: neutral, full text and model shown', () {
      final id = DeviceSpec.describeBin(
        _fullImage(banner: _zt3Banner, serial: realZt3),
        slotBin: false,
      );
      expect(id.warn, isFalse);
      expect(id.summary, contains('ZT3 · VCU'));
      expect(id.summary, contains(realZt3));
    });

    test('generic serial: amber and the full generic string is shown', () {
      final id = DeviceSpec.describeBin(
        _fullImage(banner: _zt3Banner, serial: genericZt3),
        slotBin: false,
      );
      expect(id.warn, isTrue);
      expect(id.summary, contains(genericZt3));
      expect(id.summary, contains('generic / replacement part'));
    });

    test('cleared serial: amber with the erasure warning', () {
      final id = DeviceSpec.describeBin(
        _fullImage(banner: _zt3Banner),
        slotBin: false,
      );
      expect(id.warn, isTrue);
      expect(id.summary, contains('serial cleared'));
    });

    test('serial model disagreeing with the banner is amber', () {
      final id = DeviceSpec.describeBin(
        _fullImage(banner: _g3Banner, serial: realZt3),
        slotBin: false,
      );
      expect(id.serialModelClash, isTrue);
      expect(id.warn, isTrue);
      expect(id.summary, contains('disagrees'));
    });

    test('slot bin has no serial facts', () {
      final id = DeviceSpec.describeBin(
        _slotBin(banner: _mcuBanner),
        slotBin: true,
      );
      expect(id.serial, isNull);
      expect(id.warn, isFalse);
      expect(id.summary, 'MCU');
      expect(id.logLine, contains('slot bin'));
    });
  });

  group('serialChangeNote', () {
    SerialInfo read(Uint8List b) => DeviceSpec.readSerial(b);

    test('restoring the device\'s own backup is silent', () {
      final note = DeviceSpec.serialChangeNote(
        target: read(_fullImage(serial: realZt3)),
        incoming: read(_fullImage(serial: realZt3)),
      );
      expect(note, isNull);
    });

    test('slot writes are silent (serial preserved)', () {
      final note = DeviceSpec.serialChangeNote(
        target: read(_fullImage(serial: realZt3)),
        incoming: null,
      );
      expect(note, isNull);
    });

    test('different incoming serial notes the change tense-free', () {
      final note = DeviceSpec.serialChangeNote(
        target: read(_fullImage(serial: realZt3)),
        incoming: read(_fullImage(serial: realG3)),
      );
      expect(note, contains('$realZt3 → $realG3'));
      // The same string is logged pre-write and shown post-success — it must
      // not claim a completed action (the guard can still abort the write).
      expect(note, isNot(contains('replaced')));
    });

    test('cleared incoming notes the erasure and re-provisioning', () {
      final note = DeviceSpec.serialChangeNote(
        target: read(_fullImage(serial: realZt3)),
        incoming: read(_fullImage()),
      );
      expect(note, contains('cleared'));
      expect(note, contains('re-provisions'));
    });

    test('generic incoming notes the revert to factory state', () {
      final note = DeviceSpec.serialChangeNote(
        target: read(_fullImage(serial: realZt3)),
        incoming: read(_fullImage(serial: genericZt3)),
      );
      expect(note, contains('generic'));
    });

    test('writing onto a blank target notes the incoming serial', () {
      final note = DeviceSpec.serialChangeNote(
        target: read(_fullImage()),
        incoming: read(_fullImage(serial: realZt3)),
      );
      expect(note, contains('(blank) → $realZt3'));
    });
  });
}
