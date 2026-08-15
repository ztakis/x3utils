// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'cortexm.dart';
import 'debug_probe.dart';

const _dbgmcu = 0xe0042000;

class TargetInfo {
  TargetInfo({
    required this.name,
    required this.family,
    required this.idcode,
    required this.flashKB,
    required this.pageSize,
    required this.sramBytes,
    required this.flashBase,
    required this.programAlign,
    required this.protection,
    required this.rdpDisableValue,
    required this.tested,
  });

  final String name;
  final String family;
  final int idcode;
  final int flashKB;
  final int pageSize;
  final int sramBytes;
  final int flashBase;
  final int programAlign;
  final String protection;
  final int rdpDisableValue;
  final bool tested;
}

class _At32Part {
  const _At32Part(
    this.pid,
    this.name,
    this.flashKB,
    this.pageSize, {
    this.tested = false,
  });

  final int pid;
  final String name;
  final int flashKB;
  final int pageSize;
  final bool tested;
}

const _at32f415 = <_At32Part>[
  _At32Part(0x70030240, 'AT32F415RCT7', 256, 2048),
  _At32Part(0x70030241, 'AT32F415CCT7', 256, 2048),
  _At32Part(0x70030242, 'AT32F415KCU7-4', 256, 2048),
  _At32Part(0x70030243, 'AT32F415RCT7-7', 256, 2048),
  _At32Part(0x7003024c, 'AT32F415CCU7', 256, 2048),
  _At32Part(0x700301c4, 'AT32F415RBT7', 128, 1024),
  _At32Part(0x700301c5, 'AT32F415CBT7', 128, 1024, tested: true),
  _At32Part(0x700301c6, 'AT32F415KBU7-4', 128, 1024),
  _At32Part(0x700301c7, 'AT32F415RBT7-7', 128, 1024),
  _At32Part(0x700301cd, 'AT32F415CBU7', 128, 1024),
  _At32Part(0x70030108, 'AT32F415R8T7', 64, 1024),
  _At32Part(0x70030109, 'AT32F415C8T7', 64, 1024),
  _At32Part(0x7003010a, 'AT32F415K8U7-4', 64, 1024),
];

const _collidingPids = <int>{0x700301c5, 0x70030240, 0x70030242};

Future<int> _read(DebugProbe probe, int address) async {
  try {
    return await probe.readDebugReg(address);
  } catch (_) {
    return 0;
  }
}

Future<TargetInfo> detectTarget(DebugProbe probe, CortexM core) async {
  final idcode = await _read(probe, _dbgmcu);
  var matches = _at32f415.where((part) => part.pid == idcode).toList();
  if (matches.isNotEmpty && _collidingPids.contains(idcode)) {
    if (await core.hasFpu()) matches = const [];
  }
  if (matches.isNotEmpty) {
    final part = matches.first;
    return TargetInfo(
      name: '${part.name} (${part.flashKB} KB, ${part.pageSize} B pages)',
      family: 'AT32',
      idcode: idcode,
      flashKB: part.flashKB,
      pageSize: part.pageSize,
      sramBytes: 32 * 1024,
      flashBase: 0x08000000,
      programAlign: 4,
      protection: 'FAP',
      rdpDisableValue: 0xa5,
      tested: part.tested,
    );
  }
  return TargetInfo(
    name: idcode == 0
        ? 'unknown (AT32 DBGMCU IDCODE reads 0)'
        : 'unsupported target (AT32 DBGMCU IDCODE '
              '0x${idcode.toRadixString(16)})',
    family: 'unknown',
    idcode: idcode,
    flashKB: 0,
    pageSize: 0,
    sramBytes: 0,
    flashBase: 0x08000000,
    programAlign: 4,
    protection: 'none',
    rdpDisableValue: 0,
    tested: false,
  );
}
