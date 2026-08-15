import 'dart:typed_data';

Future<void> downloadBackupBytes(Uint8List bytes, String fileName) =>
    Future<void>.error(
      UnsupportedError('Browser backup downloads are unavailable here.'),
    );
