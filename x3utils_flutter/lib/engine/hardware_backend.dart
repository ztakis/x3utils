import 'dart:typed_data';

import '../models.dart';

/// Hardware operations shared by the controller and every concrete backend.
enum HardwareOperation { check, dump, flashFull, flashSlot0 }

/// Backend-neutral classification for a Power-race connection attempt.
enum HardwareRaceTier { searching, noisy, nearCatch, adapterGone, timedOut }

/// Stages in the guided clone-C45 hold/count/release flow.
enum HardwareGuidedStage { hold, count, release, connected }

/// Backend-neutral USB/probe readiness shown before hardware work starts.
enum HardwareDeviceState {
  unsupported,
  selectionRequired,
  ready,
  disconnected,
  ambiguous,
}

class HardwareDeviceStatus {
  const HardwareDeviceStatus(this.state, {this.productName});

  final HardwareDeviceState state;
  final String? productName;

  bool get ready => state == HardwareDeviceState.ready;
}

enum HardwareFailureKind {
  userCancelled,
  permissionRequired,
  unsupported,
  deviceDisconnected,
  deviceAmbiguous,
  deviceUnavailable,
  deviceBusy,
  targetContact,
  unsupportedTarget,
  operation,
}

class HardwareException implements Exception {
  const HardwareException(this.kind, this.message);

  final HardwareFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

class HardwareGuidedEvent {
  const HardwareGuidedEvent(this.stage, {this.countdown});

  final HardwareGuidedStage stage;
  final int? countdown;
}

/// Live progress that proves the target answered or work may have started.
class HardwareProgress {
  const HardwareProgress({required this.connected});

  final bool connected;
}

class HardwareCapabilities {
  const HardwareCapabilities({
    required this.connectionModes,
    required this.check,
    required this.dump,
    required this.flashFull,
    required this.flashSlot0,
    required this.protectionCheck,
    required this.protectionRescue,
    this.extraBackup = false,
  });

  final Set<ConnectionMode> connectionModes;
  final bool check;
  final bool dump;
  final bool flashFull;
  final bool flashSlot0;
  final bool protectionCheck;
  final bool protectionRescue;

  /// Can capture SRAM, raw protection evidence, and two independent full
  /// flash reads in one connected session for standalone Backup.
  final bool extraBackup;

  bool supports(HardwareOperation operation, ConnectionMode mode) {
    if (!connectionModes.contains(mode)) return false;
    return switch (operation) {
      HardwareOperation.check => check,
      HardwareOperation.dump => dump,
      HardwareOperation.flashFull => flashFull,
      HardwareOperation.flashSlot0 => flashSlot0,
    };
  }

  bool supportsProtection(
    HardwareProtectionOperation operation,
    ConnectionMode mode,
  ) {
    if (!connectionModes.contains(mode)) return false;
    return switch (operation) {
      HardwareProtectionOperation.check => protectionCheck,
      HardwareProtectionOperation.rescue => protectionRescue,
    };
  }
}

class HardwareRequest {
  const HardwareRequest({
    required this.operation,
    required this.mode,
    required this.countdown,
    this.filePath,
    this.bytes,
    this.captureSram = false,
    this.extraBackup = false,
  });

  final HardwareOperation operation;
  final ConnectionMode mode;
  final int countdown;

  /// Native input/output path used by the temporary OpenOCD adapter.
  ///
  /// A WebUSB backend can return or consume bytes without using this field.
  final String? filePath;

  /// In-memory program input used by browser/native-library backends.
  final Uint8List? bytes;

  /// Ask a capable backend to take an SRAM snapshot during this same halted
  /// session. SHU Compat opts in; ordinary backups remain unchanged.
  final bool captureSram;

  /// Opt in to the standalone Backup BETA evidence capture. Other actions
  /// leave this false even when they also take a safety backup.
  final bool extraBackup;
}

class HardwareEvidence {
  const HardwareEvidence({
    this.caught = false,
    this.dumped = false,
    this.erased = false,
    this.wrote = false,
    this.verified = false,
    this.resetRunning = false,
    this.sramAttempted = false,
  });

  final bool caught;
  final bool dumped;
  final bool erased;
  final bool wrote;
  final bool verified;
  final bool resetRunning;
  final bool sramAttempted;
}

class HardwareResult {
  const HardwareResult(
    this.exitCode,
    this.evidence, {
    this.bytes,
    this.sramBytes,
    this.comparisonBytes,
    this.extraBackupEvidence,
  });

  final int exitCode;
  final HardwareEvidence evidence;

  /// In-memory read result used by backends that do not write a native path.
  final Uint8List? bytes;

  /// Optional SRAM snapshot captured by swdart during the same halted session
  /// as a full flash dump. It is never persisted as part of the backup.
  final Uint8List? sramBytes;

  /// The second full flash read from an Extra backup. Product policy compares
  /// it with [bytes] above the hardware boundary.
  final Uint8List? comparisonBytes;

  /// Raw, backend-observed context for an Extra backup certificate.
  final ExtraBackupHardwareEvidence? extraBackupEvidence;

  bool get ok => exitCode == 0;
}

class ExtraBackupHardwareEvidence {
  const ExtraBackupHardwareEvidence({
    required this.targetName,
    required this.targetFamily,
    required this.idcode,
    required this.flashKB,
    required this.pageSize,
    required this.sramBytes,
    required this.usdWord,
    this.flashReadSkipped = false,
  });

  final String targetName;
  final String targetFamily;
  final int idcode;
  final int flashKB;
  final int pageSize;
  final int sramBytes;

  /// Raw 32-bit option/USD word at 0x1FFFF800, or null when that evidence
  /// could not be read. Null must remain inconclusive rather than protected.
  final int? usdWord;

  /// Extra backup only: the pre-read protection probe classified the target as
  /// protected, so the two 128 KiB reads were skipped and no backup bytes
  /// exist. Only a `protected` verdict sets this — an inconclusive probe falls
  /// through to the normal full read, so this can never deny a backup.
  final bool flashReadSkipped;
}

class HardwareCallbacks {
  const HardwareCallbacks({
    required this.onLine,
    required this.onProgress,
    required this.onGuided,
    required this.onCaught,
    required this.onAttempt,
  });

  final void Function(String line) onLine;
  final void Function(HardwareProgress progress) onProgress;
  final void Function(HardwareGuidedEvent event) onGuided;
  final void Function() onCaught;
  final void Function(int attempt, HardwareRaceTier tier) onAttempt;
}

enum HardwareProtectionOperation { check, rescue }

class HardwareProtectionRequest {
  const HardwareProtectionRequest({
    required this.operation,
    required this.mode,
    required this.countdown,
  });

  final HardwareProtectionOperation operation;
  final ConnectionMode mode;
  final int countdown;
}

class HardwareProtectionResult {
  const HardwareProtectionResult(this.exitCode, this.verdict);

  final int exitCode;
  final HardwareProtectionVerdict verdict;
}

enum HardwareProtectionVerdict {
  notProtected,
  protected,
  inconclusive,
  rescued,
  failed,
}

class HardwareProtectionCallbacks {
  const HardwareProtectionCallbacks({
    required this.onLine,
    required this.onChunk,
    required this.onGuided,
  });

  final void Function(String line) onLine;
  final void Function(String chunk) onChunk;
  final void Function(HardwareGuidedEvent event) onGuided;
}

/// The hardware boundary used by [AppController].
///
/// Product policy remains above this interface. Implementations perform the
/// requested hardware operation and return structured completion evidence.
abstract interface class HardwareBackend {
  String get name;

  HardwareCapabilities get capabilities;

  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  );

  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  );

  bool sendContinue({required bool protection});

  void cancel();
}

/// Optional probe-selection lifecycle for transports such as WebUSB.
abstract interface class HardwareDeviceBackend {
  HardwareDeviceStatus get deviceStatus;

  Future<HardwareDeviceStatus> refreshDevice();

  Future<HardwareDeviceStatus> selectDevice();

  void watchDevice(HardwareDeviceStatusListener listener);
}

typedef HardwareDeviceStatusListener =
    void Function(HardwareDeviceStatus status);
