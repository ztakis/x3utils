// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'dart:typed_data';

class ProbeVersion {
  ProbeVersion(this.stlink, this.jtag, this.swim, this.text);

  final int stlink;
  final int jtag;
  final int swim;
  final String text;
}

abstract class DebugProbe {
  ProbeVersion get version;
  String get probeName;
  bool get hasMem16;

  Future<void> init();
  Future<void> enterSwd();
  Future<int> readIdcode();
  Future<double?> getTargetVoltage();
  Future<void> resetSys();

  /// Drive the genuine probe's nRST output: 0 = assert low, 1 = release high.
  Future<void> driveNrst(int state);

  Future<int> readReg(int index);
  Future<void> writeReg(int index, int value);
  Future<int> readDebugReg(int address);
  Future<void> writeDebugReg(int address, int value);
  Future<Uint8List> readMem32(int address, int length);
  Future<void> writeMem16(int address, Uint8List data);
  Future<void> writeMem32(int address, Uint8List data);
  Future<void> close();
}
