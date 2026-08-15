// ignore_for_file: avoid_print
//
// Diagnostic ONLY — not part of the product build.
//
// Reads three things through the swdart native path and prints them, so we can
// see what a real AT32F415 returns *via swdart* (not via OpenOCD):
//
//   1. the DBGMCU IDCODE at 0x40022000's debug alias (0xE0042000) that
//      detectTarget() uses to identify the part — the read FAP could mask;
//   2. the USD / option word at 0x1FFFF800 (FAP is its low byte);
//   3. the flash vector table at 0x08000000 (MSP + reset vector).
//
// Strictly read-only. It connects in normal SWD, halts to read flash, and
// disconnects. It never erases, writes, or touches the option area, so it is
// safe to point at a locked board — a read cannot change FAP. The core is left
// halted; power-cycle the board afterwards.
//
// Run (Windows, from the package root, with the vendored DLL on the search
// path):
//   copy third_party\libusb\windows\libusb-1.0.dll .
//   dart run tool\fap_probe.dart
//   del libusb-1.0.dll
import 'dart:typed_data';

import 'package:x3utils_flutter/engine/swd/swd.dart';

const _fapUnlocked = 0xa5;

String _h32(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';
String _h8(int v) => '0x${v.toRadixString(16).padLeft(2, '0').toUpperCase()}';

int _u32le(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

Future<void> main() async {
  final probe = Probe();
  probe.onLog((line) => print('  $line'));

  print('== swdart FAP probe (read-only) ==');
  try {
    final target = await probe.connect(ConnectMode.normal);

    print('');
    print('-- identity (detectTarget via DBGMCU 0xE0042000) --');
    print('  name     : ${target.name}');
    print('  family   : ${target.family}');
    print('  idcode   : ${_h32(target.idcode)}');
    print('  flashKB  : ${target.flashKB}');
    print('  tested   : ${target.tested}');

    print('');
    print('-- USD / option word @ 0x1FFFF800 --');
    final usdBytes = await probe.readMemory(0x1ffff800, 4);
    final usd = _u32le(usdBytes, 0);
    final fap = usd & 0xff;
    final fapComp = (usd >> 8) & 0xff;
    final ssb = (usd >> 16) & 0xff;
    final ssbComp = (usd >> 24) & 0xff;
    print('  word     : ${_h32(usd)}');
    print(
      '  FAP=${_h8(fap)} FAP_COMP=${_h8(fapComp)} '
      'SSB=${_h8(ssb)} SSB_COMP=${_h8(ssbComp)}',
    );
    final compOk = (fap ^ fapComp) == 0xff;
    print('  FAP complement ${compOk ? "consistent" : "INCONSISTENT"}');

    print('');
    print('-- flash vector table @ 0x08000000 --');
    final vt = await probe.readFlash(address: 0x08000000, length: 16);
    final words = [for (var i = 0; i < 16; i += 4) _u32le(vt, i)];
    print('  ${words.map(_h32).join(' ')}');
    final msp = words[0];
    String flashState;
    if ((msp & 0xff000000) == 0x20000000) {
      flashState = 'firmware present (MSP in SRAM)';
    } else if (words.every((w) => w == 0xffffffff)) {
      flashState = 'blank / erased (all 0xFF) — readable';
    } else if (words.every((w) => w == 0x00000000)) {
      flashState = 'masked (all 0x00) — access-protection pattern';
    } else {
      flashState = 'unclassified';
    }
    print('  state    : $flashState');

    print('');
    print(
      '-- swdart-side reading (informational, mirrors rdp_check ladder) --',
    );
    final flashAccessible =
        flashState.contains('firmware') || flashState.contains('blank');
    final flashMasked = flashState.contains('masked');
    if (flashAccessible && fap != _fapUnlocked) {
      print('  NOT PROTECTED: flash readable; FAP read glitched (${_h8(fap)})');
    } else if (fap != _fapUnlocked && (flashMasked || !flashAccessible)) {
      print(
        '  READ PROTECTED: FAP=${_h8(fap)} not ${_h8(_fapUnlocked)}, '
        'flash masked/blocked',
      );
    } else if (fap == _fapUnlocked && compOk) {
      print('  NOT PROTECTED: FAP unlocked (0xA5), complement valid');
    } else {
      print('  INCONCLUSIVE');
    }
  } catch (e) {
    print('');
    print('FAILED: $e');
  } finally {
    await probe.disconnect();
  }
}
