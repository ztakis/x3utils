import '../models.dart';
import 'hardware_backend.dart';

enum DesktopBackendSelection { openOcd, swdart }

/// Selects one authoritative desktop hardware backend for the whole session.
///
/// This is deliberately not an automatic fallback router. Every request goes
/// only to [selection]; unsupported work must fail rather than silently moving
/// to the other backend and contaminating migration evidence.
class DesktopBackendRouter implements HardwareBackend {
  DesktopBackendRouter({
    required this.openOcd,
    required this.swdart,
    this.openOcdUnavailableReason,
  });

  final HardwareBackend? openOcd;
  final HardwareBackend swdart;
  final String? openOcdUnavailableReason;

  DesktopBackendSelection selection = DesktopBackendSelection.openOcd;
  HardwareBackend? _activeBackend;

  void select(DesktopBackendSelection value) => selection = value;

  bool get selectedAvailable => _selectedBackend != null;

  HardwareCapabilities get selectedCapabilities =>
      _selectedBackend?.capabilities ?? _allDesktopCapabilities;

  String? get selectedUnavailableReason =>
      selection == DesktopBackendSelection.openOcd
      ? openOcdUnavailableReason ?? 'Bundled OpenOCD was not found.'
      : null;

  HardwareBackend? get _selectedBackend => switch (selection) {
    DesktopBackendSelection.openOcd => openOcd,
    DesktopBackendSelection.swdart => swdart,
  };

  @override
  String get name => switch (selection) {
    DesktopBackendSelection.openOcd => 'OpenOCD',
    DesktopBackendSelection.swdart => 'swdart',
  };

  /// Keep the complete desktop surface visible while the selected backend's
  /// narrower capabilities provide the preflight/not-implemented verdict.
  @override
  HardwareCapabilities get capabilities => _allDesktopCapabilities;

  static const _allDesktopCapabilities = HardwareCapabilities(
    connectionModes: {
      ConnectionMode.defaultSwd,
      ConnectionMode.cloneC45,
      ConnectionMode.genuineC45,
      ConnectionMode.powerRace,
    },
    check: true,
    dump: true,
    flashFull: true,
    flashSlot0: true,
    protectionCheck: true,
    protectionRescue: true,
  );

  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) async {
    callbacks.onLine(
      '== backend route: $name · ${request.mode.title} · '
      '${request.operation.name} ==',
    );
    final backend = _requireSelectedBackend();
    _activeBackend = backend;
    try {
      return await backend.run(request, callbacks);
    } finally {
      if (identical(_activeBackend, backend)) _activeBackend = null;
    }
  }

  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) async {
    callbacks.onLine(
      '== backend route: $name · ${request.mode.title} · '
      'protection ${request.operation.name} ==',
    );
    final backend = _requireSelectedBackend();
    _activeBackend = backend;
    try {
      return await backend.runProtection(request, callbacks);
    } finally {
      if (identical(_activeBackend, backend)) _activeBackend = null;
    }
  }

  @override
  bool sendContinue({required bool protection}) =>
      (_activeBackend ?? _selectedBackend)?.sendContinue(
        protection: protection,
      ) ??
      false;

  @override
  void cancel() => (_activeBackend ?? _selectedBackend)?.cancel();

  HardwareBackend _requireSelectedBackend() {
    final backend = _selectedBackend;
    if (backend != null) return backend;
    throw StateError(selectedUnavailableReason ?? '$name is unavailable.');
  }
}
