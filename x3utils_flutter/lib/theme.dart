import 'package:flutter/material.dart';

/// Locked "Flash Studio" palette — dark, arcade-like, single-theme.
/// Mirrors design/flash-studio.html.
class AppColors {
  static const bg = Color(0xFF0A0D13);
  static const bg2 = Color(0xFF0E1219);
  static const panel = Color(0xFF141A25);
  static const panel2 = Color(0xFF1A2230);
  static const elev = Color(0xFF212C3D);
  static const line = Color(0x14FFFFFF); // white @ ~8%
  static const line2 = Color(0x26FFFFFF); // white @ ~15%
  static const txt = Color(0xFFE8EDF4);
  static const dim = Color(0xFF96A2B6);
  static const mut = Color(0xFF5D6A7E);

  static const brand = Color(0xFF16E0C4); // electric teal — the one bold accent
  static const brand2 = Color(0xFF0FB9A6);
  static const pop = Color(0xFFFF2E88); // rare hot-magenta pop

  // semantic (separate from accent)
  static const hold = Color(0xFFFFB224); // amber
  static const release = Color(0xFFFF7A2F); // orange
  static const ok = Color(0xFF38E08A); // green
  static const danger = Color(0xFFFF4D5E); // red
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.brand,
      secondary: AppColors.pop,
      surface: AppColors.panel,
      error: AppColors.danger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.txt,
      displayColor: AppColors.txt,
      fontFamily: 'Segoe UI',
    ),
    splashFactory: InkRipple.splashFactory,
  );
}

/// Monospace for console + numeric readouts (Windows-present).
const kMono = 'Consolas';

/// App version — single source of truth (keep pubspec.yaml `version:` in sync).
const kAppVersion = '0.9';
