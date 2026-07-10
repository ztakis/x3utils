import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'cfg.dart';
import 'openocd_paths.dart';

class OpenOcdResult {
  const OpenOcdResult(this.exitCode);
  final int exitCode;
  bool get ok => exitCode == 0;
}

/// Spawns the frozen OpenOCD and streams stdout+stderr line-by-line.
///
/// Port of the WinForms `OpenOcdRunner`. The command sequences are identical to
/// the field-proven `.bat` scripts (same `guided_connect` / `do_flash_and_verify`
/// cfg procs). Args are passed as a list, so no shell-quoting is needed.
class OpenOcdRunner {
  OpenOcdRunner(this.paths);
  final OpenOcdPaths paths;

  Process? _active;

  /// Writes a newline to OpenOCD's stdin — the C45 guided "Continue" keystroke.
  bool sendContinue() {
    final proc = _active;
    if (proc == null) return false;
    try {
      proc.stdin.writeln();
      return true;
    } catch (_) {
      return false;
    }
  }

  void kill() {
    _active?.kill();
    _active = null;
  }

  Future<OpenOcdResult> run(
      List<String> args, void Function(String line) onLine) async {
    onLine('> openocd ${args.join(' ')}');
    final proc = await Process.start(
      paths.openOcdExe,
      args,
      workingDirectory: paths.binDir,
    );
    _active = proc;

    final out = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);
    final err = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);

    final code = await proc.exitCode;
    await out.cancel();
    await err.cancel();
    if (identical(_active, proc)) _active = null;
    return OpenOcdResult(code);
  }

  // ── command builders (mirror OpenOcdRunner.cs / the .bat scripts) ──────────

  List<String> _base() => ['-s', paths.scriptsDir, '-d0'];

  List<String> checkArgs(ConnectionMode mode, int countdown) {
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f', Cfg.c45,
        '-c', 'guided_connect {$countdown}',
        '-c', 'flash probe 0',
        '-c', 'exit',
      ];
    }
    return [
      ..._base(),
      '-f', Cfg.interface,
      '-f', Cfg.target(mode),
      '-c', 'adapter speed 1000',
      '-c', 'init',
      '-c', 'reset halt',
      '-c', 'flash probe 0',
      '-c', 'exit',
    ];
  }

  List<String> dumpArgs(ConnectionMode mode, int countdown, String outPath) {
    final path = outPath.replaceAll('\\', '/');
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f', Cfg.c45,
        '-c', 'guided_connect {$countdown}',
        '-c', 'dump_image {$path} 0x08000000 0x20000',
        '-c', 'exit',
      ];
    }
    return [
      ..._base(),
      '-f', Cfg.interface,
      '-f', Cfg.target(mode),
      '-c', 'init',
      '-c', 'reset halt',
      '-c', 'flash probe 0',
      '-c', 'dump_image {$path} 0x08000000 0x20000',
      '-c', 'exit',
    ];
  }

  List<String> flashArgs(ConnectionMode mode, int countdown, String binPath) {
    final path = binPath.replaceAll('\\', '/');
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f', Cfg.c45,
        '-c', 'guided_flash_connect {$countdown}',
        '-c', 'do_flash_and_verify {$path}',
        '-c', 'exit',
      ];
    }
    return [
      ..._base(),
      '-f', Cfg.interface,
      '-f', Cfg.target(mode),
      '-c', 'init',
      '-c', 'reset halt',
      '-c', 'flash erase_address 0x08000000 0x20000',
      '-c', 'flash write_bank 0 {$path}',
      '-c', 'verify_image {$path} 0x08000000',
      '-c', 'exit',
    ];
  }

  /// Slot-0 flash: app slot at 0x08001000, leaves bootloader + identity intact
  /// (mirrors special/flash_slot0.bat — write_image erase, guided proc variant).
  List<String> flashSlot0Args(ConnectionMode mode, int countdown, String binPath) {
    final path = binPath.replaceAll('\\', '/');
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f', Cfg.c45,
        '-c', 'guided_flash_connect {$countdown}',
        '-c', 'do_flash_and_verify_slot0 {$path}',
        '-c', 'exit',
      ];
    }
    return [
      ..._base(),
      '-f', Cfg.interface,
      '-f', Cfg.target(mode),
      '-c', 'init',
      '-c', 'reset halt',
      '-c', 'flash write_image erase {$path} 0x08001000 bin',
      '-c', 'verify_image {$path} 0x08001000 bin',
      '-c', 'exit',
    ];
  }
}
