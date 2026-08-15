import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _GetAcpNative = Uint32 Function();
typedef _GetAcpDart = int Function();

typedef _WideCharToMultiByteNative =
    Int32 Function(
      Uint32 codePage,
      Uint32 flags,
      Pointer<Utf16> wideChars,
      Int32 wideCharCount,
      Pointer<Uint8> bytes,
      Int32 byteCount,
      Pointer<Uint8> defaultChar,
      Pointer<Int32> usedDefaultChar,
    );
typedef _WideCharToMultiByteDart =
    int Function(
      int codePage,
      int flags,
      Pointer<Utf16> wideChars,
      int wideCharCount,
      Pointer<Uint8> bytes,
      int byteCount,
      Pointer<Uint8> defaultChar,
      Pointer<Int32> usedDefaultChar,
    );

typedef _MultiByteToWideCharNative =
    Int32 Function(
      Uint32 codePage,
      Uint32 flags,
      Pointer<Uint8> bytes,
      Int32 byteCount,
      Pointer<Utf16> wideChars,
      Int32 wideCharCount,
    );
typedef _MultiByteToWideCharDart =
    int Function(
      int codePage,
      int flags,
      Pointer<Uint8> bytes,
      int byteCount,
      Pointer<Utf16> wideChars,
      int wideCharCount,
    );

/// Result of asking Windows whether [originalPath] survives one ANSI-codepage
/// round trip unchanged.
class WindowsAnsiPathResult {
  const WindowsAnsiPathResult({
    required this.originalPath,
    required this.codePage,
    required this.exact,
    this.roundTrippedPath,
    this.usedDefaultCharacter = false,
    this.conversionFailed = false,
  });

  final String originalPath;
  final int codePage;
  final bool exact;
  final String? roundTrippedPath;
  final bool usedDefaultCharacter;
  final bool conversionFailed;

  int? get firstDifferenceIndex {
    final converted = roundTrippedPath;
    if (converted == null) return null;
    final originalRunes = originalPath.runes.toList(growable: false);
    final convertedRunes = converted.runes.toList(growable: false);
    final common = originalRunes.length < convertedRunes.length
        ? originalRunes.length
        : convertedRunes.length;
    for (var i = 0; i < common; i++) {
      if (originalRunes[i] != convertedRunes[i]) return i;
    }
    return originalRunes.length == convertedRunes.length ? null : common;
  }

  int? get offendingCodePoint {
    final index = firstDifferenceIndex;
    if (index == null) return null;
    final runes = originalPath.runes.toList(growable: false);
    return index < runes.length ? runes[index] : null;
  }

  String? get offendingCharacter {
    final codePoint = offendingCodePoint;
    return codePoint == null ? null : String.fromCharCode(codePoint);
  }
}

/// Models the exact UTF-16 → current Windows ACP conversion performed by the
/// bundled MinGW OpenOCD before `main()` receives its argv.
///
/// This is validation only. The app keeps its paths as Unicode and never stores
/// the converted bytes.
class WindowsAnsiPath {
  static const int _cpUtf8 = 65001;
  static const int _wcNoBestFitChars = 0x00000400;
  static const int _wcErrInvalidChars = 0x00000080;
  static const int _mbErrInvalidChars = 0x00000008;

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _GetAcpDart _getAcp = _kernel32
      .lookupFunction<_GetAcpNative, _GetAcpDart>('GetACP');
  static final _WideCharToMultiByteDart _wideCharToMultiByte = _kernel32
      .lookupFunction<_WideCharToMultiByteNative, _WideCharToMultiByteDart>(
        'WideCharToMultiByte',
      );
  static final _MultiByteToWideCharDart _multiByteToWideChar = _kernel32
      .lookupFunction<_MultiByteToWideCharNative, _MultiByteToWideCharDart>(
        'MultiByteToWideChar',
      );

  static int get activeCodePage {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows ACP exists only on Windows.');
    }
    return _getAcp();
  }

  /// Check [path] against [codePage], or this machine's active ANSI code page
  /// when omitted. Supplying a code page makes the Windows tests deterministic.
  static WindowsAnsiPathResult check(String path, {int? codePage}) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows ACP validation exists only on Windows.');
    }
    final cp = codePage ?? activeCodePage;
    final utf8 = cp == _cpUtf8;
    final wideFlags = utf8 ? _wcErrInvalidChars : _wcNoBestFitChars;
    final narrowFlags = utf8 ? _mbErrInvalidChars : 0;
    final source = path.toNativeUtf16(allocator: calloc);
    final usedDefault = calloc<Int32>();
    final noBytes = nullptr.cast<Uint8>();
    final noWideChars = nullptr.cast<Utf16>();
    final usedDefaultPointer = utf8 ? nullptr.cast<Int32>() : usedDefault;

    try {
      final byteLength = _wideCharToMultiByte(
        cp,
        wideFlags,
        source,
        -1,
        noBytes,
        0,
        noBytes,
        usedDefaultPointer,
      );
      if (byteLength == 0) {
        return WindowsAnsiPathResult(
          originalPath: path,
          codePage: cp,
          exact: false,
          conversionFailed: true,
        );
      }

      final bytes = calloc<Uint8>(byteLength);
      try {
        usedDefault.value = 0;
        final encoded = _wideCharToMultiByte(
          cp,
          wideFlags,
          source,
          -1,
          bytes,
          byteLength,
          noBytes,
          usedDefaultPointer,
        );
        if (encoded == 0) {
          return WindowsAnsiPathResult(
            originalPath: path,
            codePage: cp,
            exact: false,
            conversionFailed: true,
          );
        }

        final wideLength = _multiByteToWideChar(
          cp,
          narrowFlags,
          bytes,
          -1,
          noWideChars,
          0,
        );
        if (wideLength == 0) {
          return WindowsAnsiPathResult(
            originalPath: path,
            codePage: cp,
            exact: false,
            usedDefaultCharacter: usedDefault.value != 0,
            conversionFailed: true,
          );
        }

        final roundTripUnits = calloc<Uint16>(wideLength);
        try {
          final roundTrip = roundTripUnits.cast<Utf16>();
          final decoded = _multiByteToWideChar(
            cp,
            narrowFlags,
            bytes,
            -1,
            roundTrip,
            wideLength,
          );
          if (decoded == 0) {
            return WindowsAnsiPathResult(
              originalPath: path,
              codePage: cp,
              exact: false,
              usedDefaultCharacter: usedDefault.value != 0,
              conversionFailed: true,
            );
          }
          final converted = roundTrip.toDartString();
          final defaultUsed = usedDefault.value != 0;
          return WindowsAnsiPathResult(
            originalPath: path,
            codePage: cp,
            exact: !defaultUsed && converted == path,
            roundTrippedPath: converted,
            usedDefaultCharacter: defaultUsed,
          );
        } finally {
          calloc.free(roundTripUnits);
        }
      } finally {
        calloc.free(bytes);
      }
    } finally {
      calloc
        ..free(usedDefault)
        ..free(source);
    }
  }
}
