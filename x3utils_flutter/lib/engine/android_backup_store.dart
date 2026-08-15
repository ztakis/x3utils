import 'package:flutter/services.dart';

const androidBackupStoreChannelName = 'dev.x3utils/backup_store';
const androidBackupDirectoryLabel = 'Downloads/x3utils/backup';

const MethodChannel _channel = MethodChannel(androidBackupStoreChannelName);

typedef AndroidBackupPublisher =
    Future<String> Function(Uint8List bytes, String fileName);

class AndroidBackupStoreException implements Exception {
  const AndroidBackupStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Publishes one already-validated backup through Android scoped storage.
///
/// The native bridge keeps the MediaStore row pending until every byte has
/// been written, so an interrupted save never appears as a completed `.bin`.
Future<String> publishAndroidBackup(Uint8List bytes, String fileName) async {
  try {
    final path = await _channel.invokeMethod<String>('publishBackup', {
      'bytes': bytes,
      'fileName': fileName,
    });
    if (path == null || path.isEmpty) {
      throw const AndroidBackupStoreException(
        'Android storage did not return the saved backup location.',
      );
    }
    return path;
  } on AndroidBackupStoreException {
    rethrow;
  } on PlatformException catch (error) {
    throw AndroidBackupStoreException(
      error.message ?? 'Android backup storage failed (${error.code}).',
    );
  }
}
