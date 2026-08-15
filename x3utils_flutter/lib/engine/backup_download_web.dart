import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Trigger one browser download for a backup that has already passed the
/// controller's exact-length and varied-content validation.
Future<void> downloadBackupBytes(Uint8List bytes, String fileName) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  try {
    anchor.click();
  } finally {
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }
}
