import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'cfg.dart';
import 'firmware.dart';
import 'openocd_paths.dart';

/// Runs the bundled, vetted read-protection toolkit — `rdp.ps1` on Windows,
/// the `.sh` equivalents on macOS/Linux. Both encode the WRP-safe deterministic
/// option rewrite + their own re-seat retry, so we shell out rather than
/// reimplement. Only Check + Rescue are wired.
///
/// Exit codes (Check): 0 = not protected, 2 = read-protected, 3 = inconclusive.
class RdpRunner {
  RdpRunner(this.paths);
  final OpenOcdPaths paths;

  Process? _active;

  // native/<os>/oocd/bin → native/<os> (the OS root: has oocd/ + special/)
  String get _root => p.dirname(p.dirname(paths.binDir));
  String get _rdpDir => p.join(_root, 'special', 'rdp');

  String _scriptFor(String verb) {
    if (Platform.isWindows) return 'rdp.ps1';
    return verb == 'Rescue' ? 'rescue_unlock.sh' : 'rdp_check.sh';
  }

  /// Where the toolkit writes its OWN transcript: the same per-action folder
  /// under the x3utils root that this run's console log goes to, so one action
  /// leaves its evidence in one place. Windows receives it as `-LogDir`; the
  /// Unix scripts still receive it through config.sh. GUI-owned Windows runs
  /// suppress the script's redundant toolkit transcript, while a hand-run of
  /// rdp.ps1 without `-NoToolkitLog` keeps its own local log.
  String _logDirFor(String verb) => p.join(
    Firmware.root,
    'logs',
    verb == 'Rescue' ? 'rdp_rescue' : 'rdp_check',
  );

  bool get available => File(p.join(_rdpDir, _scriptFor('Check'))).existsSync();

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

  /// Runs a verb (`Check` | `Rescue`). Returns the process exit code.
  Future<int> run(
    String verb,
    ConnectionMode mode,
    int timeout, {
    bool yes = false,
    required void Function(String) onLine,
    void Function(String chunk)? onChunk,
  }) async {
    final String exe;
    final List<String> args;

    final logDir = _logDirFor(verb);

    if (Platform.isWindows) {
      final target = Cfg.target(mode).replaceAll('/', '\\');
      exe = 'powershell';
      args = [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(_rdpDir, 'rdp.ps1'),
        '-$verb',
        '-Launcher',
        '-Target',
        target,
        '-ConnectTimeout',
        '$timeout',
        '-LogDir',
        logDir,
        '-NoToolkitLog',
        if (mode == ConnectionMode.powerRace) '-Race',
        if (yes) '-Yes',
      ];
      onLine(
        '> powershell rdp.ps1 -$verb -Launcher '
        '-Target "$target" -ConnectTimeout $timeout '
        '-LogDir "$logDir" -NoToolkitLog'
        '${mode == ConnectionMode.powerRace ? ' -Race' : ''}'
        '${yes ? ' -Yes' : ''}',
      );
    } else {
      final runRoot = _prepareUnixRunRoot();
      final runRdpDir = p.join(runRoot, 'special', 'rdp');
      // Linux GUI scripts load config.sh beside themselves. The macOS scripts
      // preserve the CLI layout and load ../../config.sh from special/rdp.
      final configDir = Platform.isMacOS ? runRoot : runRdpDir;
      _writeConfigSh(mode, timeout, configDir, logDir);
      final script = _scriptFor(verb);
      exe = 'bash';
      args = [p.join(runRdpDir, script), '--launcher', if (yes) '--yes'];
      onLine('> bash $script --launcher${yes ? ' --yes' : ''}');
    }

    final proc = await Process.start(exe, args, workingDirectory: _root);
    _active = proc;

    final out = _listenText(proc.stdout, onLine, onChunk);
    final err = _listenText(proc.stderr, onLine, onChunk);

    final code = await proc.exitCode;
    await out.cancel();
    await err.cancel();
    if (identical(_active, proc)) _active = null;
    return code;
  }

  StreamSubscription<String> _listenText(
    Stream<List<int>> stream,
    void Function(String) onLine,
    void Function(String chunk)? onChunk,
  ) {
    var pending = '';
    // Lenient decoding + a logging-only guard, for the same reason as
    // OpenOcdRunner: the other end here is PowerShell or bash relaying OpenOCD,
    // so undecodable bytes are just as reachable, and a console failure must
    // never abort a protection check or a rescue.
    return stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            try {
              onChunk?.call(text);
              pending += text;
              while (true) {
                final idx = pending.indexOf('\n');
                if (idx < 0) break;
                final line = pending
                    .substring(0, idx)
                    .replaceFirst(RegExp(r'\r$'), '');
                pending = pending.substring(idx + 1);
                onLine(line);
              }
            } catch (_) {
              // Presentation cannot decide the verdict.
            }
          },
          onDone: () {
            try {
              if (pending.isNotEmpty) {
                onLine(pending.replaceFirst(RegExp(r'\r$'), ''));
              }
            } catch (_) {}
          },
        );
  }

  // macOS/Linux run from a writable temporary copy because the installed app
  // bundle is signed. Linux reads special/rdp/config.sh; macOS preserves the
  // CLI tree and reads config.sh from the temporary run root.
  String _prepareUnixRunRoot() {
    final runRoot = Directory.systemTemp.createTempSync('x3utils_rdp_').path;
    final runRdpDir = p.join(runRoot, 'special', 'rdp');
    Directory(runRdpDir).createSync(recursive: true);
    // The scripts' own log fallback, used only if X3UTILS_RDP_LOG_DIR is ever
    // missing from config.sh. The GUI always sets it (see _logDirFor).
    Directory(p.join(runRoot, 'backup')).createSync(recursive: true);
    _copyDirectory(Directory(_rdpDir), Directory(runRdpDir));
    return runRoot;
  }

  void _copyDirectory(Directory source, Directory target) {
    target.createSync(recursive: true);
    for (final entity in source.listSync(followLinks: false)) {
      final targetPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        entity.copySync(targetPath);
      }
    }
  }

  void _writeConfigSh(
    ConnectionMode mode,
    int timeout,
    String configDir,
    String logDir,
  ) {
    final oocd = paths.openOcdExe;
    final scripts = paths.scriptsDir;
    final race = mode == ConnectionMode.powerRace ? 'RACE=true\n' : '';
    File(p.join(configDir, 'config.sh')).writeAsStringSync(
      'export CL_NC="\\033[0m"\n'
      'export CL_R="\\033[1;31m"\n'
      'export CL_G="\\033[1;32m"\n'
      'export CL_Y="\\033[1;33m"\n'
      'export CL_M="\\033[1;35m"\n'
      'export CL_C="\\033[1;36m"\n'
      'export D="============================================================"\n'
      'OPENOCD_BIN="$oocd"\n'
      'SCRIPTS_DIR="$scripts"\n'
      'INTERFACE="${Cfg.interface}"\n'
      'TARGET="${Cfg.target(mode)}"\n'
      'CONNECT_TIMEOUT=$timeout\n'
      'X3UTILS_RDP_LOG_DIR="$logDir"\n'
      '$race'
      'EXPECTED_SIZE=131072\n',
    );
  }
}
