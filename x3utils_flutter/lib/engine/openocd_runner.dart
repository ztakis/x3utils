import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'cfg.dart';
import 'openocd_paths.dart';

/// Per-attempt classification of a power-race respawn miss (mirrors
/// race_grade.cmd) — how far the attempt got, for the live "hammering" indicator.
enum RaceTier { searching, noisy, nearCatch, adapterGone }

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
  bool _raceStop = false; // set by kill() to break the respawn loop

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
    _raceStop = true; // also breaks a runRace respawn loop
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

  /// Power-race respawn: relaunch OpenOCD over the same [args] until one attempt
  /// catches the post-power-on window (exit 0), then replay that winning attempt's
  /// output to [onLine]. Every miss reports its classified [RaceTier] to
  /// [onAttempt] so the UI can show a live "hammering" indicator. Stop with kill().
  ///
  /// openocd's init is one-shot, so catching a window means repeated FRESH
  /// launches (this loop), not retrying inside one session. No inter-attempt delay
  /// — the window is short and sampling speed is everything (proven on the CLI).
  Future<OpenOcdResult> runRace(
    List<String> args, {
    required void Function(String line) onLine,
    required void Function(int attempt, RaceTier tier) onAttempt,
  }) async {
    _raceStop = false;
    var attempt = 0;
    while (!_raceStop) {
      attempt++;
      final buf = StringBuffer();
      final proc = await Process.start(paths.openOcdExe, args,
          workingDirectory: paths.binDir);
      _active = proc;
      final out = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(buf.writeln);
      final err = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(buf.writeln);
      final code = await proc.exitCode;
      await out.cancel();
      await err.cancel();
      if (identical(_active, proc)) _active = null;
      if (code == 0) {
        for (final l in const LineSplitter().convert(buf.toString())) {
          onLine(l);
        }
        return const OpenOcdResult(0);
      }
      onAttempt(attempt, _classify(buf.toString()));
    }
    return const OpenOcdResult(-1); // stopped by kill()
  }

  /// Classify a missed attempt by how far it got (see race_grade.cmd): "Cortex-M4
  /// detected" is the real "reached the core" signal — it needs live SWD.
  static RaceTier _classify(String out) {
    if (out.contains('open failed')) return RaceTier.adapterGone;
    if (out.contains('target halted')) return RaceTier.nearCatch;
    if (out.contains('Cortex-M4')) return RaceTier.noisy;
    return RaceTier.searching;
  }

  // ── command builders (mirror OpenOcdRunner.cs / the .bat scripts) ──────────

  List<String> _base() => ['-s', paths.scriptsDir, '-d0'];

  List<String> checkArgs(ConnectionMode mode, int countdown) {
    if (mode == ConnectionMode.powerRace) {
      // Self-contained race cfg (sources the interface); race_connect = init +
      // halt + watchdog-freeze. Run via runRace() (respawn), not run().
      return [
        ..._base(),
        '-f', Cfg.race,
        '-c', 'race_connect',
        '-c', 'flash probe 0',
        '-c', 'exit',
      ];
    }
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
    if (mode == ConnectionMode.powerRace) {
      return [
        ..._base(),
        '-f', Cfg.race,
        '-c', 'race_connect',
        '-c', 'dump_image {$path} 0x08000000 0x20000',
        '-c', 'exit',
      ];
    }
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
    if (mode == ConnectionMode.powerRace) {
      return [
        ..._base(),
        '-f', Cfg.race,
        '-c', 'race_connect',
        '-c', 'flash erase_address 0x08000000 0x20000',
        '-c', 'flash write_bank 0 {$path}',
        '-c', 'verify_image {$path} 0x08000000',
        '-c', 'exit',
      ];
    }
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
    if (mode == ConnectionMode.powerRace) {
      return [
        ..._base(),
        '-f', Cfg.race,
        '-c', 'race_connect',
        '-c', 'flash write_image erase {$path} 0x08001000 bin',
        '-c', 'verify_image {$path} 0x08001000 bin',
        '-c', 'exit',
      ];
    }
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
