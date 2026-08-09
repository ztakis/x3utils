/// The file inspector behind Get file info.
///
/// This is observation and nothing else: it opens a `.bin` or a zip3 package,
/// reports what the bytes say, and never writes, patches, or decides that a
/// file may be flashed. A file described here has passed no flash guard — the
/// guarded actions run their own, stricter checks at Start.
///
/// It is deliberately INDEPENDENT of the backup sidecar. Both happen to
/// describe a full image today and their row sets look alike, but they answer
/// different questions — "what is this file, right now" versus "what was this
/// backup when it was taken" — and this one is meant to grow into a detailed
/// inspector with its own rules and display options. It shares the byte
/// READERS in [DumpMetadata] and the presentation vocabulary in `info_row`;
/// it does not share the sidecar's row rules.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'device_spec.dart';
import 'dump_metadata.dart';
import 'firmware.dart';
import 'firmware_inspection.dart';
import 'info_row.dart';
import 'pack_zip3.dart';
import 'zp_extract.dart';

class FileInfo {
  const FileInfo._();

  /// Refuse absurd inputs before reading them into memory. Neither bound is a
  /// firmware fact: a full image is 131072 bytes and the largest real package
  /// seen is a ~1.85 MB BLE archive, so both leave room to spare and exist
  /// only so a mis-picked file fails with a sentence instead of an OOM.
  static const int maxBinBytes = 8 * 1024 * 1024;
  static const int maxZipBytes = 32 * 1024 * 1024;

  static const String _intro =
      'Read locally from the selected file. This describes what the bytes '
      'say; it is not a flash-compatibility verdict.';

  /// Describe any `.bin` or `.zip` on disk. Never throws — a file that cannot
  /// be read comes back as a report carrying [InfoReport.message].
  static InfoReport describe(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return const InfoReport(
        title: 'File info unavailable',
        message: 'That file no longer exists. Select it again.',
      );
    }
    final extension = p.extension(path).toLowerCase();
    final length = file.lengthSync();
    try {
      if (extension == '.zip') {
        if (length > maxZipBytes) return _tooBig(length, maxZipBytes);
        return _zip(path, file.readAsBytesSync());
      }
      if (extension == '.bin') {
        if (length > maxBinBytes) return _tooBig(length, maxBinBytes);
        return _bin(path, file.readAsBytesSync());
      }
      return const InfoReport(
        title: 'File info unavailable',
        message:
            'Only firmware images (.bin) and zip3 packages (.zip) can be '
            'described.',
      );
    } catch (e) {
      return InfoReport(
        title: 'File info unavailable',
        message: 'That file could not be read: $e',
      );
    }
  }

  static InfoReport _tooBig(int length, int limit) => InfoReport(
    title: 'File info unavailable',
    message:
        'That file is $length bytes, past the $limit-byte limit for this '
        'reader. Firmware images and packages are far smaller.',
  );

  static InfoReport _bin(String path, List<int> bytes) =>
      bytes.length == Firmware.expectedSize
      ? _fullImage(path, bytes)
      : _slotBin(path, bytes);

  /// A full 128 KB image. [DumpMetadata.inspect] supplies the byte facts —
  /// it is the reader for this layout — but the rows below are the
  /// inspector's own.
  static InfoReport _fullImage(String path, List<int> bytes) {
    final facts = DumpMetadata.inspect(bytes, backupPath: path);
    final firmware = <String>[
      if (facts['model'] != null) infoText(facts['model']).toUpperCase(),
      infoText(facts['type']),
      infoText(facts['version']),
    ].where((part) => part != '—').join(' ');
    final uidConflict = facts['uid'] == null && facts['uidState'] == 'conflict';
    final zpKnown = facts['zpPayloadLen'] != null && facts['zpEncLen'] != null;

    return InfoReport(
      title: 'File info',
      intro: _intro,
      rows: [
        InfoRow('File', p.basename(path)),
        InfoRow('Size', '${bytes.length} bytes', state: 'full image'),
        // The sidecar's stored verdict describes a dump that was ALREADY
        // validated, so it can only ever say ok. A picked file has been
        // validated by nothing, so the read state is established here and
        // spelled out rather than reported as a code name.
        InfoRow('Read', _readState(path)),
        InfoRow(
          'Firmware',
          firmware.isEmpty ? '—' : firmware,
          state: infoText(facts['versionVerdict']),
        ),
        // Same rule as the key. A shape-valid serial that is not on the known
        // generic list has been RECOGNISED BY NOTHING; `real` would claim we
        // checked it against something. A known generic, an erased pair and an
        // unreadable region are all observations, and keep their state.
        InfoRow(
          'Serial',
          infoText(facts['serial']),
          state: switch (facts['serialState']) {
            'generic' => 'generic replacement serial',
            'cleared' => 'cleared',
            'none' => 'unreadable',
            _ => null,
          },
          secret: true,
        ),
        InfoRow(
          'UID',
          uidConflict
              ? '${infoGrouped(facts['uidPrimary'], 4)} / '
                    '${infoGrouped(facts['uidBackup'], 4)}'
              : infoGrouped(facts['uid'], 4),
          state: uidConflict ? 'copies conflict' : infoText(facts['uidState']),
          secret: true,
        ),
        // Read from the bytes, not from `facts`: the sidecar stores the key as
        // TEXT when it happens to be printable, and the inspector always shows
        // hex.
        ..._keyRows(
          bytes,
          keyAt: CompatPatch.offset,
          randAt: DumpMetadata.randOffset,
        ),
        InfoRow(
          'ZP',
          zpKnown
              ? '${facts['zpPayloadLen']} payload / '
                    '${facts['zpEncLen']} encoded'
              : '—',
          state: infoText(facts['zpState']),
        ),
      ],
    );
  }

  /// Plain English for what the read itself says about the image. A complete
  /// all-zeros or all-0xFF image is a correct read of a chip with nothing on
  /// it, and must not be described as a bad file.
  static String _readState(String path) =>
      switch (Firmware.inspectDump(path).verdict) {
        DumpVerdict.ok => 'Readable firmware image',
        DumpVerdict.masked => 'All zeros — the readout-protection signature',
        DumpVerdict.blank => 'All 0xFF — an erased or blank chip',
        DumpVerdict.uniform => 'A single repeated byte — not firmware',
        DumpVerdict.incomplete => 'Short of a full image',
        DumpVerdict.missing => 'Unreadable',
      };

  /// The key and rand regions seen from the START of a slot-0 payload.
  ///
  /// Slot 0 begins at [Zp.slot0Offset] in a full image, so the full-image
  /// offsets shift down by exactly that much: `0x1420` → `0x420`, `0x1430` →
  /// `0x430`. Derived rather than written out so the two views cannot drift.
  static int get _payloadKeyOffset => CompatPatch.offset - Zp.slot0Offset;
  static int get _payloadRandOffset => DumpMetadata.randOffset - Zp.slot0Offset;

  /// Key and rand rows, from a full image or from a slot-0 payload.
  ///
  /// BOTH ARE ALWAYS HEX. They are raw bytes and a key is read as hex, so the
  /// display never asks whether the bytes happen to be printable: that sniff
  /// rendered a text key as 8 uppercase pairs when it is 16 bytes, and
  /// uppercasing can change the key that Copy all hands over. The state
  /// follows: `defaultKey` / `blank` / `other` come from the bytes themselves,
  /// never from how they look.
  ///
  /// Reported for VCU and MCU alike on the maintainer's read that the region
  /// is the same on both — a REPORTED fact, not one measured here, and the
  /// qualifier "at least for now" belongs with it. There is one place to
  /// narrow it if MCU turns out to differ: the caller's banner-type gate.
  static List<InfoRow> _keyRows(
    List<int> image, {
    required int keyAt,
    required int randAt,
  }) {
    if (image.length < randAt + DumpMetadata.randLength) {
      return const <InfoRow>[];
    }
    return [
      InfoRow(
        'Key',
        _hexBytes(image, keyAt, CompatPatch.signature.length),
        // Only what can be PROVEN about these bytes: they equal the known
        // default key, or they are erased. A key we do not recognise is a key
        // we know nothing about — calling it `oem` or `other` dresses up the
        // absence of a match as a finding, so it gets no state at all.
        state: switch (CompatPatch.keyState(image, at: keyAt)) {
          FwKeyState.defaultKey => 'default key',
          FwKeyState.blank => 'blank',
          FwKeyState.other => null,
        },
        secret: true,
      ),
      InfoRow(
        'Rand',
        _hexBytes(image, randAt, DumpMetadata.randLength),
        secret: true,
      ),
    ];
  }

  static String _hexBytes(List<int> image, int at, int length) => infoGrouped(
    image
        .sublist(at, at + length)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(),
    2,
  );

  /// Anything else in a `.bin`: a slot payload, or simply not a firmware image.
  /// Serial, UID and ZP live OUTSIDE slot 0 (0x1F020, 0x1F1B4, 0x1F800), so
  /// they are omitted rather than reported as absent. The key and rand are
  /// not in that list: at 0x1420/0x1430 they sit inside slot 0 and travel
  /// with the payload.
  static InfoReport _slotBin(String path, List<int> bytes) {
    final inspection = FirmwareInspector.inspect(bytes, slotBin: true);
    final identity = inspection.identity;
    return InfoReport(
      title: 'File info',
      intro: _intro,
      rows: [
        InfoRow('File', p.basename(path)),
        InfoRow(
          'Size',
          '${bytes.length} bytes',
          state: 'not a full ${Firmware.expectedSize}-byte image',
        ),
        _firmwareRow(
          identity,
          DumpMetadata.scanVersion(
            bytes,
            type: identity.bannerType,
            model: identity.bannerModel,
          ),
        ),
        InfoRow('Banner', inspection.bannerValue),
        // Only where the banner establishes that slot-0 offsets apply. In an
        // unidentified file, 0x420 is just an address.
        if (identity.bannerType != null)
          ..._keyRows(
            bytes,
            keyAt: _payloadKeyOffset,
            randAt: _payloadRandOffset,
          ),
        if (inspection.hasFindings)
          InfoRow(
            'Notes',
            inspection.findings.map((finding) => finding.message).join('\n'),
          ),
      ],
    );
  }

  static InfoReport _zip(String path, List<int> bytes) {
    final UnpackedV3 package;
    try {
      // The permissive policy: describing a BMS or BLE package is reading, and
      // reading one is not arming it for a controller write.
      package = PackV3.unpackV3(bytes, policy: Zip3UnpackPolicy.extract);
    } on FormatException catch (e) {
      return InfoReport(
        title: 'Package info unavailable',
        message:
            'This package could not be opened as zip3 or zip3.2: ${e.message}',
      );
    }

    final type = package.normalizedType;
    final identity = type == 'VCU' || type == 'MCU'
        ? DeviceSpec.describeBin(package.firmware, slotBin: true)
        : null;

    return InfoReport(
      title: 'Package info',
      intro: _intro,
      rows: [
        InfoRow('File', p.basename(path)),
        InfoRow('Package', package.format.label, state: package.source),
        InfoRow(
          'Declared',
          '${package.model.toUpperCase()} · $type',
          state: package.displayName,
        ),
        InfoRow('Payload', '${package.firmware.length} bytes'),
        // unpackV3 has already failed the package if its MD5 disagreed, so
        // reaching this row IS the check passing.
        const InfoRow('Integrity', 'MD5 matches the package'),
        if (identity != null) ...[
          _firmwareRow(
            identity,
            DumpMetadata.scanVersion(
              package.firmware,
              type: identity.bannerType,
              model: identity.bannerModel,
            ),
          ),
          InfoRow(
            'Banner',
            identity.banner == null
                ? 'Not found'
                : '${identity.bannerLabel} · ${identity.banner}',
          ),
          // A compat-patched package carries the default key here, which is
          // the one thing its filename cannot be trusted for.
          ..._keyRows(
            package.firmware,
            keyAt: _payloadKeyOffset,
            randAt: _payloadRandOffset,
          ),
        ],
      ],
    );
  }

  static InfoRow _firmwareRow(
    BinIdentity identity,
    ({String? version, String verdict}) version,
  ) {
    final parts = <String>[
      if (identity.bannerModel != null) identity.bannerModel!.toUpperCase(),
      if (identity.bannerType != null) identity.bannerType!,
      if (version.version != null) version.version!,
    ];
    return InfoRow(
      'Firmware',
      parts.isEmpty ? '—' : parts.join(' '),
      state: version.verdict,
    );
  }
}
