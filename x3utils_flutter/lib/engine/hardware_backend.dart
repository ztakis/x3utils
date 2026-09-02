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
  });

  final Set<ConnectionMode> connectionModes;
  final bool check;
  final bool dump;
  final bool flashFull;
  final bool flashSlot0;
  final bool protectionCheck;
  final bool protectionRescue;

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
  });

  final int exitCode;
  final HardwareEvidence evidence;

  /// In-memory read result used by backends that do not write a native path.
  final Uint8List? bytes;

  /// Optional SRAM snapshot captured by swdart during the same halted session
  /// as a full flash dump. It is never persisted as part of the backup.
  final Uint8List? sramBytes;

  bool get ok => exitCode == 0;
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
