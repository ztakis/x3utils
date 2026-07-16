import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'cfg.dart';
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

    if (Platform.isWindows) {
      _writeConfigCmd(mode, timeout);
      exe = 'powershell';
      args = [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(_rdpDir, 'rdp.ps1'),
        '-$verb',
        '-Launcher',
        if (yes) '-Yes',
      ];
      onLine('> powershell rdp.ps1 -$verb -Launcher${yes ? ' -Yes' : ''}');
    } else {
      final runRoot = _prepareUnixRunRoot();
      final runRdpDir = p.join(runRoot, 'special', 'rdp');
      // Linux GUI scripts load config.sh beside themselves. The macOS scripts
      // preserve the CLI layout and load ../../config.sh from special/rdp.
      final configDir = Platform.isMacOS ? runRoot : runRdpDir;
      _writeConfigSh(mode, timeout, configDir, runRoot);
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
    return stream
        .transform(utf8.decoder)
        .listen(
          (text) {
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
          },
          onDone: () {
            if (pending.isNotEmpty) {
              onLine(pending.replaceFirst(RegExp(r'\r$'), ''));
            }
          },
        );
  }

  // Windows: config.cmd beside rdp.ps1 (our rdp.ps1 reads from its ScriptDir).
  void _writeConfigCmd(ConnectionMode mode, int timeout) {
    final target = Cfg.target(mode).replaceAll('/', '\\');
    // Mode D: the ported rdp.ps1 honors RACE=true (power-race respawn connect).
    final race = mode == ConnectionMode.powerRace ? 'set "RACE=true"\r\n' : '';
    File(p.join(_rdpDir, 'config.cmd')).writeAsStringSync(
      'set "TARGET=$target"\r\n'
      'set "CONNECT_TIMEOUT=$timeout"\r\n'
      '$race',
    );
  }

  // macOS/Linux run from a writable temporary copy because the installed app
  // bundle is signed. Linux reads special/rdp/config.sh; macOS preserves the
  // CLI tree and reads config.sh from the temporary run root.
  String _prepareUnixRunRoot() {
    final runRoot = Directory.systemTemp.createTempSync('x3utils_rdp_').path;
    final runRdpDir = p.join(runRoot, 'special', 'rdp');
    Directory(runRdpDir).createSync(recursive: true);
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
    String runRoot,
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
      'X3UTILS_RDP_LOG_DIR="${p.join(runRoot, 'backup')}"\n'
      '$race'
      'EXPECTED_SIZE=131072\n',
    );
  }
}
