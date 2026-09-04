// Re-runs SramIdentityParser over saved `_RAM.bin` snapshots and prints what
// the CURRENT parser makes of each, beside the `ram` block its sidecar recorded
// at capture time. Offline diagnostic: reads only, writes nothing, touches no
// hardware. Point it at a backup folder:
//
//   dart run tool/reparse_ram.dart C:\x3utils\backup
//
// Serials are printed masked; the sidecars beside the dumps hold the real ones.
import 'dart:convert';
import 'dart:io';

import 'package:x3utils_flutter/engine/sram_identity.dart';

String _mask(String? s) =>
    s == null ? '-' : '${s.substring(0, 3)}${'*' * (s.length - 3)}';

Map<String, Object?>? _sidecar(String stem) {
  for (final name in ['${stem}_EXTRA.json', '$stem.extra.json']) {
    final f = File(name);
    if (f.existsSync()) {
      return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    }
  }
  return null;
}

void main(List<String> args) {
  final dir = Directory(args.isEmpty ? r'C:\x3utils\backup' : args.first);
  final snapshots =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('_RAM.bin'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  var recovered = 0;
  var agree = 0;
  var disagree = 0;

  for (final file in snapshots) {
    final stem = file.path.substring(0, file.path.length - '_RAM.bin'.length);
    final result = SramIdentityParser.parse(file.readAsBytesSync());
    final id = result.identity;

    final side = _sidecar(stem);
    // schema 4 nests the flash facts under `rom`; schema 2 keeps them flat.
    final rom = (side?['rom'] ?? side) as Map<String, Object?>?;
    final fw = rom?['firmware'] as Map<String, Object?>?;
    final ident = rom?['identity'] as Map<String, Object?>?;
    final romVersion = fw?['version'] as String?;
    final romSerial = ident?['scooterSerial'] as String?;
    final wasVerdict =
        (side?['ram'] as Map<String, Object?>?)?['verdict'] as String?;

    final notes = <String>[];
    if (wasVerdict == 'notFound' && result.identified) {
      recovered++;
      notes.add('RECOVERED');
    }
    if (id != null && romVersion != null) {
      if (id.version?.toString() == romVersion) {
        agree++;
        notes.add('ver=ROM');
      } else {
        disagree++;
        notes.add('VERSION MISMATCH rom=$romVersion');
      }
    }
    if (id != null && romSerial != null) {
      notes.add(id.serial == romSerial ? 'serial=ROM' : 'SERIAL MISMATCH');
    }
    if (id != null && romVersion == null) notes.add('no ROM reference');

    final offsets = id?.tableOffsets
        .map((o) => '0x${o.toRadixString(16)}')
        .join(',');
    stdout.writeln(
      '${file.uri.pathSegments.last.padRight(34)} '
      '${result.verdict.name.padRight(12)} '
      '${(id?.type ?? '-').padRight(4)} '
      '${(id?.version?.toString() ?? '-').padRight(7)} '
      '${_mask(id?.serial).padRight(15)} '
      '${(offsets ?? '-').padRight(16)} ${notes.join('; ')}',
    );
  }

  stdout.writeln(
    '\n${snapshots.length} snapshots · $recovered recovered from notFound · '
    '$agree agree with ROM · $disagree disagree',
  );
  if (disagree > 0) exitCode = 1;
}
