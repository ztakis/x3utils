/// The single source of truth for which zip3 packages x3utils will flash.
///
/// **Change your mind HERE** — one file, compiled + code-reviewed + versioned
/// with the app. This is a *safety allow-list*: a wrong-model firmware can brick
/// a controller, so it lives in code (not a runtime config that could be edited
/// to bypass the gate) on purpose. Editing the list is a one-line change.
///
/// Two layers share these records:
/// - **Model validation**: trust `info.json`'s declared `model` / `type`
///   against [kSupportedDevices] — see [DeviceSpec.evaluateZip3].
/// - **Device-side guard**: BANNERS ENFORCE, SERIALS INFORM (decided
///   2026-07-19). [DeviceSpec.checkTargetMatch] requires supported firmware
///   banners and blocks on their type/model disagreement. Serial facts —
///   prefix→model decode, the
///   generic replacement-part string, cleared identity regions — are surfaced
///   via [DeviceSpec.describeBin] for the UI strip and run logs, and never
///   block. Serial-based enforcement (pairing matrix, exact-match rules) was
///   deliberately RETIRED: the BLE app owns serial provisioning (it rewrites
///   the generic serial with the bound one at 0x1F020/0x1F420), layouts vary
///   by firmware, and SWD cannot be authoritative about them. Do not rebuild
///   serial blocking without a new decision.
library;

import 'firmware.dart' show FirmwareCheck;

/// One supported controller family + the payload types we accept for it.
class SupportedDevice {
  const SupportedDevice({
    required this.model,
    required this.types,
    required this.vcuCode,
  });

  /// `info.json` `firmware.model`, compared case-insensitively.
  final String model;

  /// `info.json` `firmware.type` values accepted for this model (compared
  /// upper-cased). Today every model is VCU/MCU — never BLE/BMS.
  final Set<String> types;

  /// The 4-char code in this model's VCU firmware banner
  /// (`SCOOTER_VCU_<vcuCode>` at [kBannerOffset]). MCU firmware shares
  /// [kMcuCode] across all models, so an MCU banner can't corroborate the
  /// model — only the type.
  final String vcuCode;

  // ── Room to grow for device-side validation (no cost today) ───────────────
  // final String? displayName;      // friendly name for the UI
  // final int? slotBase;            // flash write address (e.g. 0x08001000)
  // final ({int start, int end})? identityRegion; // where identity lives
  // final List<int>? identitySignature;           // expected identity bytes
  // final String? chipId;           // AT32F415 variant / board id
}

/// Everything x3utils will flash today: X3-family controllers, VCU/MCU only.
/// NOT BLE, NOT BMS, no other models. Add/remove a row to change the policy.
const kSupportedDevices = <SupportedDevice>[
  SupportedDevice(model: 'zt3', types: {'MCU', 'VCU'}, vcuCode: 'xxU2'),
  SupportedDevice(model: 'g3', types: {'MCU', 'VCU'}, vcuCode: 'xxG3'),
  SupportedDevice(model: 'gt3', types: {'MCU', 'VCU'}, vcuCode: 'xGT3'),
  SupportedDevice(model: 'f3', types: {'MCU', 'VCU'}, vcuCode: 'xxF3'),
];

/// MCU firmware uses this one banner code across every model, so an MCU banner
/// confirms the type but not which model. ZT3/GT3/G3 share MCU hardware; F3
/// does not, but its identical banner leaves that mismatch undetectable here.
const kMcuCode = '0001';

/// The firmware banner is a fixed 16-byte ASCII string `SCOOTER_<TYPE>_<CODE>`
/// (8 + 3 + 1 + 4) at this offset in the decrypted bin.
const kBannerOffset = 0x400;
const kBannerLength = 16;

/// Same banner seen in a full 128 KB backup dump: slot 0 lives at 0x1000
/// (flash 0x08001000), so its banner is at 0x1000 + [kBannerOffset].
const kSlotBannerOffset = 0x1400;

final _bannerRe = RegExp(r'^SCOOTER_(VCU|MCU)_(.{4})$');

/// The device serial in user space: 14 ASCII chars whose 3-char PREFIX encodes
/// the model (bench-corrected 2026-07-19 — earlier notes said 15, but the 15th
/// byte was adjacent memory bleeding into the read). Stored twice
/// ([kSerialOffset] + [kSerialBackupOffset]) — the pair the BLE app rewrites
/// when it provisions a replacement part. It sits in the top-4 KB user region
/// a slot flash preserves, so it survives a slot mis-flash. INFORMATIONAL
/// ONLY: serials are BLE-app-owned and writable, so they decorate the UI/logs
/// but never gate a flash.
const kSerialOffset = 0x1F020;
const kSerialBackupOffset = 0x1F420;
const kSerialLength = 14;
const kSerialPrefixToModel = <String, String>{
  '1K1': 'zt3',
  '1CG': 'g3',
  '1EF': 'f3', // F3 / F3 pro
  '03S': 'gt3',
};

/// Factory serials of replacement VCUs, exactly as shipped (the BLE app
/// overwrites them with the bound serial on "did you replace a part?").
/// Known strings only — add per model/region as they are observed on real
/// parts; an unknown-but-valid serial is simply treated as real.
/// Bench-confirmed real/generic pairs: ZT3 org 1K1EA2510P1673, G3 org
/// 1CGCC9926C8115.
const kGenericSerials = <String>{
  '1K1E0000000001', // ZT3, Europe
  '1CGC0000000001', // G3
};

final _serialRe = RegExp(r'^[0-9A-Za-z]{14}$');

/// What a serial region turned out to hold.
enum SerialState {
  /// A shape-valid serial that is not a known factory-generic string.
  real,

  /// A known replacement-part factory serial ([kGenericSerials]).
  generic,

  /// Both serial copies are blank (all 0x00 or all 0xFF) — a cleared identity;
  /// the BLE app re-provisions on next connect.
  cleared,

  /// Nothing readable (garbage bytes, or the image is too small).
  none,
}

/// A serial read result: the [state], the raw [text] when readable, and the
/// [model] its prefix decodes to (null for unknown prefixes).
class SerialInfo {
  const SerialInfo(this.state, [this.text, this.model]);
  final SerialState state;
  final String? text;
  final String? model;

  bool get readable =>
      state == SerialState.real || state == SerialState.generic;
}

/// Outcome of checking a package's declared model/type against the allow-list.
class Zip3Verdict {
  const Zip3Verdict.accept(SupportedDevice this.device)
    : ok = true,
      reason = '';
  const Zip3Verdict.reject(this.reason) : ok = false, device = null;

  final bool ok;
  final String reason; // user-facing rejection message; '' when accepted
  final SupportedDevice? device; // the matched device when accepted
}

class DeviceSpec {
  const DeviceSpec._();

  /// Accept only a supported [model] AND a [type] that model allows. Matching
  /// is case-insensitive (model → lower, type → upper) so a stray `Zt3` / `vcu`
  /// in someone's `info.json` doesn't slip through as "unsupported". Fails
  /// closed: null/empty/unknown → reject with a user-facing reason.
  static Zip3Verdict evaluateZip3(String? model, String? type) {
    final m = (model ?? '').trim().toLowerCase();
    final t = (type ?? '').trim().toUpperCase();
    if (m.isEmpty || t.isEmpty) {
      return const Zip3Verdict.reject(
        'info.json is missing the firmware model or type.',
      );
    }
    SupportedDevice? dev;
    for (final d in kSupportedDevices) {
      if (d.model == m) {
        dev = d;
        break;
      }
    }
    if (dev == null) {
      return Zip3Verdict.reject(
        'This package is for ${m.toUpperCase()}. '
        'x3utils supports ${modelList()} only.',
      );
    }
    if (!dev.types.contains(t)) {
      return Zip3Verdict.reject(
        'Unsupported type "$type" for $m — x3utils flashes VCU/MCU only '
        '(not BLE/BMS).',
      );
    }
    return Zip3Verdict.accept(dev);
  }

  /// Friendly supported-model list for messages/UI.
  static String modelList() {
    final models = kSupportedDevices
        .map((device) => device.model.toUpperCase())
        .toList(growable: false);
    if (models.length == 1) return models.single;
    return '${models.sublist(0, models.length - 1).join(', ')}, '
        'and ${models.last}';
  }

  /// Cross-check the DECRYPTED firmware's banner (`SCOOTER_<TYPE>_<CODE>` at
  /// [kBannerOffset]) against the package's declared [model]/[type]. This reads
  /// the payload itself, so it catches a mislabeled image the metadata gate
  /// can't. [model]/[type] are assumed already accepted by [evaluateZip3].
  ///
  /// Returns a [BannerVerdict] so callers can apply their own policy. ZIP3
  /// import treats a mismatch as a hard failure; the inspection report can
  /// still present the same evidence without throwing. Verifies the type for
  /// every package, and the model for VCU (MCU shares [kMcuCode] across models,
  /// so it can't confirm the model).
  static BannerVerdict verifyBanner(
    List<int> firmware,
    String model,
    String type,
  ) {
    if (firmware.length < kBannerOffset + kBannerLength) {
      return const BannerVerdict.mismatch(
        '',
        'Firmware is too small to contain a banner at 0x400.',
      );
    }
    final raw = _bannerAt(firmware, kBannerOffset);
    if (raw == null) {
      return BannerVerdict.mismatch(
        '',
        'x3utils cannot identify this file as VCU or MCU firmware.',
      );
    }
    final banner = _supportedBannerAt(firmware, kBannerOffset);
    if (banner == null) {
      return BannerVerdict.mismatch(
        raw,
        'Unsupported firmware banner "$raw" at 0x400.',
      );
    }
    final t = type.trim().toUpperCase();
    final mo = model.trim().toLowerCase();

    if (banner.type != t) {
      return BannerVerdict.mismatch(
        banner.raw,
        'The JSON says $t, but the firmware banner says ${banner.type}.',
      );
    }
    if (banner.type == 'VCU' && banner.model != mo) {
      return BannerVerdict.mismatch(
        banner.raw,
        'The JSON says ${mo.toUpperCase()} VCU, but the firmware banner says '
        '${banner.label}.',
      );
    }
    return BannerVerdict.ok(banner.raw);
  }

  /// Device-side (pre-flash) guard — BANNERS ONLY. Compares the target's
  /// slot-0 firmware banner (from the fresh backup [dump]) against the loaded
  /// [firmware]'s banner and blocks on model or type disagreement. A missing,
  /// malformed, or unsupported banner also blocks: guarded flashing cannot
  /// claim compatibility without both identities. Only Backup + Flash and
  /// Flash slot 0 call this (they dump first); Flash Only is the deliberate
  /// expert override.
  ///
  /// Serials deliberately do NOT participate (2026-07-19): they are
  /// BLE-app-owned, layout varies by firmware, and enforcement kept producing
  /// wrong answers on real devices. Serial facts are displayed/logged via
  /// [describeBin] instead. [incomingIsSlotBin] picks the incoming banner
  /// offset (0x400 vs 0x1400).
  static TargetMatch checkTargetMatch({
    required List<int> dump,
    required List<int> firmware,
    required bool incomingIsSlotBin,
  }) {
    final incomingOffset = incomingIsSlotBin
        ? kBannerOffset
        : kSlotBannerOffset;
    final target = _supportedBannerAt(dump, kSlotBannerOffset);
    final incoming = _supportedBannerAt(firmware, incomingOffset);

    if (target == null) {
      return const TargetMatch(
        blocked: true,
        message:
            'the target backup has no supported VCU/MCU firmware banner at '
            '0x1400, so compatibility cannot be verified. Use Flash Only only '
            'as an expert override; it skips this protection.',
      );
    }
    if (incoming == null) {
      return TargetMatch(
        blocked: true,
        message:
            'the selected firmware has no supported VCU/MCU firmware banner '
            'at 0x${incomingOffset.toRadixString(16).toUpperCase()}, so '
            'compatibility cannot be verified.',
      );
    }
    if (target.type != incoming.type ||
        (target.type == 'VCU' && target.model != incoming.model)) {
      return TargetMatch(
        blocked: true,
        message:
            'the target firmware identifies as ${target.label}, but the '
            'selected firmware identifies as ${incoming.label}. Incompatible '
            'firmware can brick the controller.',
      );
    }
    if (target.type == 'MCU') {
      return const TargetMatch(
        note:
            'Both banners identify MCU firmware. The banner does not encode '
            'the MCU model: ZT3/GT3/G3 share MCU hardware, but F3 '
            'compatibility cannot be verified.',
      );
    }
    return const TargetMatch();
  }

  /// Gate for a picked or revalidated `.bin`. When [enforceBanner] (the guarded
  /// Backup + Flash / Flash slot 0 actions), the expected offset must contain a
  /// supported VCU banner code or the exact shared MCU banner
  /// `SCOOTER_MCU_0001`. Flash Only stays the deliberate expert override for
  /// unrecognized/crafted images.
  static FirmwareCheck checkIncomingBin(
    List<int> bytes, {
    required bool slotBin,
    required bool enforceBanner,
  }) {
    if (!enforceBanner) return FirmwareCheck.valid;
    final off = slotBin ? kBannerOffset : kSlotBannerOffset;
    if (_supportedBannerAt(bytes, off) == null) {
      return FirmwareCheck.fail(
        'x3utils cannot identify this file as VCU or MCU firmware.',
      );
    }
    return FirmwareCheck.valid;
  }

  /// Everything we can READ from a bin, for display and logs — enforces
  /// nothing. Works on a loaded firmware file or a target backup dump
  /// ([slotBin] false: banner at 0x1400 + serial pair; true: banner at 0x400,
  /// no serial — slot bins structurally lack one).
  static BinIdentity describeBin(List<int> bytes, {required bool slotBin}) {
    final offset = slotBin ? kBannerOffset : kSlotBannerOffset;
    final banner = _bannerAt(bytes, offset);
    final supportedBanner = _supportedBannerAt(bytes, offset);
    String? bannerModel;
    String? bannerType;
    if (banner != null) {
      final m = _bannerRe.firstMatch(banner)!;
      bannerType = m.group(1)!;
      bannerModel = _modelFromVcuCode(m.group(2)!);
    }
    return BinIdentity(
      banner: banner,
      bannerModel: bannerModel,
      bannerType: bannerType,
      bannerSupported: supportedBanner != null,
      serial: slotBin ? null : readSerial(bytes),
    );
  }

  /// Classify the serial pair at [kSerialOffset]/[kSerialBackupOffset]: a
  /// shape-valid 15-char serial (primary first, then the backup copy) is
  /// [SerialState.real] or [SerialState.generic]; both copies blank is
  /// [SerialState.cleared]; anything else is [SerialState.none].
  static SerialInfo readSerial(List<int> b) {
    for (final off in const [kSerialOffset, kSerialBackupOffset]) {
      final s = _serialTextAt(b, off);
      if (s != null) {
        return SerialInfo(
          kGenericSerials.contains(s) ? SerialState.generic : SerialState.real,
          s,
          kSerialPrefixToModel[s.substring(0, 3)],
        );
      }
    }
    if (_regionBlank(b, kSerialOffset) &&
        _regionBlank(b, kSerialBackupOffset)) {
      return const SerialInfo(SerialState.cleared);
    }
    return const SerialInfo(SerialState.none);
  }

  /// A human note when this flash changes the device serial (full-image writes
  /// only — [incoming] null means a slot write, which preserves user space).
  /// Null when nothing identity-relevant changes. Tense-free "A → B" phrasing
  /// on purpose: the same string is logged BEFORE the write (which the guard
  /// may still abort) and shown in the success message after it — it must
  /// never claim an action that has not happened.
  static String? serialChangeNote({
    required SerialInfo target,
    required SerialInfo? incoming,
  }) {
    if (incoming == null) return null;
    final from = target.readable ? target.text : '(blank)';
    if (incoming.readable) {
      if (target.readable && target.text == incoming.text) return null;
      if (incoming.state == SerialState.generic) {
        return 'device serial: $from → ${incoming.text} (generic factory '
            'serial — the app re-provisions on next connect)';
      }
      return 'device serial: $from → ${incoming.text}';
    }
    if (incoming.state == SerialState.cleared && target.readable) {
      return 'device serial: $from → cleared '
          '(the app re-provisions on next connect)';
    }
    return null;
  }

  /// The model whose VCU banner uses [code] (e.g. xxG3 → g3), or null for the
  /// shared MCU code / unknown.
  static String? _modelFromVcuCode(String code) {
    for (final d in kSupportedDevices) {
      if (d.vcuCode == code) return d.model;
    }
    return null;
  }

  /// The [kSerialLength] chars at [off] when they form a shape-valid serial,
  /// else null.
  static String? _serialTextAt(List<int> b, int off) {
    if (b.length < off + kSerialLength) return null;
    final s = String.fromCharCodes(b.sublist(off, off + kSerialLength));
    return _serialRe.hasMatch(s) ? s : null;
  }

  /// True when the serial region at [off] exists and is uniformly blank
  /// (all 0x00 or all 0xFF — written-zeros vs erased flash).
  static bool _regionBlank(List<int> b, int off) {
    if (b.length < off + kSerialLength) return false;
    final region = b.sublist(off, off + kSerialLength);
    return region.every((v) => v == 0x00) || region.every((v) => v == 0xFF);
  }

  /// A valid `SCOOTER_<TYPE>_<CODE>` banner at [off], or null if absent/garbage.
  static String? _bannerAt(List<int> b, int off) {
    if (b.length < off + kBannerLength) return null;
    final s = String.fromCharCodes(b.sublist(off, off + kBannerLength));
    return _bannerRe.hasMatch(s) ? s : null;
  }

  static _SupportedBanner? _supportedBannerAt(List<int> b, int off) {
    final raw = _bannerAt(b, off);
    if (raw == null) return null;
    final match = _bannerRe.firstMatch(raw)!;
    final type = match.group(1)!;
    final code = match.group(2)!;
    if (type == 'MCU') {
      return code == kMcuCode ? _SupportedBanner(raw: raw, type: type) : null;
    }
    final model = _modelFromVcuCode(code);
    return model == null
        ? null
        : _SupportedBanner(raw: raw, type: type, model: model);
  }
}

class _SupportedBanner {
  const _SupportedBanner({required this.raw, required this.type, this.model});

  final String raw;
  final String type;
  final String? model;

  String get label => type == 'MCU' ? 'MCU' : '${model!.toUpperCase()} VCU';
}

/// Result of [DeviceSpec.checkTargetMatch]. [blocked] is true on an unsupported
/// identity or a confirmed target/firmware mismatch; [note] carries an
/// informational limitation for an otherwise-allowed match.
class TargetMatch {
  const TargetMatch({this.blocked = false, this.message = '', this.note});
  final bool blocked;
  final String message; // block reason (when blocked)
  final String? note; // informational reason the check was skipped
}

/// Readable identity facts from one bin (a loaded firmware file or a target
/// backup dump) — display/log material only, never a verdict. Built by
/// [DeviceSpec.describeBin].
class BinIdentity {
  const BinIdentity({
    this.banner,
    this.bannerModel,
    this.bannerType,
    this.bannerSupported = false,
    this.serial,
  });

  final String? banner; // raw 16-char banner, null when absent/garbage
  final String? bannerModel; // zt3/g3/... for VCU banners with a known code
  final String? bannerType; // VCU | MCU
  final bool bannerSupported;
  final SerialInfo? serial; // null for slot bins (structurally no serial)

  /// Friendly identity read from the firmware banner, without claiming target
  /// compatibility. Unknown-but-shaped banners retain their raw evidence.
  String get bannerLabel {
    if (bannerType == 'VCU') {
      return bannerModel != null
          ? '${bannerModel!.toUpperCase()} · VCU'
          : 'VCU · unsupported code';
    }
    if (bannerType == 'MCU') {
      return bannerSupported ? 'MCU' : 'MCU · unsupported code';
    }
    return 'Not found';
  }

  /// The serial's decoded model contradicts the banner's (both known).
  bool get serialModelClash =>
      serial?.model != null &&
      bannerModel != null &&
      serial!.model != bannerModel;

  /// Amber-worthy: a generic (replacement-part) or cleared serial, or a
  /// serial-vs-banner model contradiction. Purely presentation severity.
  bool get warn =>
      serial?.state == SerialState.generic ||
      serial?.state == SerialState.cleared ||
      serialModelClash;

  /// The banner half of [summary] on its own, or null when no banner is
  /// readable. Make zip3 shows this instead of the full summary: it packs
  /// slot 0 only, and the serial pair at [kSerialOffset] sits outside that
  /// payload, so serial state cannot affect the package. Showing it there
  /// raised an amber warning about something the action cannot change (and
  /// a three-line one, which pushed the CTA off a 768px window). Serial facts
  /// stay in [logLine] for the run log.
  String? get bannerSummary {
    if (bannerType == 'VCU') {
      return bannerModel != null
          ? '${bannerModel!.toUpperCase()} · VCU'
          : 'VCU ($banner)';
    }
    if (bannerType == 'MCU') return 'MCU';
    return null;
  }

  /// One line for the firmware-bar strip (caller adds the "Firmware says:"
  /// label), or null when nothing identity-readable is worth showing.
  String? get summary {
    final parts = <String>[];
    final bannerPart = bannerSummary;
    if (bannerPart != null) {
      parts.add(bannerPart);
    } else if (serial != null) {
      parts.add('no firmware banner');
    }
    final s = serial;
    if (s != null) {
      switch (s.state) {
        case SerialState.real:
          parts.add(
            'serial ${s.text}${s.model != null ? ' → ${s.model!.toUpperCase()}' : ''}',
          );
        case SerialState.generic:
          parts.add('serial ${s.text} — generic / replacement part');
        case SerialState.cleared:
          parts.add(
            'serial cleared — erases device identity; '
            'the app re-provisions on next connect',
          );
        case SerialState.none:
          parts.add('no readable serial');
      }
      if (serialModelClash) {
        parts.add(
          'serial model ${s.model!.toUpperCase()} disagrees with '
          'the firmware banner',
        );
      }
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Verbose one-liner for the run log.
  String get logLine {
    final b = banner == null ? 'banner: none' : 'banner: $banner';
    final s = serial;
    final ser = s == null
        ? 'serial: n/a (slot bin)'
        : switch (s.state) {
            SerialState.real =>
              'serial: ${s.text} (model ${s.model ?? 'unknown'})',
            SerialState.generic =>
              'serial: ${s.text} (generic replacement, model ${s.model ?? 'unknown'})',
            SerialState.cleared => 'serial: cleared',
            SerialState.none => 'serial: unreadable',
          };
    return '$b · $ser';
  }
}

/// Result of [DeviceSpec.verifyBanner]: whether the firmware's own banner is
/// consistent with the package label. The caller decides whether a mismatch is
/// a hard failure or an observed finding.
class BannerVerdict {
  const BannerVerdict.ok(this.banner) : consistent = true, message = '';
  const BannerVerdict.mismatch(this.banner, this.message) : consistent = false;

  final bool consistent;
  final String banner; // the 16 bytes read at 0x400 (may be garbage/unreadable)
  final String message; // warning text when inconsistent
}
