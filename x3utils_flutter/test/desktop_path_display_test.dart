import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/widgets/desktop_path_display.dart';

void main() {
  testWidgets('compact path display separates filename from its directory', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(440, 180);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final path = p.join(
      'Users',
      Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? 'user',
      'Documents',
      'x3utils',
      'packed_zip3',
      'g3_vcu_v1.5.15_compat.zip',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 400, child: DesktopPathDisplay(path: path)),
          ),
        ),
      ),
    );

    expect(find.text(p.basename(path)), findsOneWidget);
    expect(find.text(p.dirname(path)), findsOneWidget);
    expect(find.byTooltip('Copy full path'), findsOneWidget);
  });

  testWidgets('result path offers a file-manager reveal action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(440, 180);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final path = p.join('missing-output-folder', 'firmware.zip');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopPathDisplay(
            path: path,
            action: DesktopPathAction.reveal,
          ),
        ),
      ),
    );

    expect(find.byTooltip('Show in folder'), findsOneWidget);
  });
}
