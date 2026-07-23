// Generates the synthetic test bins ("folder 10" set) for x3utils validation
// testing, plus gen_manifest.csv naming the knob each file turns and the
// verdict the app is expected to reach.
//
// Layout constants below are CORPUS-DERIVED: measured on real hardware dumps
// and repo bins (byte survey 2026-07-23), deliberately NOT imported from
// lib/engine. The generator is an independent statement of the bin layout, so
// an engine constant that drifts from the hardware makes a test fail instead
// of silently agreeing with the code under test. Real files (OEM dumps,
// rescue bins, the pre-existing zip3) stay in the set to pin constants and
// formats; each synthetic pins one logic branch — it differs from its accept
// baseline by exactly one knob.
//
// Usage (from x3utils_flutter/):
//   dart run tool/gen_test_bins.dart <out_dir> [known_good_zip3]
//
// The zip3 mutation cases derive from a known-good zip3 package; when the
// second argument is omitted the tool looks for
// 6_zt3_vcu_v1.5.2_Compat_existing.zip in <out_dir> and <out_dir>/../10.
// Real-file copies (17*) are taken from the corpus at <out_dir>/.. when
// present and skipped otherwise.
//
// Synthetic images are unflashable garbage by construction (random payload)
// and additionally carry an ASCII marker inside the payload at +0x800.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

// ── Corpus-derived layout (real dumps + repo bins, 2026-07-23) ──────────────
const kFullSize = 131072;
const kSlot0Off = 0x1000; // flash 0x08001000
const kBannerOff = 0x400; // in a slot payload; 0x1400 in a full image
const kVcuSlot1Base = 0x10000; // banner repeats at 0x10400 on every VCU dump
const kMcuSlot1Base = 0x10800; // banner repeats at 0x10C00 on the MCU dump
const kKeyOff = 0x420; // 16-byte firmware key (0x1420 in a full image)
const kRandOff = 0x430; // 6-byte device rand follows the key
const kClearedKeyRandLen = 22; // cleared state = 22 x 0xFF (key + rand)
const kSerialOff = 0x1F020;
const kSerialBackupOff = 0x1F420;
const kZpOff = 0x1F800; // "ZP" 00*6, LE u32 at +8 = encrypted len = payload+4
const kPayloadLen = 58436; // ≡4 (mod 8), inside observed real span 56372–61436

const kShuKeyHex = 'FE801CB2D1EF41A6A41731F5A06824F0';
const kMarker = 'SYNTHETIC-TEST-BIN-DO-NOT-FLASH';
const kMarkerOff = 0x800; // gate-neutral spot inside the payload

const kBannerZt3Vcu = 'SCOOTER_VCU_xxU2';
const kBannerGt3Vcu = 'SCOOTER_VCU_xGT3';
const kBannerMcu = 'SCOOTER_MCU_0001';
const kBannerUnknown = 'SCOOTER_VCU_xxZ9'; // shape-valid, unsupported code

const kSerialZt3Generic = '1K1E0000000001';
const kSerialGt3 = '03S00000000001';
const kSerialMcuPart = 'Z025A400000001';

const kZip3SourceName = '6_zt3_vcu_v1.5.2_Compat_existing.zip';

// ── Deterministic bytes (xorshift32; stable across Dart SDKs) ───────────────
class Rng {
  Rng(int seed) : _s = seed == 0 ? 0x9E3779B9 : seed & 0xFFFFFFFF;
  int _s;

  int _next() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    return _s = x;
  }

  void fill(Uint8List b) {
    for (var i = 0; i < b.length; i++) {
      b[i] = _next() & 0xFF;
    }
  }

  String text(String alphabet, int n) => String.fromCharCodes([
    for (var i = 0; i < n; i++) alphabet.codeUnitAt(_next() % alphabet.length),
  ]);
}

int seedOf(String name) {
  var h = 2166136261;
  for (final c in name.codeUnits) {
    h = ((h ^ c) * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

Uint8List asciiBytes(String s) => Uint8List.fromList(s.codeUnits);

// ── Builders ────────────────────────────────────────────────────────────────
enum KeyState { blank, shu, oemStyle }

/// A slot-0 payload: seeded-random bytes, optional banner at 0x400, key+rand
/// region at 0x420 per [key], marker at 0x800.
Uint8List payload(
  String seedName, {
  String? banner = kBannerZt3Vcu,
  int size = kPayloadLen,
  KeyState key = KeyState.blank,
}) {
  final rng = Rng(seedOf(seedName));
  final b = Uint8List(size);
  rng.fill(b);
  if (banner != null) {
    assert(banner.length == 16);
    b.setAll(kBannerOff, asciiBytes(banner));
  }
  switch (key) {
    case KeyState.blank:
      b.fillRange(kKeyOff, kKeyOff + kClearedKeyRandLen, 0xFF);
    case KeyState.shu:
      for (var i = 0; i < 16; i++) {
        b[kKeyOff + i] = int.parse(
          kShuKeyHex.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
      }
      b.fillRange(kRandOff, kRandOff + 6, 0xFF);
    case KeyState.oemStyle:
      // Real OEM keys: 16 lowercase alnum; rand: 6 mixed-case alnum.
      b.setAll(
        kKeyOff,
        asciiBytes(rng.text('abcdefghijklmnopqrstuvwxyz0123456789', 16)),
      );
      b.setAll(
        kRandOff,
        asciiBytes(
          rng.text(
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789',
            6,
          ),
        ),
      );
  }
  if (size > kMarkerOff + kMarker.length) {
    b.setAll(kMarkerOff, asciiBytes(kMarker));
  }
  return b;
}

enum ZpMode { valid, zero, allFf, absurd }

/// A full 128 KB image: 0xFF fill, [pay] at 0x1000, slot-1 copy at the
/// per-type base, serial pair, ZP record, optional decoy ZP record.
Uint8List fullImage(
  Uint8List pay, {
  bool mcu = false,
  String? serial = kSerialZt3Generic,
  ZpMode zp = ZpMode.valid,
  List<(int off, int encLen)> zpDecoys = const [],
}) {
  final b = Uint8List(kFullSize)..fillRange(0, kFullSize, 0xFF);
  b.setAll(kSlot0Off, pay);
  final slot1 = mcu ? kMcuSlot1Base : kVcuSlot1Base;
  b.setAll(slot1, pay.sublist(0, min(pay.length, 0x1F000 - slot1)));
  if (serial != null) {
    assert(serial.length == 14);
    b.setAll(kSerialOff, asciiBytes(serial));
    b.setAll(kSerialBackupOff, asciiBytes(serial));
  }
  void zpRecord(int off, int encLen) {
    b[off] = 0x5A; // Z
    b[off + 1] = 0x50; // P
    b.fillRange(off + 2, off + 8, 0x00);
    b[off + 8] = encLen & 0xFF;
    b[off + 9] = (encLen >> 8) & 0xFF;
    b[off + 10] = (encLen >> 16) & 0xFF;
    b[off + 11] = (encLen >> 24) & 0xFF;
  }

  switch (zp) {
    case ZpMode.valid:
      zpRecord(kZpOff, pay.length + 4);
    case ZpMode.zero:
      zpRecord(kZpOff, 0);
    case ZpMode.allFf:
      break; // identity page stays 0xFF
    case ZpMode.absurd:
      zpRecord(kZpOff, 0x30000);
  }
  for (final d in zpDecoys) {
    zpRecord(d.$1, d.$2);
  }
  return b;
}

// ── Zip3 mutation helpers ───────────────────────────────────────────────────
List<MapEntry<String, Uint8List>> readZipEntries(Uint8List zipBytes) {
  final a = ZipDecoder().decodeBytes(zipBytes);
  return [
    for (final f in a.files)
      if (f.isFile)
        MapEntry(f.name, Uint8List.fromList(f.content as List<int>)),
  ];
}

Uint8List writeZipEntries(List<MapEntry<String, Uint8List>> entries) {
  final a = Archive();
  for (final e in entries) {
    a.add(ArchiveFile.bytes(e.key, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

List<MapEntry<String, Uint8List>> editInfo(
  List<MapEntry<String, Uint8List>> entries,
  void Function(Map<String, dynamic> info) edit,
) {
  return [
    for (final e in entries)
      if (e.key == 'info.json')
        MapEntry(e.key, () {
          final info = jsonDecode(utf8.decode(e.value)) as Map<String, dynamic>;
          edit(info);
          return Uint8List.fromList(
            utf8.encode(const JsonEncoder.withIndent('    ').convert(info)),
          );
        }())
      else
        e,
  ];
}

// ── Output plumbing ─────────────────────────────────────────────────────────
late Directory outDir;
final manifest = <List<String>>[];

void emit(
  String relName,
  Uint8List bytes,
  String group,
  String knob,
  String expected,
) {
  final f = File('${outDir.path}${Platform.pathSeparator}$relName');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  manifest.add([
    relName,
    group,
    knob,
    expected,
    bytes.length.toString(),
    sha256.convert(bytes).toString(),
  ]);
  stdout.writeln('  ${relName.padRight(52)} ${bytes.length} B');
}

void copyReal(
  Directory corpusRoot,
  String srcRel,
  String destName,
  String knob,
  String expected,
) {
  final src = File(
    '${corpusRoot.path}${Platform.pathSeparator}${srcRel.replaceAll('/', Platform.pathSeparator)}',
  );
  if (!src.existsSync()) {
    stdout.writeln('  SKIP $destName (source not found: $srcRel)');
    return;
  }
  emit(destName, src.readAsBytesSync(), 'real-copy', knob, expected);
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/gen_test_bins.dart <out_dir> [known_good_zip3]',
    );
    exit(2);
  }
  outDir = Directory(args[0])..createSync(recursive: true);
  final sep = Platform.pathSeparator;
  final corpusRoot = outDir.absolute.parent;

  // ── 1/2/3: degenerates + the legacy slot no-banner case (regenerated) ─────
  stdout.writeln('Degenerates:');
  final zeros = Uint8List(
    kFullSize,
  ); // all 0x00, no marker: content IS the knob
  emit(
    '1_all_zer{o}s.bin',
    zeros,
    'degenerate',
    'braces in path',
    'reject unsafe path before OpenOCD starts',
  );
  emit(
    '2_all_zeros.bin',
    zeros,
    'degenerate',
    'single repeated byte',
    'reject as repeated-content image',
  );
  emit(
    '3_synthetic_64k.bin',
    payload('3_synthetic_64k', banner: null, size: 65536),
    'slot',
    'no banner (64 KiB)',
    'guarded Flash slot 0 rejects missing banner; Flash Only is the expert override',
  );

  // ── 4/5: target-identity matrix + mutation source ─────────────────────────
  stdout.writeln('Full-image identity set:');
  emit(
    '4b_zt3_vcu_SYNTHETIC_FULL.bin',
    fullImage(payload('4b')),
    'full',
    'accept baseline (zt3 VCU)',
    'identity accept vs zt3 VCU target; fake runner may reach the write command',
  );
  emit(
    '4c_gt3_vcu_SYNTHETIC_FULL.bin',
    fullImage(payload('4c', banner: kBannerGt3Vcu), serial: kSerialGt3),
    'full',
    'banner model = gt3',
    'identity reject: cross-model VCU',
  );
  emit(
    '4d_zt3_mcu_SYNTHETIC_FULL.bin',
    fullImage(
      payload('4d', banner: kBannerMcu),
      mcu: true,
      serial: kSerialMcuPart,
    ),
    'full',
    'banner type = MCU',
    'identity reject: VCU/MCU mismatch',
  );
  emit(
    '5_mutation_source_zt3_vcu_SYNTHETIC_FULL.bin',
    fullImage(payload('5')),
    'full',
    'protected mutation source',
    'temp copy mutated mid-run is rejected pre-Start and mid-backup; never modify this file',
  );

  // ── 11: firmware-key gate (Make zip3) ─────────────────────────────────────
  stdout.writeln('Key gate:');
  emit(
    '11a_zt3_vcu_key_shu_SYNTHETIC_FULL.bin',
    fullImage(payload('11a', key: KeyState.shu)),
    'full',
    'key @0x1420 = SHU default',
    'Make zip3 accepts (defaultKey branch)',
  );
  emit(
    '11b_zt3_vcu_key_oemstyle_SYNTHETIC_FULL.bin',
    fullImage(payload('11b', key: KeyState.oemStyle)),
    'full',
    'key/rand @0x1420 = ASCII production-style',
    'Make zip3 refuses (oem branch); Flash Only remains the operator override',
  );

  // ── 12: ZP length-record guard ────────────────────────────────────────────
  stdout.writeln('ZP guard:');
  emit(
    '12a_zt3_vcu_zp_decoy_plausible_SYNTHETIC_FULL.bin',
    fullImage(payload('12a'), zpDecoys: [(0x1F100, 57472)]),
    'full',
    'plausible decoy ZP at 0x1F100 before the real record',
    'authoritative 0x1F800 record wins; exact payload $kPayloadLen extracted, decoy ignored',
  );
  emit(
    '12b_zt3_vcu_zp_decoy_skipped_SYNTHETIC_FULL.bin',
    fullImage(payload('12b'), zpDecoys: [(0x1F100, 12346)]),
    'full',
    'invalid decoy ZP (fails mod-8 guard) before the real record',
    'decoy skipped; exact payload $kPayloadLen extracted',
  );
  emit(
    '12c_zt3_vcu_zp_absurd_SYNTHETIC_FULL.bin',
    fullImage(payload('12c'), zp: ZpMode.absurd),
    'full',
    'ZP encrypted length 0x30000',
    'no trustworthy record in window; Make zip3 refuses',
  );
  emit(
    '12d_zt3_vcu_zp_conflict_SYNTHETIC_FULL.bin',
    fullImage(
      payload('12d'),
      zp: ZpMode.allFf,
      zpDecoys: [(0x1F100, 57472), (0x1F300, 58440)],
    ),
    'full',
    'no 0x1F800 record; two disagreeing relocated candidates',
    'Make zip3 refuses: conflicting ZP length records',
  );
  emit(
    '12e_zt3_vcu_zp_relocated_SYNTHETIC_FULL.bin',
    fullImage(
      payload('12e'),
      zp: ZpMode.allFf,
      zpDecoys: [(0x1F300, kPayloadLen + 4)],
    ),
    'full',
    'single relocated ZP record at 0x1F300, none at 0x1F800',
    'scan fallback accepts the unanimous record; exact payload $kPayloadLen extracted',
  );

  // ── 13: full-image banner gate ────────────────────────────────────────────
  stdout.writeln('Full banner gate:');
  emit(
    '13a_zt3_vcu_banner_unknown_code_SYNTHETIC_FULL.bin',
    fullImage(payload('13a', banner: kBannerUnknown)),
    'full',
    'banner code xxZ9 (shape-valid, unsupported)',
    'guarded Backup+Flash rejects unsupported banner',
  );
  emit(
    '13b_zt3_vcu_no_banner_SYNTHETIC_FULL.bin',
    fullImage(payload('13b', banner: null)),
    'full',
    'no banner at 0x1400',
    'guarded Backup+Flash rejects missing banner',
  );

  // Scenario-8 companions: wrong-component artifacts at exactly 128 KB, where
  // the size gates cannot catch them (real BLE/BMS bins carry no SCOOTER
  // banner anywhere — corpus-verified). The truthful rejection is the banner
  // gate's, unlike the oversized BLE zip whose size message fires first.
  stdout.writeln('Wrong-component 128K bins:');
  final ble128 = Uint8List(kFullSize);
  Rng(seedOf('8e_ble')).fill(ble128);
  ble128.setAll(kMarkerOff, asciiBytes(kMarker));
  emit(
    '8e_ble_style_128k_SYNTHETIC_FULL.bin',
    ble128,
    'full',
    'BLE-style artifact: 128 KB, no SCOOTER banner anywhere',
    'guarded flash rejects on missing banner (truthful message for a wrong-component bin)',
  );
  final bms128 = Uint8List(kFullSize);
  Rng(seedOf('8f_bms')).fill(bms128);
  bms128.setAll(kMarkerOff, asciiBytes(kMarker));
  emit(
    '8f_bms_style_128k_SYNTHETIC_FULL.bin',
    bms128,
    'full',
    'BMS-style artifact: 128 KB, no SCOOTER banner anywhere',
    'guarded flash rejects on missing banner (truthful message for a wrong-component bin)',
  );

  // ── 14: slot-size window ──────────────────────────────────────────────────
  stdout.writeln('Slot-size window (banner present so ONLY size varies):');
  emit(
    '14a_slot_zt3_vcu_SYNTHETIC.bin',
    payload('14a'),
    'slot',
    'accept baseline ($kPayloadLen B)',
    'guarded Flash slot 0 accepts',
  );
  emit(
    '14b_slot_too_small_SYNTHETIC.bin',
    payload('14b', size: 40964),
    'slot',
    'size 40964 < window min',
    'reject: too small for slot 0',
  );
  emit(
    '14c_slot_too_big_SYNTHETIC.bin',
    payload('14c', size: 71684),
    'slot',
    'size 71684 > window max',
    'reject: too big for slot 0',
  );
  emit(
    '14d_slot_edge_64k_SYNTHETIC.bin',
    payload('14d', size: 65536),
    'slot',
    'size exactly 65536 (window edge)',
    'PINS CURRENT BEHAVIOR: passes the provisional window; revisit if window is tightened',
  );

  // ── 15: zip3 container mutations (derived from the known-good zip3) ───────
  stdout.writeln('Zip3 mutations:');
  final zipSrc = args.length > 1
      ? File(args[1])
      : [
          File('${outDir.path}$sep$kZip3SourceName'),
          File('${corpusRoot.path}${sep}10$sep$kZip3SourceName'),
        ].firstWhere(
          (f) => f.existsSync(),
          orElse: () => File(kZip3SourceName),
        );
  if (!zipSrc.existsSync()) {
    stdout.writeln('  SKIP 15* (known-good zip3 not found — pass it as arg 2)');
  } else {
    final srcEntries = readZipEntries(zipSrc.readAsBytesSync());
    void emitZip(
      String name,
      List<MapEntry<String, Uint8List>> entries,
      String knob,
      String expected,
    ) => emit(name, writeZipEntries(entries), 'zip3', knob, expected);

    emitZip(
      '15a_zip3_schema2.zip',
      editInfo(srcEntries, (m) => m['schemaVersion'] = 2),
      'schemaVersion = 2',
      'reject: unsupported schemaVersion',
    );
    emitZip(
      '15b_zip3_no_infojson.zip',
      [
        for (final e in srcEntries)
          if (e.key != 'info.json') e,
      ],
      'info.json removed',
      'reject: not a v3 package',
    );
    emitZip(
      '15c_zip3_bad_json.zip',
      [
        for (final e in srcEntries)
          e.key == 'info.json'
              ? MapEntry(e.key, asciiBytes('{ this is not json'))
              : e,
      ],
      'info.json is garbage text',
      'reject: info.json is not valid JSON',
    );
    emitZip(
      '15d_zip3_no_firmware_record.zip',
      editInfo(srcEntries, (m) => m.remove('firmware')),
      'firmware record removed',
      'reject: no firmware record',
    );
    emitZip(
      '15e_zip3_no_model.zip',
      editInfo(srcEntries, (m) => (m['firmware'] as Map).remove('model')),
      'firmware.model removed',
      'reject: no firmware.model',
    );
    emitZip(
      '15f_zip3_unsupported_model.zip',
      editInfo(srcEntries, (m) {
        final firmware = m['firmware'] as Map;
        firmware['model'] = 'm365';
        firmware['compatible'] = ['m365_VCU_AT32'];
      }),
      'package identity relabeled m365; payload stays zt3',
      'reject: unsupported model',
    );
    emitZip(
      '15g_zip3_no_md5enc.zip',
      editInfo(
        srcEntries,
        (m) => ((m['firmware'] as Map)['md5'] as Map).remove('enc'),
      ),
      'md5.enc removed',
      'reject: package is not MD5-verified',
    );
    emitZip(
      '15h_zip3_md5_mismatch.zip',
      [
        for (final e in srcEntries)
          e.key == 'FIRM.bin.enc'
              ? MapEntry(e.key, Uint8List.fromList(e.value)..last ^= 0xFF)
              : e,
      ],
      'one byte flipped in FIRM.bin.enc',
      'reject: failed MD5 check',
    );
    emitZip(
      '15i_zip3_model_mismatch.zip',
      editInfo(srcEntries, (m) {
        final firmware = m['firmware'] as Map;
        firmware['model'] = 'g3';
        firmware['compatible'] = ['g3_VCU_AT32'];
      }),
      'package identity relabeled g3; payload banner stays zt3',
      'reject: banner/metadata mismatch (MD5 still valid)',
    );
    final pad = Uint8List(20480);
    Rng(seedOf('15j_pad')).fill(pad);
    emitZip(
      '15j_zip3_oversize.zip',
      [...srcEntries, MapEntry('pad.bin', pad)],
      'padded past the container size cap',
      'reject before parsing: ZIP too large',
    );
    final junk = Uint8List(4096);
    Rng(seedOf('15k_junk')).fill(junk);
    emit(
      '15k_notazip.zip',
      junk,
      'zip3',
      'random bytes named .zip',
      'reject: not a readable ZIP archive',
    );
    emitZip(
      '15l_zip3_type_ble.zip',
      editInfo(srcEntries, (m) => (m['firmware'] as Map)['type'] = 'BLE'),
      'firmware.type = BLE; payload and integrity records unchanged',
      'reject: unsupported firmware type BLE (component gate, not size)',
    );
    emitZip(
      '15m_zip3_type_bms.zip',
      editInfo(srcEntries, (m) => (m['firmware'] as Map)['type'] = 'BMS'),
      'firmware.type = BMS; payload and integrity records unchanged',
      'reject: unsupported firmware type BMS (component gate, not size)',
    );
    emitZip(
      '15n_zip3_compatible_mismatch.zip',
      editInfo(
        srcEntries,
        (m) => (m['firmware'] as Map)['compatible'] = ['g3_VCU_AT32'],
      ),
      'compatible relabeled g3; model and payload stay zt3',
      'reject: compatible board disagrees with model',
    );
  }

  // ── 16: path / extension / size gates ─────────────────────────────────────
  stdout.writeln('Path and size gates:');
  emit(
    'Prüfung${sep}16a_slot_zt3_vcu_SYNTHETIC.bin',
    payload('14a'),
    'path',
    'non-ASCII (German umlaut) directory in path',
    'reject non-ASCII path before OpenOCD starts',
  );
  emit(
    '16b_slot_zt3_vcu_SYNTHETIC.dat',
    payload('14a'),
    'path',
    'extension .dat',
    'reject: only .bin is allowed',
  );
  final trunc = Uint8List(100004);
  Rng(seedOf('16c')).fill(trunc);
  trunc.setAll(kSlot0Off + kBannerOff, asciiBytes(kBannerZt3Vcu));
  emit(
    '16c_truncated_full_SYNTHETIC.bin',
    trunc,
    'full',
    'full image truncated to 100004 B',
    'reject: invalid size for a full image',
  );

  // ── 17: real files promoted from the corpus ───────────────────────────────
  stdout.writeln('Real-file copies:');
  copyReal(
    corpusRoot,
    'repo/g3/VCU/FIRM_1.4.8 (Compat).bin',
    '17a_g3_vcu_v1.4.8_oldrepo_key_REAL.bin',
    'old-repo slot bin with donor ASCII key+rand at 0x420',
    'slot structural+banner PASS (key not gated on slot path); a dump of it is refused by Make zip3',
  );
  copyReal(
    corpusRoot,
    'x3_rescue.bin',
    '17b_x3_rescue_zp_len0_REAL_FULL.bin',
    'real ZP record with length 0',
    'Make zip3 refuses: no trustworthy length record',
  );
  copyReal(
    corpusRoot,
    'cleared/zt3_vcu_v1.5.5_rescue.bin',
    '17c_zt3_vcu_cleared_REAL_FULL.bin',
    'identity page all-0xFF (no ZP, blank serials)',
    'Make zip3 refuses; serials informational-blank; guarded flash accepts (banner ok)',
  );
  copyReal(
    corpusRoot,
    'full_dumps/MEMORY_ZT3Pro.bin',
    '17d_zt3_oem_key_REAL_FULL.bin',
    'real OEM dump: ASCII key+rand, real serial pair, valid ZP',
    'Make zip3 refuses (oem key); guarded flash accepts (banner ok)',
  );

  // ── Manifest ──────────────────────────────────────────────────────────────
  // BOM so Excel on Windows decodes the non-ASCII path row (Prüfung) as UTF-8.
  final csv = StringBuffer(
    '﻿File,Group,Knob,ExpectedVerdict,SizeBytes,Sha256\n',
  );
  for (final row in manifest) {
    csv.writeln(row.map((c) => '"${c.replaceAll('"', '""')}"').join(','));
  }
  File(
    '${outDir.path}${sep}gen_manifest.csv',
  ).writeAsStringSync(csv.toString());
  stdout.writeln('\n${manifest.length} files written to ${outDir.path}');
  stdout.writeln(
    'Manifest: gen_manifest.csv (file, knob turned, expected verdict, sha256)',
  );
}
