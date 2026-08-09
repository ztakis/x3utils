import 'package:flutter/material.dart';
import 'theme.dart';

// Enum ORDER IS PERSISTED: `defaultConnMode` stores `ConnectionMode.index`, so
// appending is safe but reordering silently repoints a saved startup default.
// The GUI carries no A/B/C/D tag. The CLI launchers still letter their menus,
// and the GUI's rail order deliberately differs from them, so a letter here
// would assert a mapping the scripts contradict. Modes are identified by title,
// icon and `kModeOrder`; the GUI passes `Cfg.target(mode)`, never a letter.
enum ConnectionMode { defaultSwd, cloneC45, genuineC45, powerRace }

/// Canonical rail/dropdown order, independent of the persisted enum order.
const kModeOrder = <ConnectionMode>[
  ConnectionMode.defaultSwd,
  ConnectionMode.powerRace,
  ConnectionMode.cloneC45,
  ConnectionMode.genuineC45,
];

extension ConnectionModeX on ConnectionMode {
  /// Fixed identity colour, independent of the swappable accent — see
  /// `AppColors.mode*`. The tile's selection styling stays accent-driven; this
  /// only tints the glyph, so a low-chroma accent can't wash the badge out.
  Color get color => switch (this) {
    ConnectionMode.defaultSwd => AppColors.modeDefault,
    ConnectionMode.cloneC45 => AppColors.modeClone,
    ConnectionMode.genuineC45 => AppColors.modeGenuine,
    ConnectionMode.powerRace => AppColors.modeRace,
  };

  /// Tile badge glyph; replaced the old letter, which read as a CLI mode tag.
  IconData get icon => switch (this) {
    ConnectionMode.defaultSwd => Icons.bolt_rounded,
    ConnectionMode.cloneC45 => Icons.pan_tool_rounded,
    ConnectionMode.genuineC45 => Icons.cable_rounded,
    ConnectionMode.powerRace => Icons.restart_alt_rounded,
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

/// Write scope shared by the two firmware flash actions. Backup + Flash and
/// Flash Only differ in their guards, not in what they can address, so both
/// carry the same Full image / Slot 0 choice rather than a separate slot action.
enum FlashScope { fullImage, slot0 }

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
  /// Kept wired but not rendered in the rail. A retired action stays complete —
  /// definition, dispatch, confirm copy and evidence — so bringing it back is
  /// flipping this flag, not rebuilding it.
  final bool hidden;
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
    this.hidden = false,
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
    id: 'flash_backup',
    section: Section.standard,
    name: 'Backup + Flash',
    script: 'flash',
    sub:
        'Back up the chip first, then write and verify your firmware — the full image, or slot 0 only.',
    chips: [InfoChipData('backs up first', ChipKind.brand)],
    cta: 'Start flash',
    danger: DangerLevel.soft,
    okMsg: 'Flashed & verified. Backup saved first.',
    needsFirmware: true,
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
    id: 'make_zip3',
    section: Section.advanced,
    name: 'ZIP3 tools',
    script: 'slice · pack · unpack',
    sub:
        'Slice a 128 KB backup, pack a firmware .bin, or unpack a zip3 package. Fully offline.',
    chips: [InfoChipData('offline', ChipKind.ok)],
    cta: 'Pack zip 3.2',
    okMsg: 'zip3 package written.',
    needsFirmware: true,
  ),
  // A normal selectable action with a normal hero, so the page has somewhere
  // to grow display options. What it does NOT share is the run machinery:
  // Start opens a report dialog and never enters the stage/verdict path,
  // because nothing here connects to a target. `okMsg` is therefore unused —
  // there is no run outcome to announce.
  FlashAction(
    id: 'file_info',
    section: Section.advanced,
    name: 'Get file info',
    script: 'inspect · bin / zip3',
    sub:
        'Describe any local firmware .bin or zip3 package — identity, version and package metadata. Reads the file only.',
    chips: [InfoChipData('read-only', ChipKind.ok)],
    cta: 'Show file info',
    okMsg: '',
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
  // ── Retired (hidden, still wired) ─────────────────────────
  // Superseded by Backup + Flash's Slot 0 scope, which runs the same
  // `_runFlash(backup: true, slot0: true)` with the same guards. Kept whole
  // rather than deleted: if the merged action ever needs splitting back out,
  // dropping `hidden` returns the tile with its own copy and confirm text.
  FlashAction(
    id: 'flash_slot0',
    section: Section.standard,
    hidden: true,
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
];
