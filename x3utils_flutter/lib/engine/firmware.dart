import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:universal_io/universal_io.dart';

import 'windows_ansi_path_stub.dart'
    if (dart.library.io) 'windows_ansi_path.dart';

class FirmwareCheck {
  const FirmwareCheck(this.ok, this.message);
  final bool ok;
  final String message;
  static const FirmwareCheck valid = FirmwareCheck(true, '');
  static FirmwareCheck fail(String m) => FirmwareCheck(false, m);
}

/// What a finished dump file actually is. A failed read and a read-protected
/// chip both used to collapse into one "invalid" message, but they are opposite
/// findings: one is a broken read of a working chip, the other is a complete,
/// correct read of a chip that refuses to show its flash.
enum DumpVerdict {
  /// 128 KB of real, varied firmware. The only verdict that becomes a backup.
  ok,

  /// OpenOCD wrote nothing at all.
  missing,

  /// Short (or long) read. Identity lives in the last 4 KB at 0x1F000, so a
  /// truncated dump is not a degraded backup — it is not a backup.
  incomplete,

  /// Full size, all `0x00`: the readout-protection (FAP) signature. Valid
  /// evidence about the chip, and the reason to run Check protection.
  masked,

  /// Full size, all `0xFF`: an erased or blank chip. Nothing to back up.
  blank,

  /// Full size, but one repeated byte that is neither `0x00` nor `0xFF`.
  uniform,
}

class DumpCheck {
  const DumpCheck(this.verdict, this.message, this.length);

  final DumpVerdict verdict;
  final String message;
  final int length;

  bool get ok => verdict == DumpVerdict.ok;

  /// A file that never can be a backup, and that only clutters the folder.
  /// These are the ones the operator is offered a trash move for.
  bool get isJunk =>
      verdict == DumpVerdict.incomplete || verdict == DumpVerdict.uniform;

  /// A complete read that says something true about the chip. Kept, never
  /// swept up as junk.
  bool get isEvidence =>
      verdict == DumpVerdict.masked || verdict == DumpVerdict.blank;
}

/// Port of FirmwareValidator.cs. `requireSize` is off for slot-0 bins
/// (validate_bin ... nosize in flash_slot0.bat).
class Firmware {
  static const int expectedSize = 131072; // 128 KB
  static const int maxZip3Bytes = 70 * 1024; // reject before readAsBytes()

  /// Master switch for the three GUESSED size gates: the
  /// [slot0MinBytes]/[slot0MaxBytes] window in [_validateSlotLength], and the
  /// [maxZip3Bytes] container cap on the flash-import path.
  ///
  /// Off because none of the three is a measurement. The window's upper edge
  /// sits 4 KB above the end of slot 0, so it already permitted the overrun it
  /// was written to prevent, and a firmware generation with different slot
  /// geometry would be refused by numbers that never described it. The real
  /// bounds that remain armed are measured or structural: the exact 128 KB
  /// full-image reject below, the per-type payload ceilings, and the ZP
  /// record's fits-in-dump check.
  ///
  /// Constants and call sites are left in place — set this true to re-arm all
  /// three at once. Deliberately NOT read by [Zp]: the same two numbers also
  /// filter candidate ZP length records, where they pick a payload rather than
  /// permit one, and that use stays armed.
  static const bool enforceSlotSizeHeuristics = false;

  /// Acceptable size window for a slot-0 bin, measured on the plaintext bin
  /// (what is actually written at 0x08001000). **PROVISIONAL placeholders** —
  /// change these two numbers once the exact slot-0 region spec is confirmed.
  /// Observed real firmware is ~57–61 KB; outside the window is a HARD reject
  /// (too small = not a real slot image; too big = would overrun slot 0 into
  /// slot 1 / identity and break the identity-safe guarantee).
  ///
  /// Currently enforced only by [Zp]'s record filter — see
  /// [enforceSlotSizeHeuristics].
  static const int slot0MinBytes =
      0xC800; // 50 KB (51200)  — TODO: confirm spec
  static const int slot0MaxBytes =
      0x10000; // 64 KB (65536) — TODO: confirm spec

  /// Exact per-type slot-0 payload ceilings, measured over the local corpus
  /// (docs/plan-zip3-inputs.md): the region's last 4-byte word is at
  /// 0x0800FFFC (VCU) / 0x0800F7FC (MCU), so `payload + 4` fills the region
  /// exactly. Used by the sliced-bin packer path, which knows the declared
  /// type. These are measurements, so they stay armed while the guessed window
  /// above does not — but they apply only where a supported banner names the
  /// type, which is not the flash path.
  static const int slot0MaxPayloadVcu = 61436;
  static const int slot0MaxPayloadMcu = 59388;

  static FirmwareCheck validate(String path, {bool requireSize = true}) {
    return _validateBin(path, requireSize: requireSize, forOpenOcd: true);
  }

  /// Structural validation for a bin read only by Dart. ZIP3 Slice and Pack
  /// are offline file-to-file tools, so Tcl quoting and Windows OpenOCD argv
  /// conversion do not apply to their source path.
  static FirmwareCheck validateLocalBin(
    String path, {
    bool requireSize = true,
  }) {
    return _validateBin(path, requireSize: requireSize, forOpenOcd: false);
  }

  static FirmwareCheck _validateBin(
    String path, {
    required bool requireSize,
    required bool forOpenOcd,
  }) {
    if (path.trim().isEmpty) {
      return FirmwareCheck.fail('No firmware file selected.');
    }
    final f = File(path);
    if (!f.existsSync()) {
      return FirmwareCheck.fail('Firmware file does not exist.');
    }
    if (forOpenOcd) {
      final safe = validateOpenOcdPath(path);
      if (!safe.ok) return safe;
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

  /// Path rules for anything handed to OpenOCD, in either direction. Checked on
  /// dump DESTINATIONS too, before the run, so a backup folder OpenOCD cannot
  /// write to fails while nothing has happened yet.
  ///
  /// Braces are the Tcl quoting characters the commands are built with, so they
  /// are refused everywhere.
  ///
  /// The non-ASCII rule is WINDOWS ONLY. The bundled Windows OpenOCD is a mingw
  /// build whose CRT converts `argv` from UTF-16 down to the machine's ANSI
  /// codepage before `main()`. A path is safe only when Windows converts it
  /// through that codepage and back unchanged; this rejects best-fit mappings
  /// such as the measured CP1253 `ü` → `u` wrong-file hazard while allowing
  /// Greek on CP1253 and Western European names on CP1252.
  ///
  /// It does not apply off Windows: POSIX paths are opaque bytes and `argv` is
  /// unconverted. Measured 2026-07-29 against the bundled Linux OpenOCD — cfg
  /// reads and file writes through `Prüfung/`, `Δοκιμή/`, a Cyrillic-homoglyph
  /// directory and an emoji directory all succeeded. Applying it there refused
  /// every dump for a user like `/home/Jörg`, whose `~/x3utils` root carries the
  /// username, and refused firmware picked from their own home as well.
  /// BETA3 BENCH SWITCH, off by default. Skips only the Windows ACP half so the
  /// safe rule and unrestricted OpenOCD behavior can be compared. The
  /// controller stage-gates this before setting it; braces are NEVER skipped.
  static bool bypassWindowsPathSafety = false;

  static int? get windowsAnsiCodePage {
    if (!Platform.isWindows) return null;
    try {
      return WindowsAnsiPath.activeCodePage;
    } catch (_) {
      return null;
    }
  }

  static FirmwareCheck validateOpenOcdPath(String path) {
    if (path.contains('{') || path.contains('}')) {
      return FirmwareCheck.fail(
        'Path contains an unsupported character: { or }.',
      );
    }
    if (Platform.isWindows &&
        !bypassWindowsPathSafety &&
        path.codeUnits.any((c) => c > 127)) {
      try {
        final result = WindowsAnsiPath.check(path);
        if (!result.exact) {
          final codePoint = result.offendingCodePoint;
          final position = result.firstDifferenceIndex;
          if (codePoint != null && position != null) {
            final hex = codePoint
                .toRadixString(16)
                .toUpperCase()
                .padLeft(4, '0');
            final character = result.offendingCharacter;
            return FirmwareCheck.fail(
              "Windows code page ${result.codePage} cannot pass '$character' "
              '(U+$hex) at character ${position + 1} to OpenOCD unchanged. '
              'Choose a different folder or filename.',
            );
          }
          return FirmwareCheck.fail(
            'Windows code page ${result.codePage} cannot pass this path to '
            'OpenOCD unchanged. Use a different folder or filename.',
          );
        }
      } catch (_) {
        return FirmwareCheck.fail(
          'Could not verify this non-ASCII path against the Windows system '
          'code page. Use an ASCII folder or filename.',
        );
      }
    }
    return FirmwareCheck.valid;
  }

  /// Read a finished dump file and say what it is. Deliberately separate from
  /// [validate]: this runs on the staged `.part` file (so no `.bin` extension
  /// yet) and it must distinguish a broken read from read-protection instead of
  /// reporting one "invalid" for both.
  static DumpCheck inspectDump(String path) {
    final f = File(path);
    if (!f.existsSync()) {
      return const DumpCheck(
        DumpVerdict.missing,
        'No dump file was written.',
        0,
      );
    }
    return inspectDumpBytes(f.readAsBytesSync());
  }

  /// Classify in-memory dump bytes with the same policy as [inspectDump].
  /// Browser backends use this before any download is offered.
  static DumpCheck inspectDumpBytes(List<int> bytes) {
    final len = bytes.length;
    if (len != expectedSize) {
      return DumpCheck(
        DumpVerdict.incomplete,
        'Incomplete read: $len of $expectedSize bytes. Identity lives in the '
        'last 4 KB, so a short dump is not a backup.',
        len,
      );
    }
    if (!_singleRepeatedBytes(bytes)) {
      return DumpCheck(DumpVerdict.ok, '', len);
    }
    switch (bytes[0]) {
      case 0x00:
        return DumpCheck(
          DumpVerdict.masked,
          'The chip read back as all zeros. That is the readout-protection '
          'signature, not a bad read — run Check protection.',
          len,
        );
      case 0xFF:
        return DumpCheck(
          DumpVerdict.blank,
          'The chip read back as all 0xFF — an erased or blank chip. There is '
          'no firmware here to back up.',
          len,
        );
      default:
        final b = bytes[0].toRadixString(16).padLeft(2, '0').toUpperCase();
        return DumpCheck(
          DumpVerdict.uniform,
          'The whole 128 KB read back as one repeated byte (0x$b) — that is '
          'not firmware.',
          len,
        );
    }
  }

  /// Slot-0 bins are NOT full images, so a 128 KB image is rejected outright.
  /// The provisional [slot0MinBytes]..[slot0MaxBytes] window that used to
  /// follow is gated off — see [enforceSlotSizeHeuristics]. [len] is the
  /// recovered payload size (ZIP import or a directly chosen .bin).
  static FirmwareCheck validateSlot(String path) {
    final base = validate(path, requireSize: false);
    if (!base.ok) return base;
    final len = File(path).lengthSync();
    return _validateSlotLength(len);
  }

  /// Validate a plaintext slot-0 payload before it is written to disk.
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

  /// Validate a complete full-flash image already held in memory.
  static FirmwareCheck validateFullImageBytes(List<int> bytes) {
    if (bytes.length != expectedSize) {
      return FirmwareCheck.fail(
        'Invalid size. Expected $expectedSize bytes, got ${bytes.length}.',
      );
    }
    if (_singleRepeatedBytes(bytes)) {
      return FirmwareCheck.fail(
        'Bin contains only zeros or a single repeated byte.',
      );
    }
    return FirmwareCheck.valid;
  }

  static FirmwareCheck _validateSlotLength(int len) {
    if (len == expectedSize) {
      return FirmwareCheck.fail(
        'That’s a full 128 KB image — slot 0 needs a smaller slot bin.',
      );
    }
    if (enforceSlotSizeHeuristics && len < slot0MinBytes) {
      return FirmwareCheck.fail(
        'This file is too small for Slot 0 '
        '($len bytes; minimum $slot0MinBytes).',
      );
    }
    if (enforceSlotSizeHeuristics && len > slot0MaxBytes) {
      return FirmwareCheck.fail(
        'This file is too large for Slot 0 '
        '($len bytes; maximum $slot0MaxBytes).',
      );
    }
    return FirmwareCheck.valid;
  }

  /// Cheap ZIP3 container gate. The 70 KiB pre-read cap on the flash-import
  /// path was sized to one slot payload; it is gated off (see
  /// [enforceSlotSizeHeuristics]) because a package larger than slot 0 is
  /// better refused by the payload checks that know what slot 0 actually is
  /// than by a guess at the container's size. [enforceFlashSizeLimit] is kept
  /// so standalone extraction stays explicitly exempt: legitimate BLE packages
  /// are much larger, and their payload member is integrity-checked by MD5.
  static FirmwareCheck validateZip3Container(
    String path, {
    bool enforceFlashSizeLimit = true,
  }) {
    if (path.trim().isEmpty) {
      return FirmwareCheck.fail('No zip3 or zip3.2 package selected.');
    }
    final f = File(path);
    if (!f.existsSync()) {
      return FirmwareCheck.fail('The zip3/zip3.2 package does not exist.');
    }
    if (p.extension(path).toLowerCase() != '.zip') {
      return FirmwareCheck.fail('Invalid file type. Only .zip is allowed.');
    }
    final len = f.lengthSync();
    if (enforceSlotSizeHeuristics &&
        enforceFlashSizeLimit &&
        len > maxZip3Bytes) {
      return FirmwareCheck.fail(
        'ZIP is too large ($len bytes). Slot-0 zip3/zip3.2 packages must be '
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

  /// A fresh timestamped dump under `<root>/backup`. [prefix] is prepended to
  /// the filename (`<prefix>_dump_<ts>.bin`). There is no per-call folder
  /// override: the destination follows the one x3utils root.
  static String newDumpPath({String prefix = ''}) {
    final dir = _dir('backup');
    return p.join(dir, dumpFileName(prefix: prefix));
  }

  /// A browser-safe backup filename that creates no directory and writes
  /// nothing. The browser chooses the eventual download location.
  static String dumpFileName({String prefix = ''}) =>
      '${_pre(prefix)}dump_${_stamp()}.bin';

  /// Suffix a dump carries while it is being written and until it has been
  /// inspected. A failed read must never occupy a real backup name: it would
  /// look legitimate in the folder and a `.bin` file picker would offer it.
  static const String partSuffix = '.part';

  /// Where OpenOCD actually writes, given the eventual backup path.
  static String stagedDumpPath(String finalPath) => '$finalPath$partSuffix';

  static bool isStagedDump(String path) => path.endsWith(partSuffix);

  /// The backup name a staged path would be promoted to, as pure path math —
  /// no file has to exist. Used when a run ends before any dump was written
  /// but still has adjacent artifacts to name consistently.
  static String finalDumpPath(String stagedPath) => isStagedDump(stagedPath)
      ? stagedPath.substring(0, stagedPath.length - partSuffix.length)
      : stagedPath;

  /// Give a validated dump its real backup name. Returns the new path, or the
  /// staged path unchanged if the rename fails — the caller then reports where
  /// the file really is rather than a name that does not exist.
  static String promoteDump(String stagedPath) {
    if (!isStagedDump(stagedPath)) return stagedPath;
    final finalPath = stagedPath.substring(
      0,
      stagedPath.length - partSuffix.length,
    );
    try {
      File(stagedPath).renameSync(finalPath);
      return finalPath;
    } catch (_) {
      return stagedPath;
    }
  }

  /// Plaintext firmware recovered from a zip3 or zip3.2 package, kept under
  /// `<root>/unpacked_zip3` so the flash flow can read it by path
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
  /// `<root>/unpacked_zip3` folder. Path components are deliberately
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

  /// Output path for a "Make zip3" package under `<root>/packed_zip3`,
  /// named after the (possibly edited)
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
  /// regular backups, under `<root>/compat` (mirrors flash_compat.bat).
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

  /// Resolved 2nd-copy dir — deliberately OUTSIDE the x3utils root, and
  /// deliberately hidden: it is a redundant copy, so it must not share a
  /// parent the user can point somewhere else, empty, or sync. Each OS mirrors
  /// its CLI sibling's location:
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

  /// Write a per-run console log under `<root>/logs/{action}/`.
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

  // ── The x3utils folder ────────────────────────────────────────────────────
  // ONE user-chosen root holds everything a run produces, under fixed
  // subfolder names and with no per-folder overrides: `backup/`, `compat/`,
  // `unpacked_zip3/`, `packed_zip3/`, `logs/`. "Send me your backup and the
  // log" has to be one place to look. The 2nd-copy dir is deliberately NOT in
  // here — see [secondCopyDir].
  //
  // Static because every path helper on this class is static and the root is
  // one process-wide setting; `AppController` pushes the stored preference in
  // at startup and whenever the user changes it.
  static String? _rootOverride;

  /// The folder used when the user has not chosen one: `C:\x3utils` on
  /// Windows, `~/x3utils` on Linux and macOS. Deliberately outside Documents,
  /// which OneDrive redirects on many machines — the app would then write to a
  /// different Documents than the one Explorer shows — and deliberately not
  /// `~/.local/share`, because the user has to be able to find these files and
  /// send them.
  static String get defaultRoot {
    if (Platform.isWindows) return r'C:\x3utils';
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return p.join(home, 'x3utils');
  }

  /// The active root: the user's chosen folder, else [defaultRoot].
  static String get root => _rootOverride ?? defaultRoot;

  static bool get rootIsDefault => _rootOverride == null;

  /// Whether the root is on disk yet. It is created by the first run that
  /// needs it, so before then there is nothing to open.
  static bool get rootExists => Directory(root).existsSync();

  /// null or blank restores [defaultRoot].
  static void setRoot(String? path) {
    final v = path?.trim();
    _rootOverride = (v == null || v.isEmpty) ? null : v;
  }

  /// Check a folder the user is about to make the root, WHEN IT IS PICKED:
  /// usable by OpenOCD (the path rules every dump destination under it inherits,
  /// non-ASCII among them on Windows only) and actually writable. The pre-run
  /// destination check stays as the safety net; this only moves the bad news to
  /// the moment of the choice.
  static FirmwareCheck validateRootFolder(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return FirmwareCheck.fail('Choose a folder.');
    final safe = validateOpenOcdPath(trimmed);
    if (!safe.ok) return safe;
    try {
      final dir = Directory(trimmed)..createSync(recursive: true);
      File(p.join(dir.path, '.x3utils_write_test'))
        ..writeAsStringSync('')
        ..deleteSync();
    } catch (_) {
      return FirmwareCheck.fail(
        'That folder cannot be written to. Pick one you own, '
        'such as $defaultRoot.',
      );
    }
    return FirmwareCheck.valid;
  }

  // ── UI display labels ─────────────────────────────────────────────────────
  // Real absolute paths: with one root that the settings panel can show and
  // reveal, a hint no longer has to stand in for a path the app kept to itself.
  static String get backupDirLabel => _path('backup');
  static String get packedZip3DirLabel => _path('packed_zip3');
  static String get unpackedZip3DirLabel => _path('unpacked_zip3');
  static String get logsDirLabel => _path('logs');
  static String get secondCopyLabel {
    if (Platform.isWindows) return r'%LOCALAPPDATA%\x3utils_backup';
    if (Platform.isMacOS) return '~/Library/Application Support/x3utils_backup';
    return r'~/.x3utils_backup';
  }

  /// Where a subfolder is, without creating it (labels must not make folders).
  static String _path(String sub) => p.join(root, sub);

  static String _dir(String sub) {
    final dir = Directory(_path(sub));
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

/// State of the 16-byte firmware region at [CompatPatch.offset] (0x1420) — the
/// region the SHU compat patch writes. This is diagnostic evidence only. It is
/// not a ZIP3 acceptance rule and does not prove whether BLE will accept a
/// package. NB 0x1420 is INSIDE the payload (0x20 past the banner), so older
/// firmware may legitimately contain unrelated bytes there.
enum FwKeyState {
  /// The default SHU key — commonly seen in repo/Compat firmware.
  defaultKey,

  /// All `0xFF` — commonly seen in newer repo firmware.
  blank,

  /// Any other bytes. The region alone does not establish their provenance.
  other,
}

/// State of the 16-byte field added at 0x1440 by the newer OEM firmware
/// generation. This is a compatibility fingerprint, not cryptographic key
/// validation: TEA and XTEA both accept arbitrary 16-byte keys, while the OEM
/// stores this particular field as ASCII letters and digits.
enum FwXteaState {
  /// Sixteen ASCII letters/digits: the observed OEM XTEA-field shape.
  present,

  /// Sixteen 0xFF bytes: cleared by SHU/modded firmware.
  cleared,

  /// Anything else, including the code/data occupying this offset in the old
  /// layout. This means no recognisable OEM XTEA field, not a cryptographic
  /// proof that XTEA is unused anywhere in the image.
  notDetected,
}

class CompatXtea {
  const CompatXtea._();

  static const int offset = 0x1440;
  static const int length = 16;

  static FwXteaState keyState(List<int> image, {int at = offset}) {
    if (image.length < at + length) return FwXteaState.notDetected;
    var alphanumeric = true;
    var cleared = true;
    for (var i = 0; i < length; i++) {
      final byte = image[at + i];
      final digit = byte >= 0x30 && byte <= 0x39;
      final upper = byte >= 0x41 && byte <= 0x5A;
      final lower = byte >= 0x61 && byte <= 0x7A;
      if (!digit && !upper && !lower) alphanumeric = false;
      if (byte != 0xFF) cleared = false;
    }
    if (alphanumeric) return FwXteaState.present;
    if (cleared) return FwXteaState.cleared;
    return FwXteaState.notDetected;
  }

  /// Sidecar wording for the 0x1440 state. `present` is reported as
  /// `asciiAlphanumeric`: the state names the byte SHAPE that was observed,
  /// not a claim that the field is in use. Shared with the Extra certificate
  /// so one set of bytes cannot get two descriptions.
  static String keyStateLabel(List<int> image, {int at = offset}) =>
      switch (keyState(image, at: at)) {
        FwXteaState.present => 'asciiAlphanumeric',
        FwXteaState.cleared => 'cleared',
        FwXteaState.notDetected => 'notDetected',
      };
}

/// The SHU-compatible patch (flash_compat step 2): inject a fixed 16-byte
/// signature at 0x1420 into the chip's own firmware, then flash it back.
class CompatPatch {
  static const int offset = 0x1420;
  static final List<int> signature = _hex('FE801CB2D1EF41A6A41731F5A06824F0');

  /// Prove that the full output preserves every byte except the SHU field.
  static FirmwareCheck validateChange(List<int> original, List<int> patched) {
    if (original.length != Firmware.expectedSize ||
        patched.length != Firmware.expectedSize) {
      return FirmwareCheck.fail(
        'SHU patch requires two complete 128 KiB images.',
      );
    }
    if (keyState(patched) != FwKeyState.defaultKey) {
      return FirmwareCheck.fail(
        'The SHU compatibility signature is missing at 0x1420.',
      );
    }
    for (var i = 0; i < original.length; i++) {
      if (i >= offset && i < offset + signature.length) continue;
      if (original[i] != patched[i]) {
        return FirmwareCheck.fail(
          'SHU patch changed a byte outside its field at 0x${i.toRadixString(16)}.',
        );
      }
    }
    return FirmwareCheck.valid;
  }

  static List<int> _hex(String s) => [
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];

  /// Classify the 16-byte firmware key at [at] — [offset] in a full 128 KB
  /// image (a backup dump), or the same region seen from the start of a slot-0
  /// payload. This is an informational classification only; it does not decide
  /// whether the dump may be repackaged. See flash_compat's 0x1420 patch.
  static FwKeyState keyState(List<int> image, {int at = offset}) {
    if (image.length < at + signature.length) return FwKeyState.other;
    var isKey = true;
    var isBlank = true;
    for (var i = 0; i < signature.length; i++) {
      final b = image[at + i];
      if (b != signature[i]) isKey = false;
      if (b != 0xFF) isBlank = false;
    }
    if (isKey) return FwKeyState.defaultKey;
    if (isBlank) return FwKeyState.blank;
    return FwKeyState.other;
  }

  /// Sidecar wording for the 0x1420 state, refining [FwKeyState.other] into
  /// `asciiAlphanumeric` when the bytes carry the observed OEM shape.
  ///
  /// Shared so the ordinary `.json` and the Extra certificate can never
  /// describe the same bytes with different words — they did, until schema 4.
  static String keyStateLabel(List<int> image, {int at = offset}) {
    final state = keyState(image, at: at);
    if (state == FwKeyState.other &&
        asciiAlphanumeric(image, at, signature.length)) {
      return 'asciiAlphanumeric';
    }
    return switch (state) {
      FwKeyState.defaultKey => 'defaultKey',
      FwKeyState.blank => 'blank',
      FwKeyState.other => 'other',
    };
  }

  /// True when [length] bytes at [at] are all ASCII letters or digits.
  static bool asciiAlphanumeric(List<int> image, int at, int length) {
    if (image.length < at + length) return false;
    for (var i = 0; i < length; i++) {
      final byte = image[at + i];
      final digit = byte >= 0x30 && byte <= 0x39;
      final upper = byte >= 0x41 && byte <= 0x5A;
      final lower = byte >= 0x61 && byte <= 0x7A;
      if (!digit && !upper && !lower) return false;
    }
    return true;
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

  /// In-memory variant: patch [bytes] in place and return them.
  static (FirmwareCheck, Uint8List?) applyBytes(Uint8List bytes) {
    if (bytes.length < offset + signature.length) {
      return (
        FirmwareCheck.fail('Dump too small to patch (${bytes.length} bytes).'),
        null,
      );
    }
    final patched = Uint8List.fromList(bytes);
    for (var i = 0; i < signature.length; i++) {
      patched[offset + i] = signature[i];
    }
    for (var i = 0; i < signature.length; i++) {
      if (patched[offset + i] != signature[i]) {
        return (
          FirmwareCheck.fail('Patch verification failed after write.'),
          null,
        );
      }
    }
    return (FirmwareCheck.valid, patched);
  }
}
