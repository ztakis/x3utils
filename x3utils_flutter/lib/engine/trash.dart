import 'package:universal_io/universal_io.dart';

import 'package:path/path.dart' as p;

/// Asks the operator whether [path] may be moved to the OS trash. [title] and
/// [reason] carry the verdict and are shown verbatim: a broken read and a
/// read-protected chip both leave a file worth sweeping up, but only one of
/// them is a failed read, and the dialog must not blur that.
typedef ConfirmTrash =
    Future<bool> Function(String path, String title, String reason);

/// Outcome of a move to the OS trash.
class TrashResult {
  const TrashResult._(this.ok, this.destination, this.message);

  /// The file is no longer at its original path and is recoverable from the
  /// OS trash at [destination] (null when the platform does not report one).
  factory TrashResult.moved(String? destination) =>
      TrashResult._(true, destination, '');

  /// Nothing happened. The file is still exactly where it was.
  factory TrashResult.failed(String message) =>
      TrashResult._(false, null, message);

  final bool ok;
  final String? destination;
  final String message;
}

/// Moves a file to the OS trash — never a hard delete.
///
/// The maintainer's rule for the invalid-backup flow is explicit: an incomplete
/// dump may be swept out of the way, but it must stay recoverable. Every path
/// here therefore fails closed: if the platform move does not work, the file is
/// left untouched and the caller reports where it still is. There is no
/// `delete()` fallback in this file on purpose.
class Trash {
  /// What the destination is called on this OS, for UI copy.
  static String get label => Platform.isWindows ? 'Recycle Bin' : 'Trash';

  static Future<TrashResult> move(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      return TrashResult.failed('The file is no longer there.');
    }
    try {
      final result = Platform.isWindows
          ? await _recycleWindows(path)
          : _trashUnix(path);
      // Authoritative check on every platform: the shell/rename may report
      // success in ways we do not fully control, but the file being gone from
      // its original path is the fact that matters.
      if (result.ok && file.existsSync()) {
        return TrashResult.failed('The file is still at its original path.');
      }
      return result;
    } catch (e) {
      return TrashResult.failed('$e');
    }
  }

  // ── Windows ───────────────────────────────────────────────────────────────
  // VisualBasic.FileIO is the documented way to reach the real Recycle Bin from
  // a script; a plain File.delete() would bypass it. The Windows build already
  // shells out to PowerShell for rdp.ps1, so this adds no new dependency.
  static Future<TrashResult> _recycleWindows(String path) async {
    final quoted = path.replaceAll("'", "''");
    final script =
        "Add-Type -AssemblyName Microsoft.VisualBasic; "
        "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("
        "'$quoted','OnlyErrorDialogs','SendToRecycleBin','ThrowException')";
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim().split('\n').first;
      return TrashResult.failed(
        err.isEmpty ? 'PowerShell exited with ${r.exitCode}.' : err,
      );
    }
    return TrashResult.moved(null);
  }

  // ── macOS + Linux ─────────────────────────────────────────────────────────
  // macOS: a plain move into ~/.Trash. The Finder `osascript` route is avoided
  // deliberately — it trips the automation permission prompt.
  // Linux: the freedesktop trash spec, which needs the `.trashinfo` record as
  // well as the file, or the desktop cannot restore it.
  static TrashResult _trashUnix(String path) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return TrashResult.failed('HOME is not set.');
    }

    if (Platform.isMacOS) {
      final dir = Directory(p.join(home, '.Trash'));
      if (!dir.existsSync()) return TrashResult.failed('No ~/.Trash folder.');
      final dest = _uniquePath(dir.path, p.basename(path));
      return _relocate(path, dest);
    }

    final base =
        Platform.environment['XDG_DATA_HOME'] ??
        p.join(home, '.local', 'share');
    final trash = p.join(base, 'Trash');
    final filesDir = Directory(p.join(trash, 'files'))
      ..createSync(recursive: true);
    final infoDir = Directory(p.join(trash, 'info'))
      ..createSync(recursive: true);

    // The name must be free in BOTH files/ and info/, or the restore record
    // would point at the wrong file.
    final name = p.basename(
      _uniquePath(filesDir.path, p.basename(path), mirrorDir: infoDir.path),
    );
    final info = File(p.join(infoDir.path, '$name.trashinfo'));
    info.writeAsStringSync(
      '[Trash Info]\n'
      'Path=${_uriEscape(p.absolute(path))}\n'
      'DeletionDate=${_stamp()}\n',
    );
    final moved = _relocate(path, p.join(filesDir.path, name));
    if (!moved.ok) {
      // Leave no orphan record behind pointing at a file that never moved.
      try {
        info.deleteSync();
      } catch (_) {}
    }
    return moved;
  }

  /// Rename first; fall back to copy + remove when the trash sits on another
  /// filesystem (a custom backup folder on another disk is normal here). The
  /// copy is verified before the original is removed, so a failed copy can
  /// never cost the file.
  static TrashResult _relocate(String src, String dest) {
    final file = File(src);
    try {
      file.renameSync(dest);
      return TrashResult.moved(dest);
    } on FileSystemException {
      // EXDEV or similar — try the explicit two-step.
    }
    try {
      final size = file.lengthSync();
      file.copySync(dest);
      final copy = File(dest);
      if (!copy.existsSync() || copy.lengthSync() != size) {
        return TrashResult.failed(
          'The copy into the ${label.toLowerCase()} '
          'did not match the original, so nothing was removed.',
        );
      }
      file.deleteSync();
      return TrashResult.moved(dest);
    } catch (e) {
      return TrashResult.failed('$e');
    }
  }

  static String _uniquePath(String dir, String name, {String? mirrorDir}) {
    var candidate = p.join(dir, name);
    if (!_taken(candidate, name, mirrorDir)) return candidate;
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (var i = 1; i < 1000; i++) {
      final next = '$stem-$i$ext';
      candidate = p.join(dir, next);
      if (!_taken(candidate, next, mirrorDir)) return candidate;
    }
    return p.join(dir, '$stem-${DateTime.now().microsecondsSinceEpoch}$ext');
  }

  static bool _taken(String path, String name, String? mirrorDir) {
    if (File(path).existsSync() || Directory(path).existsSync()) return true;
    if (mirrorDir == null) return false;
    return File(p.join(mirrorDir, '$name.trashinfo')).existsSync();
  }

  /// Percent-escape each path segment, keeping the separators (trash spec).
  static String _uriEscape(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  static String _stamp() =>
      DateTime.now().toIso8601String().split('.').first; // YYYY-MM-DDThh:mm:ss
}
