import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/windows_ansi_path.dart';

void main() {
  if (!Platform.isWindows) {
    test('Windows ACP checks are Windows-only', () {
      expect(
        () => WindowsAnsiPath.check('/tmp/Prüfung/fw.bin', codePage: 1252),
        throwsUnsupportedError,
      );
    });
    return;
  }

  group('WindowsAnsiPath', () {
    test('reports the machine active ANSI code page', () {
      expect(WindowsAnsiPath.activeCodePage, greaterThan(0));
    });

    test('CP1252 accepts Western European paths exactly', () {
      for (final path in [
        r'C:\Users\Jörg\Desktop\firmware.bin',
        r'C:\bins\Prüfung\firmware.bin',
        r'C:\bins\français\firmware.bin',
      ]) {
        final result = WindowsAnsiPath.check(path, codePage: 1252);
        expect(result.exact, isTrue, reason: path);
        expect(result.roundTrippedPath, path);
        expect(result.usedDefaultCharacter, isFalse);
      }
    });

    test('CP1253 accepts Greek paths exactly', () {
      const path = r'C:\Users\Σοφία\Desktop\firmware.bin';
      final result = WindowsAnsiPath.check(path, codePage: 1253);

      expect(result.exact, isTrue);
      expect(result.roundTrippedPath, path);
      expect(result.usedDefaultCharacter, isFalse);
    });

    test('CP1253 rejects the observed umlaut best-fit hazard', () {
      const path = r'C:\bins\Prüfung\firmware.bin';
      final result = WindowsAnsiPath.check(path, codePage: 1253);

      expect(result.exact, isFalse);
      expect(result.usedDefaultCharacter, isTrue);
      expect(result.offendingCharacter, 'ü');
      expect(result.offendingCodePoint, 0x00FC);
    });

    test('CP1252 rejects Greek rather than substituting it', () {
      const path = r'C:\Users\Σοφία\Desktop\firmware.bin';
      final result = WindowsAnsiPath.check(path, codePage: 1252);

      expect(result.exact, isFalse);
      expect(result.usedDefaultCharacter, isTrue);
      expect(result.offendingCharacter, 'Σ');
      expect(result.offendingCodePoint, 0x03A3);
    });

    test('CP1252 rejects the founding Cyrillic homoglyph', () {
      const path = r'C:\bins\MEMORY_G3_С45_1.5.4.bin';
      final result = WindowsAnsiPath.check(path, codePage: 1252);

      expect(result.exact, isFalse);
      expect(result.usedDefaultCharacter, isTrue);
      expect(result.offendingCharacter, 'С');
      expect(result.offendingCodePoint, 0x0421);
    });

    test('UTF-8 ACP round-trips valid Unicode without a default character', () {
      const path = r'C:\Users\Σοφία\Desktop\zip⚡3\Prüfung.bin';
      final result = WindowsAnsiPath.check(path, codePage: 65001);

      expect(result.exact, isTrue);
      expect(result.roundTrippedPath, path);
      expect(result.usedDefaultCharacter, isFalse);
    });
  });
}
