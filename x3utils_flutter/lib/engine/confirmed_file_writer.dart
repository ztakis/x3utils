import 'dart:io';

typedef ConfirmFileReplace = Future<bool> Function(String path);

enum ConfirmedWriteResult { written, cancelled }

/// Writes [bytes] without ever replacing an existing file unless
/// [confirmReplace] explicitly approves that exact path.
Future<ConfirmedWriteResult> writeBytesWithConfirmation(
  File file,
  List<int> bytes, {
  ConfirmFileReplace? confirmReplace,
}) async {
  if (file.existsSync()) {
    final replace = await confirmReplace?.call(file.path) ?? false;
    if (!replace) return ConfirmedWriteResult.cancelled;
  } else {
    try {
      // Reserve a new path exclusively so a file that appears after the
      // existsSync check cannot be overwritten without confirmation.
      file.createSync(exclusive: true);
    } on FileSystemException {
      if (!file.existsSync()) rethrow;
      final replace = await confirmReplace?.call(file.path) ?? false;
      if (!replace) return ConfirmedWriteResult.cancelled;
    }
  }

  file.writeAsBytesSync(bytes);
  return ConfirmedWriteResult.written;
}
