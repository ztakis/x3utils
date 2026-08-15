import '../models.dart';
import 'hardware_backend.dart';
import 'openocd_runner.dart';
import 'rdp_runner.dart';

/// Adapts the existing field-proven OpenOCD runners to [HardwareBackend].
class OpenOcdBackend implements HardwareBackend {
  OpenOcdBackend({required this.runner, this.protectionRunner});

  final OpenOcdRunner runner;
  final RdpRunner? protectionRunner;

  static final RegExp _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

  @override
  String get name => 'OpenOCD';

  @override
  HardwareCapabilities get capabilities {
    final protection = protectionRunner?.available ?? false;
    return HardwareCapabilities(
      connectionModes: ConnectionMode.values.toSet(),
      check: true,
      dump: true,
      flashFull: true,
      flashSlot0: true,
      protectionCheck: protection,
      protectionRescue: protection,
    );
  }

  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) async {
    final args = switch (request.operation) {
      HardwareOperation.check => runner.checkArgs(
        request.mode,
        request.countdown,
      ),
      HardwareOperation.dump => runner.dumpArgs(
        request.mode,
        request.countdown,
        _requiredPath(request),
      ),
      HardwareOperation.flashFull => runner.flashArgs(
        request.mode,
        request.countdown,
        _requiredPath(request),
      ),
      HardwareOperation.flashSlot0 => runner.flashSlot0Args(
        request.mode,
        request.countdown,
        _requiredPath(request),
      ),
    };

    final guided = request.mode.guided;
    void onLine(String line) {
      callbacks.onLine(line);
      _emitStructuredLine(line, guided: guided, callbacks: callbacks);
    }

    final OpenOcdResult result;
    if (request.mode == ConnectionMode.powerRace) {
      result = await runner.runRace(
        args,
        onLine: onLine,
        onCaught: callbacks.onCaught,
        onAttempt: (attempt, tier) {
          callbacks.onAttempt(attempt, _mapRaceTier(tier));
        },
      );
    } else {
      result = await runner.run(args, onLine);
    }

    return HardwareResult(
      result.exitCode,
      HardwareEvidence(
        caught: result.evidence.caught,
        dumped: result.evidence.dumped,
        erased: result.evidence.erased,
        wrote: result.evidence.wrote,
        verified: result.evidence.verified,
      ),
    );
  }

  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) async {
    final rdp = protectionRunner;
    if (rdp == null || !rdp.available) {
      throw StateError('OpenOCD protection toolkit is unavailable');
    }
    final guided = request.mode.guided;
    final code = await rdp.run(
      request.operation == HardwareProtectionOperation.check
          ? 'Check'
          : 'Rescue',
      request.mode,
      request.countdown,
      yes: request.operation == HardwareProtectionOperation.rescue,
      onLine: (line) {
        callbacks.onLine(line);
        final guidedEvent = _guidedEvent(line, guided: guided);
        if (guidedEvent != null) callbacks.onGuided(guidedEvent);
      },
      onChunk: callbacks.onChunk,
    );
    final verdict = switch ((request.operation, code)) {
      (HardwareProtectionOperation.check, 0) =>
        HardwareProtectionVerdict.notProtected,
      (HardwareProtectionOperation.check, 2) =>
        HardwareProtectionVerdict.protected,
      (HardwareProtectionOperation.check, _) =>
        HardwareProtectionVerdict.inconclusive,
      (HardwareProtectionOperation.rescue, 0) =>
        HardwareProtectionVerdict.rescued,
      (HardwareProtectionOperation.rescue, _) =>
        HardwareProtectionVerdict.failed,
    };
    return HardwareProtectionResult(code, verdict);
  }

  @override
  bool sendContinue({required bool protection}) => protection
      ? (protectionRunner?.sendContinue() ?? false)
      : runner.sendContinue();

  @override
  void cancel() {
    runner.kill();
    protectionRunner?.kill();
  }

  String _requiredPath(HardwareRequest request) {
    final path = request.filePath;
    if (path == null || path.isEmpty) {
      throw ArgumentError.value(
        path,
        'request.filePath',
        '${request.operation.name} requires a native file path',
      );
    }
    return path;
  }

  void _emitStructuredLine(
    String line, {
    required bool guided,
    required HardwareCallbacks callbacks,
  }) {
    final clean = line.replaceAll(_ansi, '').trim();
    final low = clean.toLowerCase();
    final fromTarget = !clean.startsWith('> ');
    if (fromTarget && hasTargetProgressEvidence(low)) {
      callbacks.onProgress(
        HardwareProgress(
          connected:
              low.contains('target halted') ||
              low.contains('caught; hold power') ||
              low.contains('x3_caught_hold_power'),
        ),
      );
    }
    final guidedEvent = _guidedEvent(line, guided: guided);
    if (guidedEvent != null) callbacks.onGuided(guidedEvent);
  }

  HardwareGuidedEvent? _guidedEvent(String line, {required bool guided}) {
    if (!guided) return null;
    final clean = line.replaceAll(_ansi, '').trim();
    final low = clean.toLowerCase();
    if (low.contains('hold a wire between') ||
        low.contains('keep it grounded')) {
      return const HardwareGuidedEvent(HardwareGuidedStage.hold);
    }
    if (low.contains('remove the wire from gnd') ||
        low.contains('release nrst')) {
      return const HardwareGuidedEvent(HardwareGuidedStage.release);
    }
    if (low.contains('connected') && low.contains('ready')) {
      return const HardwareGuidedEvent(HardwareGuidedStage.connected);
    }
    if (low.contains('connecting in')) {
      return HardwareGuidedEvent(
        HardwareGuidedStage.count,
        countdown: _trailingInt(line),
      );
    }
    final tick = _countdownTick(line);
    if (tick != null) {
      return HardwareGuidedEvent(HardwareGuidedStage.count, countdown: tick);
    }
    return null;
  }

  int? _trailingInt(String value) {
    final matches = RegExp(r'(\d+)').allMatches(value);
    return matches.isEmpty ? null : int.tryParse(matches.last.group(1)!);
  }

  int? _countdownTick(String line) {
    final match = RegExp(r'^(\d+)\s*\.?$').firstMatch(line.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  HardwareRaceTier _mapRaceTier(RaceTier tier) => switch (tier) {
    RaceTier.searching => HardwareRaceTier.searching,
    RaceTier.noisy => HardwareRaceTier.noisy,
    RaceTier.nearCatch => HardwareRaceTier.nearCatch,
    RaceTier.adapterGone => HardwareRaceTier.adapterGone,
    RaceTier.timedOut => HardwareRaceTier.timedOut,
  };
}
