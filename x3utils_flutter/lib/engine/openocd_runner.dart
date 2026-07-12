import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'cfg.dart';
import 'openocd_paths.dart';

/// Per-attempt classification of a power-race respawn miss (mirrors
/// race_grade.cmd) — how far the attempt got, for the live "hammering" indicator.
enum RaceTier { searching, noisy, nearCatch, adapterGone, timedOut }

class OpenOcdResult {
  const OpenOcdResult(this.exitCode, this.evidence);
  final int exitCode;
  final OpenOcdEvidence evidence;
  bool get ok => exitCode == 0;
}

class OpenOcdEvidence {
  bool caught = false;
  bool dumped = false;
  bool erased = false;
  bool wrote = false;
  bool verified = false;

  void record(String line) {
    final low = line.toLowerCase();
    caught |=
        low.contains('target halted') ||
        low.contains('x3_caught_hold_power') ||
        low.contains('caught; hold power');
    dumped |= low.contains('dumped ');
    erased |= low.contains('erased ');
    wrote |= low.contains('wrote ');
    verified |= low.contains('verified ');
  }
}

/// Spawns the frozen OpenOCD and streams stdout+stderr line-by-line.
///
/// Port of the WinForms `OpenOcdRunner`. The command sequences are identical to
/// the field-proven `.bat` scripts (same `guided_connect` / `do_flash_and_verify`
/// cfg procs). Args are passed as a list, so no shell-quoting is needed.
class OpenOcdRunner {
  OpenOcdRunner(this.paths);
  final OpenOcdPaths paths;

  static const _racePreCatchTimeout = Duration(seconds: 4);
  static const _racePostCatchTimeout = Duration(seconds: 45);
  static const _raceCatchMarker = 'X3_CAUGHT_HOLD_POWER';

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
    List<String> args,
    void Function(String line) onLine,
  ) async {
    onLine('> openocd ${args.join(' ')}');
    final evidence = OpenOcdEvidence();
    final proc = await Process.start(
      paths.openOcdExe,
      args,
      workingDirectory: paths.binDir,
    );
    _active = proc;

    final out = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          evidence.record(line);
          onLine(line);
        });
    final err = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          evidence.record(line);
          onLine(line);
        });
    final outDone = out.asFuture<void>();
    final errDone = err.asFuture<void>();

    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    if (identical(_active, proc)) _active = null;
    return OpenOcdResult(code, evidence);
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
    void Function()? onCaught,
  }) async {
    _raceStop = false;
    var attempt = 0;
    while (!_raceStop) {
      attempt++;
      final buf = StringBuffer();
      final evidence = OpenOcdEvidence();
      var caught = false;
      var timedOut = false;
      var processExited = false;
      var watchdogGeneration = 0;
      Timer? watchdog;
      // Watch each attempt LIVE: the moment 'target halted' appears, race_connect
      // has landed — flip the UI to "caught, working" (onCaught) and stream the
      // op's progress, so the hero doesn't freeze on the last count during the
      // ~2-5s dump/flash. (A near-catch that halts then drops falls through to a
      // miss below and the UI reverts to hammering.)
      void handle(String l) {
        buf.writeln(l);
        evidence.record(l);
        if (timedOut) return;
        final marker = l.contains(_raceCatchMarker);
        // Catch signal: 'target halted' on a running core, OR the op's own progress
        // (dump/erase/write) when the core was ALREADY halted from a prior catch
        // (the 2-catch backup+flash / SHU flows) so 'target halted' isn't reprinted
        // — without this, the 2nd catch's whole output gets suppressed.
        if (!caught &&
            (marker ||
                l.contains('target halted') ||
                l.contains('dumped ') ||
                l.contains('erased ') ||
                l.contains('wrote '))) {
          caught = true;
          evidence.record('== race attempt $attempt caught; hold power ==');
          onLine('== race attempt $attempt caught; hold power ==');
          onCaught?.call();
        }
        if (caught && !marker) onLine(l);
      }

      final proc = await Process.start(
        paths.openOcdExe,
        args,
        workingDirectory: paths.binDir,
      );
      _active = proc;
      void armWatchdog(Duration timeout) {
        if (processExited) return;
        watchdog?.cancel();
        final generation = ++watchdogGeneration;
        watchdog = Timer(timeout, () {
          if (processExited || generation != watchdogGeneration) return;
          timedOut = true;
          if (caught) {
            onLine('== race attempt $attempt timed out; killing OpenOCD ==');
          }
          proc.kill();
        });
      }

      armWatchdog(_racePreCatchTimeout);
      final out = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            handle(line);
            if (caught && !timedOut) armWatchdog(_racePostCatchTimeout);
          });
      final outDone = out.asFuture<void>();
      final err = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            handle(line);
            if (caught && !timedOut) armWatchdog(_racePostCatchTimeout);
          });
      final errDone = err.asFuture<void>();
      final code = await proc.exitCode;
      processExited = true;
      watchdogGeneration++;
      watchdog?.cancel();
      await Future.wait([outDone, errDone]);
      watchdogGeneration++;
      watchdog?.cancel();
      if (identical(_active, proc)) _active = null;
      if (code == 0) {
        // Safety net: a winning attempt that never tripped a catch marker above
        // still must show its output (never silently succeed) — replay the buffer.
        if (!caught) {
          for (final l in const LineSplitter().convert(buf.toString())) {
            onLine(l);
          }
        }
        return OpenOcdResult(0, evidence);
      }
      if (timedOut) {
        onAttempt(attempt, RaceTier.timedOut);
        continue;
      }
      if (caught) {
        onLine(
          '== race attempt $attempt failed after catch (exit $code); retrying ==',
        );
      }
      onAttempt(attempt, _classify(buf.toString()));
    }
    return OpenOcdResult(-1, OpenOcdEvidence()); // stopped by kill()
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
        '-f',
        Cfg.race,
        '-c',
        'race_connect',
        '-c',
        'echo $_raceCatchMarker',
        '-c',
        'flash probe 0',
        '-c',
        'exit',
      ];
    }
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f',
        Cfg.c45,
        '-c',
        'guided_connect {$countdown}',
        '-c',
        'flash probe 0',
        '-c',
        'exit',
      ];
    }
    return [
      ..._base(),
      '-f',
      Cfg.interface,
      '-f',
      Cfg.target(mode),
      '-c',
      'adapter speed 1000',
      '-c',
      'init',
      '-c',
      'reset halt',
      '-c',
      'flash probe 0',
      '-c',
      'exit',
    ];
  }

  List<String> dumpArgs(ConnectionMode mode, int countdown, String outPath) {
    final path = outPath.replaceAll('\\', '/');
    if (mode == ConnectionMode.powerRace) {
      return [
        ..._base(),
        '-f',
        Cfg.race,
        '-c',
        'race_connect',
        '-c',
        'echo $_raceCatchMarker',
        '-c',
        'dump_image {$path} 0x08000000 0x20000',
        '-c',
        'exit',
      ];
    }
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f',
        Cfg.c45,
        '-c',
        'guided_connect {$countdown}',
        '-c',
        'dump_image {$path} 0x08000000 0x20000',
        '-c',
        'exit',
      ];
    }
    return [
      ..._base(),
      '-f',
      Cfg.interface,
      '-f',
      Cfg.target(mode),
      '-c',
      'init',
      '-c',
      'reset halt',
      '-c',
      'flash probe 0',
      '-c',
      'dump_image {$path} 0x08000000 0x20000',
      '-c',
      'exit',
    ];
  }

  List<String> flashArgs(ConnectionMode mode, int countdown, String binPath) {
    final path = binPath.replaceAll('\\', '/');
    if (mode == ConnectionMode.powerRace) {
      return [
        ..._base(),
        '-f',
        Cfg.race,
        '-c',
        'race_connect',
        '-c',
        'echo $_raceCatchMarker',
        '-c',
        'flash erase_address 0x08000000 0x20000',
        '-c',
        'flash write_bank 0 {$path}',
        '-c',
        'verify_image {$path} 0x08000000',
        '-c',
        'exit',
      ];
    }
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f',
        Cfg.c45,
        '-c',
        'guided_flash_connect {$countdown}',
        '-c',
        'do_flash_and_verify {$path}',
        '-c',
        'exit',
      ];
    }
    return [
      ..._base(),
      '-f',
      Cfg.interface,
      '-f',
      Cfg.target(mode),
      '-c',
      'init',
      '-c',
      'reset halt',
      '-c',
      'flash erase_address 0x08000000 0x20000',
      '-c',
      'flash write_bank 0 {$path}',
      '-c',
      'verify_image {$path} 0x08000000',
      '-c',
      'exit',
    ];
  }

  /// Slot-0 flash: app slot at 0x08001000, leaves bootloader + identity intact
  /// (mirrors special/flash_slot0.bat — write_image erase, guided proc variant).
  List<String> flashSlot0Args(
    ConnectionMode mode,
    int countdown,
    String binPath,
  ) {
    final path = binPath.replaceAll('\\', '/');
    if (mode == ConnectionMode.powerRace) {
      return [
        ..._base(),
        '-f',
        Cfg.race,
        '-c',
        'race_connect',
        '-c',
        'echo $_raceCatchMarker',
        '-c',
        'flash write_image erase {$path} 0x08001000 bin',
        '-c',
        'verify_image {$path} 0x08001000 bin',
        '-c',
        'exit',
      ];
    }
    if (mode == ConnectionMode.cloneC45) {
      return [
        ..._base(),
        '-f',
        Cfg.c45,
        '-c',
        'guided_flash_connect {$countdown}',
        '-c',
        'do_flash_and_verify_slot0 {$path}',
        '-c',
        'exit',
      ];
    }
    return [
      ..._base(),
      '-f',
      Cfg.interface,
      '-f',
      Cfg.target(mode),
      '-c',
      'init',
      '-c',
      'reset halt',
      '-c',
      'flash write_image erase {$path} 0x08001000 bin',
      '-c',
      'verify_image {$path} 0x08001000 bin',
      '-c',
      'exit',
    ];
  }
}
