import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/material.dart'
    show CheckedPopupMenuItem, InkWell, SelectableText;
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter/widgets.dart'
    show Axis, NeverScrollableScrollPhysics, PageView, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';
import 'package:x3utils_flutter/main.dart';
import 'package:x3utils_flutter/models.dart';

void main() {
  testWidgets('App boots and shows the default action', (
    WidgetTester tester,
  ) async {
    // Keep coverage at the compact 1024x768 responsive viewport.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());
    // Title bar brand + the default "Check connection" action are present.
    expect(find.text('x3utils'), findsOneWidget);
    expect(find.text('Check connection'), findsWidgets);
    expect(find.text('Ready to start'), findsOneWidget);
  });

  testWidgets('backup info is revealed only from a result sidecar', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('x3utils_backup_info_ui_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dump = File('${dir.path}${Platform.pathSeparator}dump.bin')
      ..writeAsBytesSync([1]);
    final sidecar = File('${dir.path}${Platform.pathSeparator}dump.json')
      ..writeAsStringSync('''
{
  "schema": 1,
  "backup": "dump.bin",
  "dumpVerdict": "ok",
  "type": "VCU",
  "model": "g3",
  "version": "1.6.1",
  "versionVerdict": "identified",
  "serial": "1CGCC9926C8115",
  "serialState": "real",
  "uid": "C49B0DB900002193A70705E8",
  "uidState": "matched",
  "key": "fe801cb2d1ef41a6",
  "keyState": "defaultKey",
  "rand": "ffffffffffff",
  "zpPayloadLen": 59028,
  "zpEncLen": 59032,
  "zpState": "readable"
}
''');

    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(const X3UtilsApp());
    final dynamic homeState = tester.state(find.byType(HomeScreen));
    homeState.c.stage = StageState.ok;
    homeState.c.resultPath = dump.path;
    homeState.c.resultMetadataPath = sidecar.path;
    homeState.c.notifyListeners();
    await tester.pump();

    expect(find.text('Show backup info'), findsOneWidget);
    expect(find.text('C49B0DB900002193A70705E8'), findsNothing);

    await tester.tap(find.text('Show backup info'));
    await tester.pump();
    expect(find.text('Backup info'), findsOneWidget);
    expect(find.text('UID'), findsOneWidget);
    // Seven rows, not eight: a sidecar only exists for a dump that already
    // validated, so a Verdict row could only ever say `ok`.
    expect(find.byType(SelectableText), findsNWidgets(7));
    expect(find.text('Verdict'), findsNothing);

    // Opening the dialog reveals nothing per-unit: the identity rows keep
    // their shape and their state, but not their value.
    List<String?> shownValues() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((field) => field.data)
        .toList();
    expect(shownValues(), contains('•••• •••• •••• •••• •••• •••• (matched)'));
    expect(shownValues(), contains('••••••••••••••'));
    expect(shownValues(), contains('•• •• •• •• •• •• •• •• (default key)'));
    expect(shownValues(), contains('•• •• •• •• •• ••'));
    // Non-identity rows are never masked.
    expect(shownValues(), contains('G3 VCU 1.6.1 (identified)'));
    expect(shownValues(), contains('59028 payload / 59032 encoded (readable)'));

    await tester.tap(find.text('Reveal'));
    await tester.pump();
    expect(shownValues(), contains('C49B 0DB9 0000 2193 A707 05E8 (matched)'));
    expect(shownValues(), contains('1CGCC9926C8115'));
    expect(shownValues(), contains('FE 80 1C B2 D1 EF 41 A6 (default key)'));
    expect(shownValues(), contains('FF FF FF FF FF FF'));

    await tester.tap(find.text('Hide'));
    await tester.pump();
    expect(shownValues(), contains('•••• •••• •••• •••• •••• •••• (matched)'));

    // Copy all hands over the rows as read on screen — never the mask, and
    // never raw JSON.
    await tester.tap(find.text('Copy all'));
    await tester.pump();
    expect(copied, hasLength(1));
    expect(copied.single, isNot(contains('•')));
    expect(copied.single, isNot(contains('{')));
    expect(
      copied.single,
      '''
Backup    dump.bin
Firmware  G3 VCU 1.6.1 (identified)
Serial    1CGCC9926C8115
UID       C49B 0DB9 0000 2193 A707 05E8 (matched)
Key       FE 80 1C B2 D1 EF 41 A6 (default key)
Rand      FF FF FF FF FF FF
ZP        59028 payload / 59032 encoded (readable)'''
          .trim(),
    );
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('Get file info sits in Advanced between ZIP3 and protection', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    expect(find.text('Get file info'), findsNothing); // Advanced is collapsed
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));

    double top(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(top('Get file info'), greaterThan(top('ZIP3 tools')));
    expect(top('Get file info'), lessThan(top('Check protection')));

    // It selects like any other action and gets a normal hero page, which is
    // where display options can live later. Fired through the tile's own
    // callback because a fifth Advanced action sits below the fold of the
    // 1024x768 rail, which scrolls.
    final tile = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('Get file info'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    tile.onTap!();
    await tester.pump();
    final dynamic homeState = tester.state(find.byType(HomeScreen));
    expect(homeState.c.actionId, 'file_info');
    expect(find.text('Choose a file'), findsOneWidget);
    expect(find.text('Choose .bin / .zip'), findsOneWidget);
    expect(find.text('Show file info'), findsWidgets);
    // Reading a file is not a run: it must not be able to enter the busy or
    // verdict states, and its picker takes packages as well as images.
    expect(homeState.c.canStart, isFalse); // nothing picked yet
    expect(homeState.c.running, isFalse);
    expect(homeState.c.stage, StageState.idle);
    expect(homeState.c.hasFlashScope, isFalse);
    expect(homeState.c.isSlotAction, isFalse);
  });

  testWidgets('SHU compat requires the timed firmware-version warning', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    // SHU compat lives in Advanced, which is collapsed at boot.
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));
    final shuTile = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('SHU compatible'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    shuTile.onTap!();
    await tester.pump();

    expect(find.text('ATTENTION'), findsOneWidget);
    expect(find.textContaining('F3 VCU — 1.6.3'), findsOneWidget);
    expect(find.textContaining('G3 VCU — 1.6.3'), findsOneWidget);
    expect(find.textContaining('GT3 VCU — 1.7.2'), findsOneWidget);
    expect(find.textContaining('ZT3 VCU — 1.5.9'), findsOneWidget);
    expect(find.text('I understand — continue (5s)'), findsOneWidget);
    expect(find.text('Ready to start'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('I understand — continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Make SHU compatible'), findsOneWidget);
    expect(find.text('ATTENTION'), findsNothing);
  });

  testWidgets('Flash Only exposes centered full and slot-0 scopes', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    final openConsole = find.text('▾ Console');
    if (openConsole.evaluate().isNotEmpty) {
      await tester.tap(openConsole);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));
    final flashTile = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('Flash Only'), matching: find.byType(InkWell))
          .first,
    );
    flashTile.onTap!();
    await tester.pump();
    expect(find.text('Flash Only — no safety nets'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('I understand — continue'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Choose firmware'), findsOneWidget);
    expect(find.text('Full image'), findsOneWidget);
    expect(find.text('Slot 0 only'), findsOneWidget);
    expect(find.text('Choose .zip'), findsOneWidget);

    await tester.tap(find.text('Slot 0 only'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('Choose a slot-sized .bin or zip3 package below.'),
      findsOneWidget,
    );
  });

  testWidgets('ZIP3 tools use a locked three-page workspace', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    final openConsole = find.text('▾ Console');
    if (openConsole.evaluate().isNotEmpty) {
      await tester.tap(openConsole);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('slice · pack · unpack'), findsOneWidget);
    expect(find.text('slice · pack · unpack · offline'), findsNothing);
    final zip3Tile = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('ZIP3 tools'), matching: find.byType(InkWell))
          .first,
    );
    // ZIP3 tools currently opens directly; its intro modal is disabled pending
    // a rewrite for the three distinct Slice / Pack / Unpack workflows.
    zip3Tile.onTap!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('What Pack zip3 is for'), findsNothing);

    // The identity form and its controls are present.
    expect(find.text('PACKAGE IDENTITY'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    // Legacy zip3 is the default format, so its enforceModel option is shown
    // from the start — SHU 4.1 rejects zip3.2, so the default is the format the
    // app in the field actually reads.
    expect(find.textContaining('Enforce model'), findsOneWidget);
    expect(find.textContaining('Package name'), findsOneWidget);
    expect(find.text('Choose a backup dump'), findsOneWidget);
    expect(
      find.text('Choose a full 128 KB backup .bin below.'),
      findsOneWidget,
    );
    expect(find.text('Pack zip 3'), findsWidgets);

    // The split arrow changes format only. Selecting zip3.2 hides the legacy
    // metadata option, and does not start the pack operation.
    final dynamic zipHomeState = tester.state(find.byType(HomeScreen));
    await tester.tap(find.byTooltip('Choose package format'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // First entry is zip3.2; legacy is the default now, so this is the switch.
    await tester.tap(
      find.byType(CheckedPopupMenuItem<Zip3Format>).first,
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(zipHomeState.c.zip3Format, Zip3Format.rev2);
    expect(zipHomeState.c.stage, StageState.idle);
    expect(find.textContaining('Enforce model'), findsNothing);
    expect(find.text('Pack zip 3.2'), findsOneWidget);

    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.scrollDirection, Axis.vertical);
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());
    expect(pageView.allowImplicitScrolling, isFalse);
    final chooseBinButton = find
        .ancestor(of: find.text('Choose .bin'), matching: find.byType(InkWell))
        .first;
    expect(
      tester.getSize(find.byKey(const ValueKey('zip3-slice'))).height,
      tester.getSize(chooseBinButton).height,
    );

    tester.widget<InkWell>(find.byKey(const ValueKey('zip3-pack'))).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1);
    expect(find.text('Choose a firmware payload'), findsOneWidget);
    expect(
      find.text('Choose the complete firmware .bin to package below.'),
      findsOneWidget,
    );
    expect(find.text('PACKAGE IDENTITY'), findsOneWidget);

    tester.widget<InkWell>(find.byKey(const ValueKey('zip3-unpack'))).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.text('Choose a zip3 package'), findsOneWidget);
    expect(find.text('PACKAGE DETAILS'), findsOneWidget);
    expect(find.text('Output filename'), findsOneWidget);
    expect(find.textContaining('.bin is added automatically'), findsOneWidget);
    expect(find.text('Unpack zip3'), findsOneWidget);
    final chooseZipInk = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('Choose .zip'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(chooseZipInk.onTap, isNotNull);
    final unpackInk = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('Unpack zip3'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(unpackInk.onTap, isNull);

    // A completed Unpack temporarily replaces the three-page setup with the
    // generic result hero. Done must restore page 2 because UNPACK remains the
    // selected workspace toggle.
    final dynamic homeState = tester.state(find.byType(HomeScreen));
    homeState.c.stage = StageState.ok;
    homeState.c.notifyListeners();
    await tester.pump();
    expect(find.byType(PageView), findsNothing);
    homeState.c.dismiss();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.text('Choose a zip3 package'), findsOneWidget);

    tester.widget<InkWell>(find.byKey(const ValueKey('zip3-slice'))).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    expect(find.text('Choose a backup dump'), findsOneWidget);
  });
}
