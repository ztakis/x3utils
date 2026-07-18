/// The single source of truth for which zip3 packages x3utils will flash.
///
/// **Change your mind HERE** — one file, compiled + code-reviewed + versioned
/// with the app. This is a *safety allow-list*: a wrong-model firmware can brick
/// a controller, so it lives in code (not a runtime config that could be edited
/// to bypass the gate) on purpose. Editing the list is a one-line change.
///
/// Two layers of validation share these records:
/// - **Model validation** (now): trust `info.json`'s declared `model` / `type`
///   against [kSupportedDevices] — see [DeviceSpec.evaluateZip3].
/// - **Device validation** (future, "more precise"): read the connected chip's
///   own identity and confirm it matches the package. That check will hang off
///   the same [SupportedDevice] records (add fields, no restructure).
library;

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

/// MCU firmware uses this one banner code across every model (so an MCU banner
/// confirms the type but not which model).
const kMcuCode = '0001';

/// The firmware banner is a fixed 16-byte ASCII string `SCOOTER_<TYPE>_<CODE>`
/// (8 + 3 + 1 + 4) at this offset in the decrypted bin.
const kBannerOffset = 0x400;
const kBannerLength = 16;
final _bannerRe = RegExp(r'^SCOOTER_(VCU|MCU)_(.{4})$');

/// Outcome of checking a package's declared model/type against the allow-list.
class Zip3Verdict {
  const Zip3Verdict.accept(SupportedDevice this.device)
      : ok = true,
        reason = '';
  const Zip3Verdict.reject(this.reason)
      : ok = false,
        device = null;

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
          'info.json is missing the firmware model or type.');
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
          'Unsupported model "$model" — x3utils flashes ${modelList()} only.');
    }
    if (!dev.types.contains(t)) {
      return Zip3Verdict.reject(
          'Unsupported type "$type" for $m — x3utils flashes VCU/MCU only '
          '(not BLE/BMS).');
    }
    return Zip3Verdict.accept(dev);
  }

  /// Comma-separated supported models, for messages/UI.
  static String modelList() => kSupportedDevices.map((d) => d.model).join(', ');

  /// Cross-check the DECRYPTED firmware's banner (`SCOOTER_<TYPE>_<CODE>` at
  /// [kBannerOffset]) against the package's declared [model]/[type]. This reads
  /// the payload itself, so it catches a mislabeled image the metadata gate
  /// can't. [model]/[type] are assumed already accepted by [evaluateZip3].
  ///
  /// Soft by design: returns a [BannerVerdict] rather than throwing. Verifies
  /// the type for every package, and the model for VCU (MCU shares [kMcuCode]
  /// across models, so it can't confirm the model).
  static BannerVerdict verifyBanner(List<int> firmware, String model, String type) {
    if (firmware.length < kBannerOffset + kBannerLength) {
      return const BannerVerdict.mismatch('',
          'Firmware is too small to contain a banner at 0x400.');
    }
    final banner = String.fromCharCodes(
        firmware.sublist(kBannerOffset, kBannerOffset + kBannerLength));
    final m = _bannerRe.firstMatch(banner);
    if (m == null) {
      return BannerVerdict.mismatch(
          banner, 'No SCOOTER_<TYPE>_<CODE> banner found at 0x400.');
    }
    final bannerType = m.group(1)!; // VCU | MCU
    final bannerCode = m.group(2)!;
    final t = type.trim().toUpperCase();
    final mo = model.trim().toLowerCase();

    if (bannerType != t) {
      return BannerVerdict.mismatch(banner,
          'Firmware banner is $bannerType but the package claims $t.');
    }
    if (bannerType == 'VCU') {
      final expected = _codeFor(mo);
      if (expected != null && bannerCode != expected) {
        return BannerVerdict.mismatch(
            banner,
            'Firmware banner code "$bannerCode" does not match model $mo '
            '(expected "$expected").');
      }
    } else if (bannerCode != kMcuCode) {
      return BannerVerdict.mismatch(banner,
          'MCU banner code "$bannerCode" is unexpected (expected "$kMcuCode").');
    }
    return BannerVerdict.ok(banner);
  }

  static String? _codeFor(String modelLower) {
    for (final d in kSupportedDevices) {
      if (d.model == modelLower) return d.vcuCode;
    }
    return null;
  }
}

/// Result of [DeviceSpec.verifyBanner]: whether the firmware's own banner is
/// consistent with the package label (soft — a mismatch is a warning).
class BannerVerdict {
  const BannerVerdict.ok(this.banner)
      : consistent = true,
        message = '';
  const BannerVerdict.mismatch(this.banner, this.message) : consistent = false;

  final bool consistent;
  final String banner; // the 16 bytes read at 0x400 (may be garbage/unreadable)
  final String message; // warning text when inconsistent
}
