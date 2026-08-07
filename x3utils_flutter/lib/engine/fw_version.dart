/// Firmware version identification from the image itself.
///
/// The OEM version is a 16-bit immediate loaded into a register, encoded one
/// nibble per field: `1.6.3` → `0x163`. Because the value is DERIVED from the
/// version number, a row here needs no sample — ZT3 1.5.9 can be searched for
/// without ever having held a 1.5.9 bin.
///
/// Measured over 26 mirror builds (2026-08-07), searching a payload for the
/// values of that model's REAL RELEASED versions returns exactly one distinct
/// version, every time. Two things make that work and both are load-bearing:
///
/// - **Both encodings must be decoded.** 8 of 26 builds use `MOVW`, 18 use
///   `MOV.W` with a ThumbExpandImm-encoded constant. A decoder that handles one
///   form finds barely a third of them and reports confident wrong answers.
/// - **Candidates must be REAL released versions, never a numeric range.**
///   Version-shaped constants are everywhere in these images — `0x147`, `0x16D`,
///   `0x18F` and `0x1EB` appear in nearly every build. They are not versions
///   anyone shipped, so an enumerated list never sees them, while a range check
///   ("anything ≥ 1.5.9") would match the decoys and refuse every device.
///
/// The destination register is NOT fixed (r0 everywhere except gt3 VCU 1.5.8,
/// which uses r1) and the offset moves unpredictably between builds — g3 VCU
/// swings ±4 KB between consecutive releases — so neither may be assumed.
library;

/// A `major.minor.patch` version whose fields each fit one nibble.
///
/// OEM patch numbers never exceed x.x.15, so the nibble encoding has no
/// overflow case.
class FwVersion implements Comparable<FwVersion> {
  const FwVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// The immediate as it appears in the instruction stream.
  int get value => (major << 8) | (minor << 4) | patch;

  /// Null when any field is out of nibble range, so a malformed table entry
  /// fails to parse instead of silently encoding to the wrong constant.
  static FwVersion? parse(String s) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(s.trim());
    if (m == null) return null;
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    final c = int.parse(m.group(3)!);
    if (a > 15 || b > 15 || c > 15) return null;
    return FwVersion(a, b, c);
  }

  @override
  int compareTo(FwVersion other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is FwVersion && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$major.$minor.$patch';
}

/// What the scan concluded about an image.
enum FwVerdict {
  /// Exactly one known version matched.
  identified,

  /// A version on the known-bad list matched. Checked FIRST, so this wins over
  /// identification and does not depend on the known list being complete.
  blacklisted,

  /// No listed version matched. A build we have never catalogued — including
  /// every future release — lands here.
  unknown,

  /// Two or more DISTINCT versions matched, so the image cannot be named.
  ambiguous,
}

/// The scan result. [version] is set for [FwVerdict.identified] and
/// [FwVerdict.blacklisted]; [matches] carries every distinct hit so an
/// ambiguous result can be reported rather than guessed at.
class FwIdentity {
  const FwIdentity(this.verdict, {this.version, this.matches = const []});

  final FwVerdict verdict;
  final FwVersion? version;
  final List<FwVersion> matches;

  /// True when the image must not be written to or patched on this evidence.
  bool get blocked => verdict == FwVerdict.blacklisted;

  /// True when the operator has to decide (or the caller's policy does).
  bool get uncertain =>
      verdict == FwVerdict.unknown || verdict == FwVerdict.ambiguous;

  String get logLine => switch (verdict) {
    FwVerdict.identified => 'firmware version: $version',
    FwVerdict.blacklisted => 'firmware version: $version (not supported)',
    FwVerdict.unknown => 'firmware version: not recognised',
    FwVerdict.ambiguous =>
      'firmware version: ambiguous (${matches.join(', ')})',
  };
}

/// Known and known-bad versions per `<model>/<type>`.
///
/// KNOWN is for naming what we found; BLACKLIST is what refuses. They are
/// deliberately separate lists, and the blacklist is checked first: safety then
/// depends only on the blacklist being complete, never on the known list. An
/// incomplete known list costs a name, not a guard.
///
/// Rows marked "verified" were decoded out of a real bin; the rest come from
/// the OEM changelog, which is legitimate precisely because the constant is
/// derived from the version number rather than measured.
class FwVersionMatrix {
  const FwVersionMatrix._();

  static String key(String model, String type) =>
      '${model.toLowerCase()}/${type.toUpperCase()}';

  /// Every version we can name. Verified rows are marked; unverified rows are
  /// changelog entries we have no sample for.
  static const known = <String, List<String>>{
    // ZT3 VCU: full released list from the OEM update log. 1.4.11 / 1.4.15 /
    // 1.5.2 / 1.5.5 verified against real bins.
    'zt3/VCU': [
      '1.4.3',
      '1.4.5',
      '1.4.8',
      '1.4.10',
      '1.4.11',
      '1.4.14',
      '1.4.15',
      '1.5.2',
      '1.5.3',
      '1.5.5',
      '1.5.7',
      '1.5.8',
      '1.5.9',
    ],
    'zt3/MCU': [
      '1.2.4',
      '1.2.8',
      '1.2.11',
      '1.4.3',
      '1.5.2',
    ], // verified; list incomplete
    'g3/VCU': [
      '1.4.8',
      '1.5.4',
      '1.5.5',
      '1.5.6',
      '1.5.8',
      '1.5.13',
      '1.5.15',
      '1.6.1',
      '1.6.2',
      '1.6.3',
    ], // all verified; list incomplete
    'g3/MCU': [
      '1.3.15',
      '1.4.8',
      '1.4.12',
      '1.5.0',
      '1.5.7',
    ], // verified; incomplete
    'f3/VCU': [
      '1.5.4',
      '1.5.5',
      '1.5.6',
      '1.5.8',
      '1.5.13',
      '1.6.0',
      '1.6.1',
      '1.6.2',
    ], // verified; incomplete
    'f3/MCU': ['1.4.1', '1.4.5', '1.4.12', '1.5.0'], // verified; incomplete
    'gt3/VCU': ['1.5.8'], // verified; GT3 is refused at the banner regardless
    'gt3/MCU': ['1.8.4'], // verified; incomplete
  };

  /// Versions SHU compat must refuse, enumerated from the ceilings in the
  /// compat warning. Never express these as "this version and newer": a numeric
  /// range matches the ubiquitous decoy constants and would refuse everything.
  /// A newer release that is not listed here is also absent from [known], so it
  /// resolves to [FwVerdict.unknown] and is handled by the caller's policy.
  static const blacklist = <String, List<String>>{
    'zt3/VCU': ['1.5.9'],
    'g3/VCU': ['1.6.3'],
    'f3/VCU': ['1.6.3'],
  };

  /// Models with no supported version at all. GT3 never carried the mechanism
  /// SHU compat depends on, so it is refused on the banner before any version
  /// work happens.
  static const unsupportedModels = <String>{'gt3'};

  static List<FwVersion> _versions(Map<String, List<String>> table, String k) =>
      (table[k] ?? const <String>[])
          .map(FwVersion.parse)
          .whereType<FwVersion>()
          .toList();

  static List<FwVersion> knownFor(String model, String type) =>
      _versions(known, key(model, type));

  static List<FwVersion> blacklistFor(String model, String type) =>
      _versions(blacklist, key(model, type));
}

/// Decodes 16-bit immediate loads out of a Thumb-2 instruction stream and
/// matches them against a candidate set.
class FwVersionScanner {
  const FwVersionScanner._();

  /// Identify [payload] — a SLOT PAYLOAD, not a full dump.
  ///
  /// Pass slot 0 only. A full 128 KB dump also contains slot 1's OTA copy,
  /// which may hold the PREVIOUS firmware; scanning both would surface two
  /// distinct versions and report [FwVerdict.ambiguous] for a perfectly normal
  /// device. Repeated hits on the SAME version are harmless and expected.
  static FwIdentity identify(
    List<int> payload, {
    required String model,
    required String type,
  }) {
    final blacklist = FwVersionMatrix.blacklistFor(model, type);
    final found = _scan(payload, {
      for (final v in blacklist) v.value: v,
      for (final v in FwVersionMatrix.knownFor(model, type)) v.value: v,
    });

    // Blacklist first and unconditionally: a known-bad hit refuses even when
    // the image also matches something else, and does not wait on the known
    // list being complete.
    for (final v in blacklist) {
      if (found.contains(v)) {
        return FwIdentity(FwVerdict.blacklisted, version: v, matches: found);
      }
    }
    if (found.isEmpty) return const FwIdentity(FwVerdict.unknown);
    if (found.length > 1) {
      return FwIdentity(FwVerdict.ambiguous, matches: found);
    }
    return FwIdentity(
      FwVerdict.identified,
      version: found.single,
      matches: found,
    );
  }

  /// Distinct candidate versions present in [bytes], in ascending order.
  static List<FwVersion> _scan(List<int> bytes, Map<int, FwVersion> wanted) {
    if (wanted.isEmpty) return const [];
    final hits = <int, FwVersion>{};
    for (var i = 0; i + 3 < bytes.length; i += 2) {
      final value = _immediateAt(bytes, i);
      if (value == null) continue;
      final v = wanted[value];
      if (v != null) hits[value] = v;
    }
    final out = hits.values.toList()..sort();
    return out;
  }

  /// The constant loaded by the 32-bit Thumb-2 instruction at [i], or null.
  ///
  /// Covers both forms the corpus actually uses. The destination register is
  /// read but deliberately ignored — it varies between builds of the same
  /// model, so keying on it would false-refuse whole model lines.
  static int? _immediateAt(List<int> b, int i) {
    final hw1 = b[i] | (b[i + 1] << 8);
    final hw2 = b[i + 2] | (b[i + 3] << 8);
    if (hw2 & 0x8000 != 0) return null; // not a 32-bit Thumb-2 second halfword

    // MOVW Rd,#imm16 — 1111 0i10 0100 imm4 : 0 imm3 Rd imm8
    if (hw1 & 0xFBF0 == 0xF240) {
      return ((hw1 & 0xF) << 12) |
          (((hw1 >> 10) & 1) << 11) |
          (((hw2 >> 12) & 7) << 8) |
          (hw2 & 0xFF);
    }
    // MOV.W Rd,#const — 1111 0i00 010S 1111 : 0 imm3 Rd imm8
    if (hw1 & 0xFBEF == 0xF04F) {
      return _thumbExpandImm(
        (((hw1 >> 10) & 1) << 11) | (((hw2 >> 12) & 7) << 8) | (hw2 & 0xFF),
      );
    }
    return null;
  }

  /// ARM's ThumbExpandImm: the 12-bit field is either a repeating byte pattern
  /// or an 8-bit value with its top bit set, rotated right.
  static int _thumbExpandImm(int imm12) {
    if (imm12 & 0xC00 == 0) {
      final v = imm12 & 0xFF;
      return switch ((imm12 >> 8) & 3) {
        0 => v,
        1 => (v << 16) | v,
        2 => (v << 24) | (v << 8),
        _ => (v << 24) | (v << 16) | (v << 8) | v,
      };
    }
    final unrotated = 0x80 | (imm12 & 0x7F);
    final rot = (imm12 >> 7) & 0x1F;
    return ((unrotated >> rot) | (unrotated << (32 - rot))) & 0xFFFFFFFF;
  }
}
