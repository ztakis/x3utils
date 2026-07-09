import 'dart:io';
import 'package:path/path.dart' as p;

class FirmwareCheck {
  const FirmwareCheck(this.ok, this.message);
  final bool ok;
  final String message;
  static const FirmwareCheck valid = FirmwareCheck(true, '');
  static FirmwareCheck fail(String m) => FirmwareCheck(false, m);
}

/// Port of FirmwareValidator.cs. `requireSize` is off for slot-0 bins
/// (validate_bin ... nosize in flash_slot0.bat).
class Firmware {
  static const int expectedSize = 131072; // 128 KB

  static FirmwareCheck validate(String path, {bool requireSize = true}) {
    if (path.trim().isEmpty) return FirmwareCheck.fail('No firmware file selected.');
    final f = File(path);
    if (!f.existsSync()) return FirmwareCheck.fail('Firmware file does not exist.');
    if (path.contains('{') || path.contains('}')) {
      return FirmwareCheck.fail('Path contains an unsupported character: { or }.');
    }
    if (path.codeUnits.any((c) => c > 127)) {
      return FirmwareCheck.fail('Path has non-ASCII characters — use English letters only.');
    }
    if (p.extension(path).toLowerCase() != '.bin') {
      return FirmwareCheck.fail('Invalid file type. Only .bin is allowed.');
    }
    final len = f.lengthSync();
    if (requireSize && len != expectedSize) {
      return FirmwareCheck.fail('Invalid size. Expected $expectedSize bytes, got $len.');
    }
    if (_singleRepeatedByte(f)) {
      return FirmwareCheck.fail('Bin contains only zeros or a single repeated byte.');
    }
    return FirmwareCheck.valid;
  }

  /// Slot-0 bins are NOT full images: reject a 128 KB image (that's a full
  /// flash, not a slot bin) and anything too big for the slot-0 region
  /// (0x08001000 → flash end 0x08020000 = 0x1F000 bytes).
  static FirmwareCheck validateSlot(String path) {
    final base = validate(path, requireSize: false);
    if (!base.ok) return base;
    final len = File(path).lengthSync();
    if (len == expectedSize) {
      return FirmwareCheck.fail(
          'That’s a full 128 KB image — slot 0 needs a smaller slot bin.');
    }
    const slotMax = 0x1F000; // 126976
    if (len > slotMax) {
      return FirmwareCheck.fail('Too big for slot 0 ($len bytes, max $slotMax).');
    }
    return FirmwareCheck.valid;
  }

  static bool _singleRepeatedByte(File f) {
    final bytes = f.readAsBytesSync();
    if (bytes.isEmpty) return true;
    final first = bytes[0];
    for (final b in bytes) {
      if (b != first) return false;
    }
    return true;
  }

  /// A fresh timestamped dump. [folder] overrides the default backup dir;
  /// [prefix] is prepended to the filename (`<prefix>_dump_<ts>.bin`).
  static String newDumpPath({String? folder, String prefix = ''}) {
    final dir = folder ?? _dir('backup');
    Directory(dir).createSync(recursive: true);
    return p.join(dir, '${_pre(prefix)}dump_${_stamp()}.bin');
  }

  /// Raw + patched paths for the SHU-compat workflow — kept SEPARATE from
  /// regular backups, under Documents/x3utils/compat (mirrors flash_compat.bat).
  static (String raw, String patched) newCompatPaths({String prefix = ''}) {
    final dir = _dir('compat');
    final ts = _stamp();
    return (
      p.join(dir, '${_pre(prefix)}compat_$ts.bin'),
      p.join(dir, '${_pre(prefix)}compat_${ts}_patched.bin'),
    );
  }

  /// Redundant copy into %LOCALAPPDATA%\x3utils_backup (mirrors dump.bat).
  /// Returns the destination path, or null on failure (best-effort).
  static String? secondCopy(String srcPath) {
    try {
      final base = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['HOME'];
      if (base == null) return null;
      final dir = Directory(p.join(base, 'x3utils_backup'))
        ..createSync(recursive: true);
      final dest = p.join(dir.path, p.basename(srcPath));
      File(srcPath).copySync(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// Sanitised filename prefix (safe chars only) + trailing underscore.
  static String _pre(String prefix) {
    final clean = prefix.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '');
    return clean.isEmpty ? '' : '${clean}_';
  }

  static String _dir(String sub) {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final dir = Directory(p.join(home, 'Documents', 'x3utils', sub));
    dir.createSync(recursive: true);
    return dir.path;
  }

  static String _stamp() => DateTime.now()
      .toIso8601String()
      .split('.')
      .first
      .replaceAll(':', '-')
      .replaceAll('T', '_');
}

/// The SHU-compatible patch (flash_compat step 2): inject a fixed 16-byte
/// signature at 0x1420 into the chip's own firmware, then flash it back.
class CompatPatch {
  static const int offset = 0x1420;
  static final List<int> signature =
      _hex('FE801CB2D1EF41A6A41731F5A06824F0');

  static List<int> _hex(String s) =>
      [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

  /// Read [srcPath], write the signature at [offset], verify, save [dstPath].
  static FirmwareCheck apply(String srcPath, String dstPath) {
    final bytes = File(srcPath).readAsBytesSync();
    if (bytes.length < offset + signature.length) {
      return FirmwareCheck.fail('Dump too small to patch (${bytes.length} bytes).');
    }
    for (var i = 0; i < signature.length; i++) {
      bytes[offset + i] = signature[i];
    }
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) {
        return FirmwareCheck.fail('Patch verification failed after write.');
      }
    }
    File(dstPath).writeAsBytesSync(bytes);
    return FirmwareCheck.valid;
  }
}
