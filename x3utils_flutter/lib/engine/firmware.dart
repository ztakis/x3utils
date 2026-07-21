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
  static const int maxZip3Bytes = 70 * 1024; // reject before readAsBytes()

  /// Acceptable size window for a slot-0 bin, measured on the **decrypted** bin
  /// (what is actually written at 0x08001000). **PROVISIONAL placeholders** —
  /// change these two numbers once the exact slot-0 region spec is confirmed.
  /// Observed real firmware is ~57–61 KB; outside the window is a HARD reject
  /// (too small = not a real slot image; too big = would overrun slot 0 into
  /// slot 1 / identity and break the identity-safe guarantee).
  static const int slot0MinBytes =
      0xC800; // 50 KB (51200)  — TODO: confirm spec
  static const int slot0MaxBytes =
      0x10000; // 64 KB (65536) — TODO: confirm spec

  static FirmwareCheck validate(String path, {bool requireSize = true}) {
    if (path.trim().isEmpty) {
      return FirmwareCheck.fail('No firmware file selected.');
    }
    final f = File(path);
    if (!f.existsSync()) {
      return FirmwareCheck.fail('Firmware file does not exist.');
    }
    if (path.contains('{') || path.contains('}')) {
      return FirmwareCheck.fail(
        'Path contains an unsupported character: { or }.',
      );
    }
    if (path.codeUnits.any((c) => c > 127)) {
      return FirmwareCheck.fail(
        'Path has non-ASCII characters — use English letters only.',
      );
    }
    if (p.extension(path).toLowerCase() != '.bin') {
      return FirmwareCheck.fail('Invalid file type. Only .bin is allowed.');
    }
    final len = f.lengthSync();
    if (requireSize && len != expectedSize) {
      return FirmwareCheck.fail(
        'Invalid size. Expected $expectedSize bytes, got $len.',
      );
    }
    if (_singleRepeatedByte(f)) {
      return FirmwareCheck.fail(
        'Bin contains only zeros or a single repeated byte.',
      );
    }
    return FirmwareCheck.valid;
  }

  /// Slot-0 bins are NOT full images: reject a 128 KB image, then enforce the
  /// provisional decrypted-size window [slot0MinBytes]..[slot0MaxBytes]. [len]
  /// is the decrypted bin size (zip3: the post-decrypt temp .bin; Choose .bin:
  /// the file itself).
  static FirmwareCheck validateSlot(String path) {
    final base = validate(path, requireSize: false);
    if (!base.ok) return base;
    final len = File(path).lengthSync();
    if (len == expectedSize) {
      return FirmwareCheck.fail(
        'That’s a full 128 KB image — slot 0 needs a smaller slot bin.',
      );
    }
    if (len < slot0MinBytes) {
      return FirmwareCheck.fail(
        'Too small for a slot-0 firmware ($len bytes, min $slot0MinBytes).',
      );
    }
    if (len > slot0MaxBytes) {
      return FirmwareCheck.fail(
        'Too big for slot 0 ($len bytes, max $slot0MaxBytes).',
      );
    }
    return FirmwareCheck.valid;
  }

  /// Cheap ZIP3 container gate. This intentionally runs before loading the
  /// archive into memory so an accidentally selected huge ZIP cannot crash the
  /// app. The decrypted payload still receives the normal slot validation.
  static FirmwareCheck validateZip3Container(String path) {
    if (path.trim().isEmpty) {
      return FirmwareCheck.fail('No ZIP3 package selected.');
    }
    final f = File(path);
    if (!f.existsSync()) {
      return FirmwareCheck.fail('ZIP3 package does not exist.');
    }
    if (p.extension(path).toLowerCase() != '.zip') {
      return FirmwareCheck.fail('Invalid file type. Only .zip is allowed.');
    }
    final len = f.lengthSync();
    if (len > maxZip3Bytes) {
      return FirmwareCheck.fail(
        'ZIP is too large ($len bytes). ZIP3 firmware packages must be '
        '$maxZip3Bytes bytes or smaller.',
      );
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

  /// Firmware decrypted from a zip3 package, kept under
  /// `Documents/x3utils/unpacked_zip3` so the flash flow can read it by path
  /// and the user can re-flash it later via Choose .bin. [name] seeds the
  /// filename (sanitised); [prefix] follows the usual rule.
  static String newUnpackedBinPath({
    String prefix = '',
    String name = 'firmware',
  }) {
    final dir = _dir('unpacked_zip3');
    final clean = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final label = clean.isEmpty ? 'firmware' : clean;
    return p.join(dir, '${_pre(prefix)}${label}_${_stamp()}.bin');
  }

  /// Default editable name the "Make zip3" tool offers for a package:
  /// `<model>_<TYPE>_<ts>` (e.g. `g3_MCU_2026-07-21_10-40-30`). A dump carries
  /// no version string, so the operator accepts or edits this; it becomes both
  /// the `info.json` displayName and the output filename.
  static String defaultZip3Name({required String model, required String type}) =>
      '${model}_${type}_${_stamp()}';

  /// Output path for a "Make zip3" package under
  /// `Documents/x3utils/packed_zip3`, named after the (possibly edited)
  /// [displayName], sanitised, with a `.zip` extension.
  static String packedZip3Path(String displayName, {String prefix = ''}) {
    final dir = _dir('packed_zip3');
    final clean = displayName.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final base = clean.isEmpty ? 'firmware' : clean;
    return p.join(dir, '${_pre(prefix)}$base.zip');
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

  /// Redundant copy into the 2nd-copy dir (mirrors dump.bat).
  /// Returns the destination path, or null on failure (best-effort).
  static String? secondCopy(String srcPath) {
    try {
      final dir = Directory(secondCopyDir())..createSync(recursive: true);
      final dest = p.join(dir.path, p.basename(srcPath));
      File(srcPath).copySync(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// Resolved 2nd-copy dir — each OS mirrors its CLI sibling's location:
  /// `%LOCALAPPDATA%\x3utils_backup` (Windows, dump.bat),
  /// `~/Library/Application Support/x3utils_backup` (macOS, x3utils_mac/dump.sh),
  /// hidden `~/.x3utils_backup` (Linux, x3utils_linux/dump.sh).
  static String secondCopyDir() {
    if (Platform.isWindows) {
      final base =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.current.path;
      return p.join(base, 'x3utils_backup');
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    if (Platform.isMacOS) {
      return p.join(home, 'Library', 'Application Support', 'x3utils_backup');
    }
    return p.join(home, '.x3utils_backup');
  }

  /// Write a per-run console log under `Documents/x3utils/logs/{action}/`.
  /// Returns the path.
  static String writeLog(String action, String content) {
    final dir = _dir(p.join('logs', action));
    final path = p.join(dir, '${action}_${_stamp()}.log');
    File(path).writeAsStringSync(content);
    return path;
  }

  /// Sanitised filename prefix (safe chars only) + trailing underscore.
  static String _pre(String prefix) {
    final clean = prefix.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '');
    return clean.isEmpty ? '' : '${clean}_';
  }

  // ── UI display labels (per-OS, so the settings panel never lies) ──────────
  // Windows keeps the bare `Documents\…` hint; unix shows a `~/`-prefixed path
  // with native separators. Kept in sync with _dir / secondCopyDir above.
  static String get backupDirLabel =>
      _homeLabel(p.join('Documents', 'x3utils', 'backup'));
  static String get logsDirLabel =>
      _homeLabel(p.join('Documents', 'x3utils', 'logs'));
  static String get secondCopyLabel {
    if (Platform.isWindows) return r'%LOCALAPPDATA%\x3utils_backup';
    if (Platform.isMacOS) return '~/Library/Application Support/x3utils_backup';
    return r'~/.x3utils_backup';
  }

  static String _homeLabel(String sub) => Platform.isWindows ? sub : '~/$sub';

  static String _dir(String sub) {
    final home =
        Platform.environment['USERPROFILE'] ??
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
  static final List<int> signature = _hex('FE801CB2D1EF41A6A41731F5A06824F0');

  static List<int> _hex(String s) => [
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];

  /// Read [srcPath], write the signature at [offset], verify, save [dstPath].
  static FirmwareCheck apply(String srcPath, String dstPath) {
    final bytes = File(srcPath).readAsBytesSync();
    if (bytes.length < offset + signature.length) {
      return FirmwareCheck.fail(
        'Dump too small to patch (${bytes.length} bytes).',
      );
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
