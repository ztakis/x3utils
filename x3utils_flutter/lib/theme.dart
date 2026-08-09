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

  // Accent — swappable at runtime via applyAccent() (see kAccents below).
  // NB: because these are non-const, widgets that use them can't be `const`.
  static Color brand = kAccents[1].brand;
  static Color brand2 = kAccents[1].brand2;
  static Color pop = kAccents[1].pop;

  // semantic (meaning-based — same across all accent themes)
  static const hold = Color(0xFFFFB224); // amber
  static const release = Color(0xFFFF7A2F); // orange
  static const ok = Color(0xFF38E08A); // green
  static const danger = Color(0xFFFF4D5E); // red

  // Connection-mode identity. These carry what the old A/B/C/D badge letter
  // carried, so they must NOT follow the swappable accent: Silver and Sand are
  // near-neutral, and a mode glyph tinted with them reads as gray-on-gray.
  // Amber/orange/red are deliberately skipped — they already mean hold,
  // release and destructive, and the action risk dots use that vocabulary.
  static const modeDefault = Color(0xFF4FE3FF); // cyan
  static const modeRace = Color(0xFF38E08A); // green (same value as ok, but
  // this is identity, not a verdict — the two never share a widget)
  static const modeClone = Color(0xFF9D6BFF); // violet
  static const modeGenuine = Color(0xFF3D9BFF); // blue

  static void applyAccent(int index) {
    final a = kAccents[index.clamp(0, kAccents.length - 1)];
    brand = a.brand;
    brand2 = a.brand2;
    pop = a.pop;
  }
}

/// A dark-ground accent theme (only the bold accent changes; grounds + semantic
/// colours stay fixed).
class AccentTheme {
  const AccentTheme(this.name, this.brand, this.brand2, this.pop);
  final String name;
  final Color brand, brand2, pop;
}

const kAccents = <AccentTheme>[
  AccentTheme('Teal', Color(0xFF16E0C4), Color(0xFF0FB9A6), Color(0xFFFF2E88)),
  AccentTheme(
    'Silver',
    Color(0xFFC4CDD8),
    Color(0xFF97A3B1),
    Color(0xFFE7ECF3),
  ),
  AccentTheme('Blue', Color(0xFF3D9BFF), Color(0xFF2C7BE0), Color(0xFF26D8F0)),
  // Appended, never reordered — accentIndex is persisted by position.
  AccentTheme('Ice', Color(0xFF4FE3FF), Color(0xFF2BB8DB), Color(0xFF7A6BFF)),
  AccentTheme('Sand', Color(0xFFD8C4A0), Color(0xFFAE9B79), Color(0xFFF2E6CE)),
  AccentTheme(
    'Indigo',
    Color(0xFF6C7BFF),
    Color(0xFF4A57E0),
    Color(0xFFB05CFF),
  ),
  AccentTheme(
    'Violet',
    Color(0xFF9D6BFF),
    Color(0xFF7A46E6),
    Color(0xFF16E0C4),
  ),
];

/// Drives a MaterialApp rebuild when the accent changes (see X3UtilsApp).
final accentNotifier = ValueNotifier<int>(1); // default: Silver

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

/// Shared max width for the stacked hero blocks — warning/result callouts,
/// the firmware bar, and the Make zip3 identity form — so they align
/// edge-to-edge instead of stepping in and out at different widths.
const kHeroBlockWidth = 500.0;

/// App version — single source of truth (keep pubspec.yaml `version:` in sync).
const kAppVersion = '1.3.0';
// Release channel shown after the version (e.g. "v1.2.0 BETA"); '' for stable.
// Kept OUT of kAppVersion so VERSION / pubspec / kAppVersion stay byte-equal —
// package_macos.sh asserts that three-way match.
const kAppStage = '';
// What the UI renders after the leading "v".
final kAppVersionLabel = kAppStage.isEmpty
    ? kAppVersion
    : '$kAppVersion $kAppStage';
