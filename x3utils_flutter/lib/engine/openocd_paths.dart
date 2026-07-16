import 'dart:io';
import 'package:path/path.dart' as p;

/// Locates the frozen per-OS bundled OpenOCD at
/// `native/{os}/oocd/bin/openocd[.exe]` + `native/{os}/oocd/scripts`, where
/// `{os}` is windows | macos | linux (each OS ships its own OpenOCD build).
///
/// Walk up from the executable and the working directory until the native
/// bundle is found. Dev build: the exe sits under `build/…/Debug/`, so the
/// walk-up lands on the project root's `native/`; packaged build: `native/`
/// sits beside the exe and is found immediately.
class OpenOcdPaths {
  OpenOcdPaths(this.openOcdExe, this.scriptsDir);

  final String openOcdExe;
  final String scriptsDir;

  /// `<root>/native/{os}/oocd/bin`
  String get binDir => p.dirname(openOcdExe);

  static String get osDir {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    throw OpenOcdNotFound(
      'Unsupported platform: ${Platform.operatingSystem}. '
      'This build has no bundled OpenOCD backend for this OS.',
    );
  }

  static OpenOcdPaths find() {
    final exeName = Platform.isWindows ? 'openocd.exe' : 'openocd';
    final starts = <String>[
      p.dirname(Platform.resolvedExecutable),
      Directory.current.path,
    ];

    for (final start in starts) {
      Directory? dir = Directory(start);
      while (dir != null) {
        final oocd = p.join(dir.path, 'native', osDir, 'oocd');
        final exe = p.join(oocd, 'bin', exeName);
        final scripts = p.join(oocd, 'scripts');
        if (File(exe).existsSync() && Directory(scripts).existsSync()) {
          return OpenOcdPaths(exe, scripts);
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break; // reached filesystem root
        dir = parent;
      }
    }

    throw OpenOcdNotFound(
      'Bundled OpenOCD not found. Expected native/$osDir/oocd/bin/$exeName '
      '+ scripts beside the app or up the tree.',
    );
  }
}

class OpenOcdNotFound implements Exception {
  const OpenOcdNotFound(this.message);
  final String message;
  @override
  String toString() => message;
}
