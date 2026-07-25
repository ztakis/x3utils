import 'package:flutter/material.dart';
import 'theme.dart';

// Script-compatible labels keep genuine C45 on C. Power-race is the extra GUI
// respawn connect mode, so it lives on D.
enum ConnectionMode { defaultSwd, cloneC45, genuineC45, powerRace }

extension ConnectionModeX on ConnectionMode {
  String get tag => switch (this) {
    ConnectionMode.defaultSwd => 'A',
    ConnectionMode.cloneC45 => 'B',
    ConnectionMode.genuineC45 => 'C',
    ConnectionMode.powerRace => 'D',
  };
  String get title => switch (this) {
    ConnectionMode.defaultSwd => 'Default SWD',
    ConnectionMode.cloneC45 => 'C45 · Clone',
    ConnectionMode.genuineC45 => 'C45 · Genuine',
    ConnectionMode.powerRace => 'Power-race',
  };
  String get sub => switch (this) {
    ConnectionMode.defaultSwd => 'Blinker buttons',
    ConnectionMode.cloneC45 => 'Guided hold / release',
    ConnectionMode.genuineC45 => 'Hardware nRST',
    ConnectionMode.powerRace => 'Respawn connect',
  };
  bool get guided => this == ConnectionMode.cloneC45;
}

/// Visual state of the central hero stage.
enum StageState { idle, hold, count, release, connect, run, ok, warn, fail }

extension StageStateX on StageState {
  Color get accent => switch (this) {
    StageState.hold || StageState.count || StageState.warn => AppColors.hold,
    StageState.release => AppColors.release,
    StageState.connect || StageState.run => AppColors.brand,
    StageState.ok => AppColors.ok,
    StageState.fail => AppColors.danger,
    StageState.idle => AppColors.brand,
  };
}

enum MessageTone { normal, notice, danger }

extension MessageToneX on MessageTone {
  Color get color => switch (this) {
    MessageTone.normal => AppColors.dim,
    MessageTone.notice => AppColors.hold,
    MessageTone.danger => AppColors.danger,
  };
}

/// Rail grouping: everyday tasks vs power-user tools (Advanced is collapsible).
enum Section { standard, advanced }

extension SectionX on Section {
  String get label => this == Section.standard ? 'Actions' : 'Advanced';
}

enum DangerLevel { none, soft, hard }

/// Write scope inside the deliberately unguarded Flash Only action.
enum FlashOnlyScope { fullImage, slot0 }

/// Page shown by the offline zip3 workspace.
enum Zip3WorkspacePage { slice, pack, unpack }

extension DangerLevelX on DangerLevel {
  /// The tile dot encodes risk at a glance: safe / write / destructive.
  Color get dot => switch (this) {
    DangerLevel.none => AppColors.ok,
    DangerLevel.soft => AppColors.brand,
    DangerLevel.hard => AppColors.danger,
  };
}

enum ChipKind { ok, brand, warn, danger }

extension ChipKindX on ChipKind {
  Color get color => switch (this) {
    ChipKind.ok => AppColors.ok,
    ChipKind.brand => AppColors.brand,
    ChipKind.warn => AppColors.hold,
    ChipKind.danger => AppColors.danger,
  };
}

class InfoChipData {
  final String label;
  final ChipKind kind;
  const InfoChipData(this.label, this.kind);
}

class FlashAction {
  final String id;
  final Section section;
  final String name; // friendly name
  final String script; // underlying script / command, shown smaller
  final String sub;
  final List<InfoChipData> chips;
  final String cta;
  final DangerLevel danger;
  final String okMsg;
  final bool needsFirmware; // gates the .bin picker
  const FlashAction({
    required this.id,
    required this.section,
    required this.name,
    required this.script,
    required this.sub,
    required this.chips,
    required this.cta,
    required this.okMsg,
    this.danger = DangerLevel.none,
    this.needsFirmware = false,
  });
}

/// Actions mirror design/flash-studio.html; wired to the frozen oocd later.
const kActions = <FlashAction>[
  // ── Standard ──────────────────────────────────────────────
  FlashAction(
    id: 'check',
    section: Section.standard,
    name: 'Check connection',
    script: 'connect · probe',
    sub: 'Probe the ST-LINK and the target. Reads nothing, writes nothing.',
    chips: [InfoChipData('read-only', ChipKind.ok)],
    cta: 'Check connection',
    okMsg: 'Target answered. You’re good to go.',
  ),
  FlashAction(
    id: 'dump',
    section: Section.standard,
    name: 'Backup',
    script: 'dump · 128 KB',
    sub: 'Read the whole flash to a timestamped backup you can restore later.',
    chips: [InfoChipData('read-only', ChipKind.ok)],
    cta: 'Start backup',
    okMsg: 'Backed up & verified → backup/dump_2026-07-09.bin',
  ),
  FlashAction(
    id: 'flash_compat',
    section: Section.standard,
    name: 'SHU compatible',
    script: 'flash_compat',
    sub:
        'Back up the chip, patch its own firmware for SHU compatibility (ZT3 / G3 / F3), and flash it back. No file needed.',
    chips: [
      InfoChipData('backs up first', ChipKind.brand),
      InfoChipData('patches firmware', ChipKind.warn),
    ],
    cta: 'Make SHU compatible',
    danger: DangerLevel.soft,
    okMsg: 'SHU-compatible firmware flashed & verified.',
  ),
  FlashAction(
    id: 'flash_backup',
    section: Section.standard,
    name: 'Backup + Flash',
    script: 'flash',
    sub: 'Back up the chip first, then write and verify your firmware.',
    chips: [InfoChipData('backs up first', ChipKind.brand)],
    cta: 'Start flash',
    danger: DangerLevel.soft,
    okMsg: 'Flashed & verified. Backup saved first.',
    needsFirmware: true,
  ),
  // ── Advanced ──────────────────────────────────────────────
  FlashAction(
    id: 'flash_only',
    section: Section.advanced,
    name: 'Flash Only',
    script: 'flash_only',
    sub: 'Write and verify with no backup.',
    chips: [InfoChipData('no backup', ChipKind.warn)],
    cta: 'Flash without backup',
    danger: DangerLevel.hard,
    okMsg: 'Flashed & verified. No backup was taken.',
    needsFirmware: true,
  ),
  FlashAction(
    id: 'flash_slot0',
    section: Section.advanced,
    name: 'Flash slot 0',
    script: 'flash_slot0',
    sub:
        'Backs up the chip first, then writes slot 0 only — boot, slot 1 and user-data stay untouched.',
    chips: [
      InfoChipData('backs up first', ChipKind.brand),
      InfoChipData('identity-safe', ChipKind.ok),
    ],
    cta: 'Flash slot 0',
    danger: DangerLevel.soft,
    okMsg: 'Slot 0 flashed & verified. Identity intact.',
    needsFirmware: true,
  ),
  FlashAction(
    id: 'make_zip3',
    section: Section.advanced,
    name: 'ZIP3 tools',
    script: 'slice · pack · unpack',
    sub:
        'Slice a 128 KB backup, pack a firmware .bin, or unpack a zip3 package. Fully offline.',
    chips: [InfoChipData('offline', ChipKind.ok)],
    cta: 'Pack zip3',
    okMsg: 'zip3 package written.',
    needsFirmware: true,
  ),
  FlashAction(
    id: 'rdp_check',
    section: Section.advanced,
    name: 'Check protection',
    script: 'rdp_check',
    sub: 'Read the flash-access-protection state and report a plain verdict.',
    chips: [InfoChipData('read-only', ChipKind.ok)],
    cta: 'Check protection',
    okMsg: 'PROTECTED · FAP active, flash is read-locked.',
  ),
  FlashAction(
    id: 'rdp_rescue',
    section: Section.advanced,
    name: 'Unlock / rescue',
    script: 'rdp_rescue',
    sub:
        'Rewrite the option bytes to clear read protection. This mass-erases the flash.',
    chips: [
      InfoChipData('rewrites option bytes', ChipKind.danger),
      InfoChipData('erases flash', ChipKind.danger),
    ],
    cta: 'Run rescue',
    danger: DangerLevel.hard,
    okMsg:
        'Rewrite sent. Power-cycle the board, then run Check protection to confirm it’s unlocked.',
  ),
];
