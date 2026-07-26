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

  /// Exact per-type slot-0 payload ceilings, measured over the local corpus
  /// (docs/plan-zip3-inputs.md): the region's last 4-byte word is at
  /// 0x0800FFFC (VCU) / 0x0800F7FC (MCU), so `payload + 4` fills the region
  /// exactly. Used by the sliced-bin packer path, which knows the declared
  /// type; the flash-path window above is a separate, deliberately unchanged
  /// gate (its 64 KiB edge is pinned by the gen_test_bins manifest).
  static const int slot0MaxPayloadVcu = 61436;
  static const int slot0MaxPayloadMcu = 59388;

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
    return _validateSlotLength(len);
  }

  /// Validate a decrypted slot-0 payload before it is written to disk.
  /// ZIP3 unpack uses this so an invalid package can never create or replace
  /// the requested output file.
  static FirmwareCheck validateSlotBytes(List<int> bytes) {
    if (bytes.isEmpty || _singleRepeatedBytes(bytes)) {
      return FirmwareCheck.fail(
        'Bin contains only zeros or a single repeated byte.',
      );
    }
    return _validateSlotLength(bytes.length);
  }

  static FirmwareCheck _validateSlotLength(int len) {
    if (len == expectedSize) {
      return FirmwareCheck.fail(
        'That’s a full 128 KB image — slot 0 needs a smaller slot bin.',
      );
    }
    if (len < slot0MinBytes) {
      return FirmwareCheck.fail(
        'This file is too small for Slot 0 '
        '($len bytes; minimum $slot0MinBytes).',
      );
    }
    if (len > slot0MaxBytes) {
      return FirmwareCheck.fail(
        'This file is too large for Slot 0 '
        '($len bytes; maximum $slot0MaxBytes).',
      );
    }
    return FirmwareCheck.valid;
  }

  /// Cheap ZIP3 container gate. Flash import retains the 70 KiB cap because it
  /// only accepts slot-sized VCU/MCU payloads. Standalone extraction passes
  /// [enforceFlashSizeLimit] false because legitimate BLE packages are much
  /// larger and their encrypted member is integrity-checked by MD5.
  static FirmwareCheck validateZip3Container(
    String path, {
    bool enforceFlashSizeLimit = true,
  }) {
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
    if (enforceFlashSizeLimit && len > maxZip3Bytes) {
      return FirmwareCheck.fail(
        'ZIP is too large ($len bytes). ZIP3 firmware packages must be '
        '$maxZip3Bytes bytes or smaller.',
      );
    }
    return FirmwareCheck.valid;
  }

  static bool _singleRepeatedByte(File f) {
    final bytes = f.readAsBytesSync();
    return _singleRepeatedBytes(bytes);
  }

  static bool _singleRepeatedBytes(List<int> bytes) {
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

  /// Suggested editable filename for standalone ZIP3 unpack:
  /// `<model>_<type>_<normalised source ZIP basename>.bin`.
  static String defaultUnpackedFilename({
    required String model,
    required String type,
    required String sourceFilename,
  }) {
    return normalizeUnpackedFilename(
      '${model.toLowerCase()}_${type.toLowerCase()}_'
      '${_sourceStem(sourceFilename)}',
    );
  }

  /// A source filename reduced to a safe suggestion stem: basename without
  /// extension, unsafe characters collapsed to `_`, edges trimmed.
  static String _sourceStem(String sourceFilename) {
    final sourceBase = p.basenameWithoutExtension(sourceFilename).trim();
    final source = sourceBase
        .replaceAll(RegExp(r'[^A-Za-z0-9.-]+'), '_')
        .replaceAll(RegExp(r'^[_\-.]+|[_\-.]+$'), '');
    return source.isEmpty ? 'firmware' : source;
  }

  /// Default editable name for a package built from a complete payload bin:
  /// `<model>_<TYPE>_<normalised source .bin basename>` — the same shape as
  /// the Unpack suggestion, so the unpack → patch → repack round trip keeps
  /// its lineage readable. Slice keeps the timestamp default
  /// ([defaultZip3Name]): a dump filename is already a timestamp, while the
  /// source payload's filename is useful package identity.
  static String defaultZip3NameForPayload({
    required String model,
    required String type,
    required String sourceFilename,
  }) => '${model}_${type}_${_sourceStem(sourceFilename)}';

  /// Validate an operator-edited output filename for the fixed
  /// `Documents/x3utils/unpacked_zip3` folder. Path components are deliberately
  /// refused: this field names one local `.bin`, not an arbitrary destination.
  static FirmwareCheck validateUnpackedFilename(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return FirmwareCheck.fail('Choose an output filename.');
    }
    if (trimmed.length > 240) {
      return FirmwareCheck.fail('Output filename is too long.');
    }
    if (trimmed.codeUnits.any((c) => c < 32) ||
        RegExp(r'[<>:"/\\|?*]').hasMatch(trimmed)) {
      return FirmwareCheck.fail(
        'Output filename contains an unsupported character.',
      );
    }
    final withoutSuffix = trimmed.toLowerCase().endsWith('.bin')
        ? trimmed.substring(0, trimmed.length - 4)
        : trimmed;
    if (withoutSuffix.isEmpty ||
        withoutSuffix == '.' ||
        withoutSuffix == '..' ||
        withoutSuffix.endsWith('.') ||
        withoutSuffix.endsWith(' ')) {
      return FirmwareCheck.fail('Choose a valid output filename.');
    }
    final stem = withoutSuffix.split('.').first.toUpperCase();
    const reserved = {
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    };
    if (reserved.contains(stem)) {
      return FirmwareCheck.fail('That output filename is reserved by Windows.');
    }
    return FirmwareCheck.valid;
  }

  static String normalizeUnpackedFilename(String input) {
    final trimmed = input.trim();
    return trimmed.toLowerCase().endsWith('.bin') ? trimmed : '$trimmed.bin';
  }

  static String unpackedBinPath(String filename) {
    final check = validateUnpackedFilename(filename);
    if (!check.ok) throw ArgumentError(check.message);
    return p.join(_dir('unpacked_zip3'), normalizeUnpackedFilename(filename));
  }

  /// Default editable name the "Make zip3" tool offers for a package:
  /// `<model>_<TYPE>_<ts>` (e.g. `g3_MCU_2026-07-21_10-40-30`). A dump carries
  /// no version string, so the operator accepts or edits this; it becomes both
  /// the `info.json` displayName and the output filename.
  static String defaultZip3Name({
    required String model,
    required String type,
  }) => '${model}_${type}_${_stamp()}';

  /// Output path for a "Make zip3" package under
  /// `Documents/x3utils/packed_zip3`, named after the (possibly edited)
  /// [displayName], sanitised, with a `.zip` extension.
  static String packedZip3Path(String displayName, {String prefix = ''}) {
    final dir = _dir('packed_zip3');
    final clean = displayName.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
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
  static String get packedZip3DirLabel =>
      _homeLabel(p.join('Documents', 'x3utils', 'packed_zip3'));
  static String get unpackedZip3DirLabel =>
      _homeLabel(p.join('Documents', 'x3utils', 'unpacked_zip3'));
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

/// State of the 16-byte firmware key at [CompatPatch.offset] (0x1420) — the
/// region the SHU compat patch writes. SHU BLE flashing decrypts with the
/// default (SHU) key, so a dump can only be repackaged into a BLE-loadable zip3
/// if it carries that key here, or leaves it blank (`0xFF`, the newer repo
/// default). OEM/stock firmware holds a different production key and would fail
/// a BLE flash. This gate is NECESSARY, NOT SUFFICIENT: a present key only rules
/// out the obvious OEM case — it does not guarantee SHU BLE will accept the
/// package. Whether an OEM dump could be made SHU-flashable just by rewriting
/// this key is unresolved (suspected enough for older firmware, not newer), so
/// Make zip3 refuses OEM dumps rather than guess. NB 0x1420 is INSIDE the
/// payload (0x20 past the banner), so some older repo builds hold unrelated
/// bytes there and trip this as a known exception — unconfirmed theory: that fw
/// doesn't look for a key, and newer fw adopted the blank convention.
enum FwKeyState {
  /// The default SHU key — repo/Compat firmware.
  defaultKey,

  /// All `0xFF` — the newer repo default.
  blank,

  /// A different production key — OEM/stock, not BLE-flashable as-is.
  oem;

  bool get bleFlashable => this != FwKeyState.oem;
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

  /// Classify the 16-byte firmware key at [offset] in a full 128 KB [image]
  /// (a backup dump). Used to gate "Make zip3": only [FwKeyState.bleFlashable]
  /// dumps — repo/Compat (default key) or newer repo default (blank) — can be
  /// repackaged; OEM firmware is refused. See flash_compat's 0x1420 patch.
  /// [slotBin] reads the slot-relative 0x420 instead (a sliced slot-0 payload
  /// starts at dump offset 0x1000, so the same region sits 0x1000 earlier);
  /// there the state is advisory, never a gate.
  static FwKeyState keyState(List<int> image, {bool slotBin = false}) {
    final base = slotBin ? offset - 0x1000 : offset;
    if (image.length < base + signature.length) return FwKeyState.oem;
    var isKey = true;
    var isBlank = true;
    for (var i = 0; i < signature.length; i++) {
      final b = image[base + i];
      if (b != signature[i]) isKey = false;
      if (b != 0xFF) isBlank = false;
    }
    if (isKey) return FwKeyState.defaultKey;
    if (isBlank) return FwKeyState.blank;
    return FwKeyState.oem;
  }

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
