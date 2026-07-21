import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../theme.dart';

enum DesktopPathAction { none, copy, reveal }

/// Compact desktop presentation for paths: keep the useful filename readable,
/// constrain the parent directory to one line, and retain the full path through
/// the tooltip and optional copy action.
class DesktopPathDisplay extends StatelessWidget {
  const DesktopPathDisplay({
    super.key,
    required this.path,
    this.action = DesktopPathAction.copy,
  });

  final String path;
  final DesktopPathAction action;

  bool get _isDirectory => Directory(path).existsSync();

  Future<void> _runAction(BuildContext context) async {
    try {
      switch (action) {
        case DesktopPathAction.none:
          return;
        case DesktopPathAction.copy:
          await Clipboard.setData(ClipboardData(text: path));
          if (context.mounted) _notify(context, 'Path copied');
          return;
        case DesktopPathAction.reveal:
          await _reveal();
          if (context.mounted) {
            _notify(
              context,
              _isDirectory ? 'Folder opened' : 'Shown in folder',
            );
          }
      }
    } catch (_) {
      if (context.mounted) {
        _notify(context, 'Could not open the folder', error: true);
      }
    }
  }

  Future<void> _reveal() async {
    final directory = _isDirectory ? path : p.dirname(path);
    if (Platform.isWindows) {
      final arguments = _isDirectory
          ? [path]
          : ['/select,${p.normalize(path)}'];
      await Process.start(
        'explorer.exe',
        arguments,
        mode: ProcessStartMode.detached,
      );
      return;
    }

    late final String executable;
    late final List<String> arguments;

    if (Platform.isMacOS) {
      executable = 'open';
      arguments = _isDirectory ? [path] : ['-R', path];
    } else if (Platform.isLinux) {
      executable = 'xdg-open';
      arguments = [directory];
    } else {
      throw UnsupportedError(
        'Opening folders is unsupported on this platform.',
      );
    }

    final result = await Process.run(executable, arguments);
    if (result.exitCode != 0) {
      throw FileSystemException('File manager exited with ${result.exitCode}.');
    }
  }

  void _notify(BuildContext context, String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(color: AppColors.txt)),
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
          width: 230,
          backgroundColor: error ? AppColors.danger : AppColors.elev,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final filename = p.basename(path);
    final directory = p.dirname(path);

    return Tooltip(
      message: path,
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        decoration: BoxDecoration(
          color: AppColors.panel2,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppColors.line2),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: const TextStyle(
                      fontFamily: kMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.txt,
                    ),
                  ),
                  if (directory != '.') ...[
                    const SizedBox(height: 3),
                    Text(
                      directory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(
                        fontFamily: kMono,
                        fontSize: 11,
                        color: AppColors.dim,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (action != DesktopPathAction.none) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: action == DesktopPathAction.copy
                    ? 'Copy full path'
                    : _isDirectory
                    ? 'Open folder'
                    : 'Show in folder',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                color: AppColors.dim,
                onPressed: () => _runAction(context),
                icon: Icon(
                  action == DesktopPathAction.copy
                      ? Icons.copy_rounded
                      : Icons.folder_open_rounded,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
