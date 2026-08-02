import 'dart:ui' show Size;

import 'package:flutter/material.dart' show CheckedPopupMenuItem, InkWell;
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
    expect(find.textContaining('Enforce model'), findsNothing);
    expect(find.textContaining('Package name'), findsOneWidget);
    expect(find.text('Choose a backup dump'), findsOneWidget);
    expect(
      find.text('Choose a full 128 KB backup .bin below.'),
      findsOneWidget,
    );
    expect(find.text('Pack zip 3.2'), findsOneWidget);

    // The split arrow changes format only. Legacy reveals its one remaining
    // metadata option, while selecting it does not start the pack operation.
    final dynamic zipHomeState = tester.state(find.byType(HomeScreen));
    await tester.tap(find.byTooltip('Choose package format'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byType(CheckedPopupMenuItem<Zip3Format>).last,
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(zipHomeState.c.zip3Format, Zip3Format.legacy);
    expect(zipHomeState.c.stage, StageState.idle);
    expect(find.textContaining('Enforce model'), findsOneWidget);
    expect(find.text('Pack zip 3'), findsWidgets);

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
