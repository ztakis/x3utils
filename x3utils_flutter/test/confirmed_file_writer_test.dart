import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/engine/confirmed_file_writer.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('x3utils_confirm_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('Cancel leaves an existing package untouched', () async {
    final output = File(p.join(temp.path, 'firmware.zip'))
      ..writeAsBytesSync([1, 2, 3]);
    String? confirmedPath;

    final result = await writeBytesWithConfirmation(
      output,
      [4, 5, 6],
      confirmReplace: (path) async {
        confirmedPath = path;
        return false;
      },
    );

    expect(result, ConfirmedWriteResult.cancelled);
    expect(confirmedPath, output.path);
    expect(output.readAsBytesSync(), [1, 2, 3]);
  });

  test('Replace writes only after explicit positive confirmation', () async {
    final output = File(p.join(temp.path, 'firmware.zip'))
      ..writeAsBytesSync([1, 2, 3]);
    var confirmations = 0;

    final result = await writeBytesWithConfirmation(
      output,
      [4, 5, 6],
      confirmReplace: (path) async {
        confirmations++;
        expect(path, output.path);
        return true;
      },
    );

    expect(result, ConfirmedWriteResult.written);
    expect(confirmations, 1);
    expect(output.readAsBytesSync(), [4, 5, 6]);
  });

  test('Missing confirmation never replaces an existing package', () async {
    final output = File(p.join(temp.path, 'firmware.zip'))
      ..writeAsBytesSync([1, 2, 3]);

    final result = await writeBytesWithConfirmation(output, [4, 5, 6]);

    expect(result, ConfirmedWriteResult.cancelled);
    expect(output.readAsBytesSync(), [1, 2, 3]);
  });
}
