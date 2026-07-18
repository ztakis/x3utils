// Single source of truth for the app version across every place it appears.
//
//   dart run tool/version.dart                  # CHECK: report all, fail on drift
//   dart run tool/version.dart 1.2.1            # SET version everywhere (+build bump)
//   dart run tool/version.dart 1.2.1 --stage BETA
//   dart run tool/version.dart --stage ""       # keep version, clear the channel
//   dart run tool/version.dart 1.3.0 --build 9  # explicit build number
//
// Places kept in sync (7):
//   1. VERSION                    <x.y.z>
//   2. pubspec.yaml   version:    <x.y.z>+<build>   (the x.y.z part)
//   3. pubspec.yaml   version:    ...+<build>       (the build number)
//   4. lib/theme.dart kAppVersion <x.y.z>
//   5. lib/theme.dart kAppStage   <channel>         (e.g. BETA, '' for stable)
//   6. installer/x3utils.iss      #define AppVer
//   7. README.md                  Current: **<x.y.z>**
//
// The five x.y.z strings (1,2,4,6,7) must match — that is what CHECK enforces
// and package_macos.sh relies on. The build number and stage are single-sourced.

import 'dart:io';

const _versionFile = 'VERSION';
const _pubspec = 'pubspec.yaml';
const _theme = 'lib/theme.dart';
const _iss = 'installer/x3utils.iss';
const _readme = 'README.md';

// No `\s*$` end-anchor: `\s` matches newlines, so a greedy tail would eat the
// blank line after `version:`. Match only through the build digits.
final _rePubspec = RegExp(r'^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)', multiLine: true);
final _reKAppVersion = RegExp(r"const kAppVersion = '([^']*)';");
final _reKAppStage = RegExp(r"const kAppStage = '([^']*)';");
final _reAppVer = RegExp(r'#define AppVer "([^"]*)"');
final _reReadme = RegExp(r'Current: \*\*([^*]+)\*\*');
final _reSemver = RegExp(r'^\d+\.\d+\.\d+$');

final String _root = _findRoot();

void main(List<String> args) {
  String? version;
  String? stage;
  int? build;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--stage') {
      stage = _need(args, ++i, '--stage');
    } else if (a == '--build') {
      build = int.tryParse(_need(args, ++i, '--build')) ?? _die('--build must be an integer');
    } else if (a == '--check' || a == '-c') {
      // explicit check; no-op flag
    } else if (a.startsWith('-')) {
      _die('unknown flag: $a');
    } else if (version == null) {
      version = a;
    } else {
      _die('unexpected argument: $a');
    }
  }

  if (version == null && stage == null && build == null) {
    exit(_check() ? 0 : 1);
  }
  _set(version: version, stage: stage, build: build);
}

// ── CHECK ──────────────────────────────────────────────────────────────────

bool _check() {
  final v = _readState();
  final want = v.versionFile;
  final rows = <(String, String, bool)>[
    ('VERSION', v.versionFile, true),
    ('pubspec version', v.pubspecVersion, true),
    ('pubspec build', '+${v.build}', false),
    ('kAppVersion', v.kAppVersion, true),
    ('kAppStage', v.stage.isEmpty ? '(stable)' : v.stage, false),
    ('installer AppVer', v.appVer, true),
    ('README Current', v.readme, true),
  ];
  var ok = true;
  stdout.writeln('version — 7 places:');
  for (final (label, value, mustMatch) in rows) {
    final bad = mustMatch && value != want;
    if (bad) ok = false;
    final mark = !mustMatch ? ' ' : (bad ? '✗' : '✓');
    stdout.writeln('  $mark ${label.padRight(18)} $value');
  }
  stdout.writeln(ok
      ? 'OK — all in sync at $want${v.stage.isEmpty ? '' : ' ${v.stage}'}.'
      : 'DRIFT — the ✗ rows disagree with VERSION ($want). '
          'Run: dart run tool/version.dart $want');
  return ok;
}

// ── SET ────────────────────────────────────────────────────────────────────

void _set({String? version, String? stage, int? build}) {
  final cur = _readState();
  final target = version ?? cur.versionFile;
  if (!_reSemver.hasMatch(target)) _die('version must be x.y.z, got "$target"');
  // Bump the build only when the version actually changes, unless overridden.
  final targetBuild = build ?? (target != cur.versionFile ? cur.build + 1 : cur.build);
  final targetStage = stage ?? cur.stage;

  _write(_versionFile, '$target\n');
  _replace(_pubspec, _rePubspec, 'version: $target+$targetBuild');
  _replace(_theme, _reKAppVersion, "const kAppVersion = '$target';");
  _replace(_theme, _reKAppStage, "const kAppStage = '$targetStage';");
  _replace(_iss, _reAppVer, '#define AppVer "$target"');
  _replace(_readme, _reReadme, 'Current: **$target**');

  stdout.writeln('set → $target+$targetBuild'
      '${targetStage.isEmpty ? '' : ' $targetStage'}');
  if (!_check()) {
    _die('post-write check failed — files may be in an inconsistent state');
  }
}

// ── state / io ──────────────────────────────────────────────────────────────

class _State {
  _State({
    required this.versionFile,
    required this.pubspecVersion,
    required this.build,
    required this.kAppVersion,
    required this.stage,
    required this.appVer,
    required this.readme,
  });
  final String versionFile;
  final String pubspecVersion;
  final int build;
  final String kAppVersion;
  final String stage;
  final String appVer;
  final String readme;
}

_State _readState() {
  final pub = _rePubspec.firstMatch(_read(_pubspec)) ??
      _die('could not parse "version: x.y.z+build" in $_pubspec');
  final theme = _read(_theme);
  return _State(
    versionFile: _read(_versionFile).trim(),
    pubspecVersion: pub.group(1)!,
    build: int.parse(pub.group(2)!),
    kAppVersion: _g1(theme, _reKAppVersion, _theme, 'kAppVersion'),
    stage: _g1(theme, _reKAppStage, _theme, 'kAppStage'),
    appVer: _g1(_read(_iss), _reAppVer, _iss, 'AppVer'),
    readme: _g1(_read(_readme), _reReadme, _readme, 'Current: **…**'),
  );
}

String _g1(String content, RegExp re, String file, String what) =>
    re.firstMatch(content)?.group(1) ?? _die('could not find $what in $file');

void _replace(String rel, RegExp re, String replacement) {
  final content = _read(rel);
  if (!re.hasMatch(content)) _die('pattern for $rel not found — did the format change?');
  _write(rel, content.replaceFirst(re, replacement));
}

String _read(String rel) => File(_path(rel)).readAsStringSync();
void _write(String rel, String content) => File(_path(rel)).writeAsStringSync(content);
String _path(String rel) => '$_root/$rel';

String _findRoot() {
  try {
    final root = File.fromUri(Platform.script).parent.parent.path; // <root>/tool/version.dart
    if (File('$root/$_pubspec').existsSync()) return root;
  } catch (_) {}
  if (File(_pubspec).existsSync()) return Directory.current.path;
  _die('cannot locate the project root — run: dart run tool/version.dart');
}

String _need(List<String> args, int i, String flag) =>
    i < args.length ? args[i] : _die('$flag needs a value');

Never _die(String msg) {
  stderr.writeln('version: $msg');
  exit(2);
}
