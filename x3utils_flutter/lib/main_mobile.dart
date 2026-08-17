// Mobile web entrypoint — the phone layout, delivered by Chrome on a phone.
//
// Hosted under /m/ on the x3utils-web Pages project; lib/main.dart keeps /.
//
// This is the PHONE TIER, not a narrow rendering of the web app. Desktop is the
// full tool, the web build at / tracks it closely and is limited mainly by file
// IO, and the phone is deliberately a subset of both. That subset is defined
// once, in AppController, and shared by this build and the Android APK.
//
// TWO FLAGS, deliberately separate:
//
//   phoneMode   the TIER — the compact layout and the reduced action set.
//               True here and in the APK.
//   androidMode the PLATFORM — USB-host transport, scoped storage, the
//               permission wording. True in the APK, FALSE here.
//
// browserMode is not passed: it defaults to kIsWeb, which is true in this
// build. AppController's constructor tests _browserMode before _androidMode, so
// the backend built is the WebUSB one. Layout and feature set from the phone
// tier, transport and storage from the browser.
//
// Because androidMode is false here, every platform-worded branch already
// resolves to its browser text — "WebUSB unavailable" rather than "USB host
// unavailable", "Select ST-Link" rather than "USB permission required", the
// browser-download backup note in Settings, and the WebUSB About legalese. The
// two strings that were hardcoded rather than branched are now
// AppController.probeTransportLabel and .backupDestinationLabel.
//
// Verified on hardware 2026-08-17 (Galaxy A16, Chrome, loca.lt tunnel, clone
// ST-Link/V2 V2J37): Check connection passed against a live AT32F415CBT7 —
// IDCODE 0x2BA01477, watchdogs frozen, Vtarget 3.15 V, swdart exit 0.

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'main.dart' show HomeScreen;
import 'theme.dart';

void main() => runApp(const X3UtilsMobileApp());

class X3UtilsMobileApp extends StatelessWidget {
  const X3UtilsMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Mirrors X3UtilsApp in main.dart: rebuild the whole tree when the accent
    // changes. Not reused from there because X3UtilsApp builds its own
    // HomeScreen and cannot be handed a controller.
    return ValueListenableBuilder<int>(
      valueListenable: accentNotifier,
      builder: (context, idx, _) {
        AppColors.applyAccent(idx);
        return MaterialApp(
          title: 'x3utils',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          // Non-const so an accent change rebuilds the tree, same as main.dart.
          home: HomeScreen(controller: AppController(phoneMode: true)),
        );
      },
    );
  }
}
