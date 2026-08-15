import 'device_spec.dart';
import 'zp_extract.dart';

/// A package's own identity claim, kept separate from evidence in its decrypted
/// payload.
class PackageClaim {
  const PackageClaim({
    required this.model,
    required this.type,
    this.displayName,
  });

  final String model;
  final String type;
  final String? displayName;

  String get label {
    final m = model.trim();
    final t = type.trim().toUpperCase();
    if (m.isEmpty && t.isEmpty) return 'Not declared';
    if (m.isEmpty) return t;
    if (t.isEmpty) return m.toUpperCase();
    return '${m.toUpperCase()} · $t';
  }
}

/// One independent compatibility observation that an action policy may block
/// or allow as an expert override.
class CompatibilityFinding {
  const CompatibilityFinding(this.code, this.message);

  final String code;
  final String message;
}

/// Read-only evidence collected from a structurally readable firmware source.
///
/// This report deliberately does not decide whether flashing is allowed.
/// Backup + Flash / guarded slot flashing may turn a finding into a hard stop;
/// Flash Only may present the same finding as an explicit override.
class FirmwareInspection {
  const FirmwareInspection({
    required this.slotBin,
    required this.identity,
    required this.zp,
    required this.findings,
    this.packageClaim,
  });

  final bool slotBin;
  final BinIdentity identity;
  final ZpInspection zp;
  final PackageClaim? packageClaim;
  final List<CompatibilityFinding> findings;

  bool get hasFindings => findings.isNotEmpty;

  String get bannerValue {
    final raw = identity.banner;
    if (raw == null) return 'Not found';
    if (!identity.bannerSupported) return 'Unsupported · $raw';
    return '${identity.bannerLabel} · $raw';
  }

  String get serialValue {
    final serial = identity.serial;
    if (serial == null) return 'Not present in a slot image';
    return switch (serial.state) {
      SerialState.real =>
        '${serial.text}${serial.model == null ? '' : ' · prefix suggests ${serial.model!.toUpperCase()}'}',
      SerialState.generic => '${serial.text} · generic replacement-part serial',
      SerialState.cleared => 'Cleared',
      SerialState.none => 'Unreadable',
    };
  }

  String get zpValue => switch (zp.state) {
    ZpRecordState.notApplicable => 'Not present in a slot image',
    ZpRecordState.readable =>
      'Readable · declares a ${zp.payloadLength}-byte payload',
    ZpRecordState.conflicting => 'Conflicting firmware-size records',
    ZpRecordState.unavailable => 'No trustworthy length record found',
    ZpRecordState.fullImageRequired => 'Full 128 KB image required',
  };

  String? get zpDetail => zp.state == ZpRecordState.readable
      ? 'Record freshness cannot be determined.'
      : null;
}

class FirmwareInspector {
  const FirmwareInspector._();

  /// Inspect a bin or decrypted ZIP3 payload after its objective structural
  /// checks have passed.
  static FirmwareInspection inspect(
    List<int> bytes, {
    required bool slotBin,
    PackageClaim? packageClaim,
  }) {
    final identity = DeviceSpec.describeBin(bytes, slotBin: slotBin);
    final zp = slotBin ? const ZpInspection.notApplicable() : Zp.inspect(bytes);
    final findings = <CompatibilityFinding>[];

    if (packageClaim == null) {
      if (identity.banner == null) {
        findings.add(
          const CompatibilityFinding(
            'banner_missing',
            'x3utils cannot identify this file as VCU or MCU firmware.',
          ),
        );
      } else if (!identity.bannerSupported) {
        findings.add(
          CompatibilityFinding(
            'banner_unsupported',
            'The selected file contains an unsupported firmware banner: '
                '"${identity.banner}".',
          ),
        );
      }
    } else {
      final packageVerdict = DeviceSpec.evaluateZip3(
        packageClaim.model,
        packageClaim.type,
      );
      if (!packageVerdict.ok) {
        findings.add(
          CompatibilityFinding(
            'package_identity_unsupported',
            packageVerdict.reason,
          ),
        );
      }

      final type = packageClaim.type.trim().toUpperCase();
      if (packageClaim.model.trim().isNotEmpty &&
          (type == 'VCU' || type == 'MCU')) {
        final bannerVerdict = DeviceSpec.verifyBanner(
          bytes,
          packageClaim.model,
          type,
        );
        if (!bannerVerdict.consistent) {
          findings.add(
            CompatibilityFinding(
              'package_payload_mismatch',
              bannerVerdict.message,
            ),
          );
        }
      }
    }

    final serial = identity.serial;
    if (serial != null) {
      if (serial.state == SerialState.generic) {
        findings.add(
          const CompatibilityFinding(
            'serial_generic',
            'The file contains a generic replacement-part serial.',
          ),
        );
      } else if (serial.state == SerialState.cleared) {
        findings.add(
          const CompatibilityFinding(
            'serial_cleared',
            'The file contains cleared serial fields.',
          ),
        );
      } else if (serial.state == SerialState.none) {
        findings.add(
          const CompatibilityFinding(
            'serial_unreadable',
            'No readable serial was found in the selected full image.',
          ),
        );
      }
      if (identity.serialModelClash) {
        findings.add(
          CompatibilityFinding(
            'serial_banner_mismatch',
            'The serial prefix suggests ${serial.model!.toUpperCase()}, but '
                'the firmware banner identifies as ${identity.bannerLabel}.',
          ),
        );
      }
    }

    switch (zp.state) {
      case ZpRecordState.conflicting:
        findings.add(
          const CompatibilityFinding(
            'zp_conflicting',
            'The file contains conflicting firmware-size records.',
          ),
        );
        break;
      case ZpRecordState.unavailable:
        findings.add(
          const CompatibilityFinding(
            'zp_unavailable',
            'No trustworthy firmware-length record was found in the selected '
                'full image.',
          ),
        );
        break;
      case ZpRecordState.fullImageRequired:
        findings.add(
          const CompatibilityFinding(
            'zp_full_image_required',
            'The firmware-length record can only be checked in a full 128 KB '
                'image.',
          ),
        );
        break;
      case ZpRecordState.notApplicable:
      case ZpRecordState.readable:
        break;
    }

    return FirmwareInspection(
      slotBin: slotBin,
      identity: identity,
      zp: zp,
      packageClaim: packageClaim,
      findings: List<CompatibilityFinding>.unmodifiable(findings),
    );
  }
}
