import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/hardware_backend.dart';
import 'package:x3utils_flutter/main.dart';
import 'package:x3utils_flutter/models.dart';

// Synthetic firmware: fake backends only, never a hardware input.
Uint8List _image({bool identified = true}) {
  final bytes = Uint8List.fromList(List.generate(131072, (i) => i % 251));
  bytes.setRange(
    kSlotBannerOffset,
    kSlotBannerOffset + kBannerLength,
    'SCOOTER_VCU_xxG3'.codeUnits,
  );
  if (identified) bytes.setRange(0x3000, 0x3004, [0x40, 0xf2, 0x55, 0x10]);
  return bytes;
}

const _success = HardwareResult(
  0,
  HardwareEvidence(
    caught: true,
    erased: true,
    wrote: true,
    verified: true,
    resetRunning: true,
  ),
);

class _Backend implements HardwareBackend {
  Uint8List original = _image();
  HardwareResult outcome = const HardwareResult(
    1,
    HardwareEvidence(caught: true),
  );
  Object? failure;
  Completer<HardwareResult>? pending;
  final flashStarted = Completer<void>();
  HardwareCallbacks? flashCallbacks;
  final requests = <HardwareRequest>[];
  bool dumpFails = false;

  @override
  String get name => 'swdart';
  @override
  HardwareCapabilities get capabilities => const HardwareCapabilities(
    connectionModes: {ConnectionMode.defaultSwd},
    check: true,
    dump: true,
    flashFull: true,
    flashSlot0: true,
    protectionCheck: false,
    protectionRescue: false,
  );
  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) async {
    requests.add(request);
    if (request.operation == HardwareOperation.dump) {
      if (dumpFails) return const HardwareResult(1, HardwareEvidence());
      callbacks.onProgress(const HardwareProgress(connected: true));
      return HardwareResult(
        0,
        const HardwareEvidence(caught: true, dumped: true),
        bytes: Uint8List.fromList(original),
      );
    }
    if (request.operation == HardwareOperation.check) {
      return const HardwareResult(0, HardwareEvidence(caught: true));
    }
    flashCallbacks = callbacks;
    if (!flashStarted.isCompleted) flashStarted.complete();
    if (failure != null) throw failure!;
    callbacks.onLine('[flash] failed: simulated interrupted flash');
    return pending == null ? outcome : pending!.future;
  }

  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) => throw UnsupportedError('not used');
  @override
  bool sendContinue({required bool protection}) => false;
  @override
  void cancel() {} // Deliberately allow late completion to test generation guards.
}

Future<AppController> _controller(
  _Backend backend,
  Directory root, {
  String platform = 'desktop',
}) async {
  SharedPreferences.setMockInitialValues({
    'defaultAutoRetry': 0,
    'logToFile': false,
  });
  final c = AppController(
    backend: backend,
    browserMode: platform == 'web',
    androidMode: platform == 'android',
    backupDownloader: (_, _) async {},
    androidBackupPublisher: (_, name) async => name,
  );
  await Future<void>.delayed(Duration.zero);
  c.setX3utilsRoot(root.path);
  c.setSecondCopy(false);
  c.selectAction('flash_compat');
  return c;
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('compat_recovery_'));
  tearDown(() {
    Firmware.setRoot(null);
    root.deleteSync(recursive: true);
  });

  for (final platform in ['desktop', 'web', 'android']) {
    for (final evidence in [
      const HardwareEvidence(
        caught: true,
      ), // Interrupted erase, no completion marker.
      const HardwareEvidence(
        caught: true,
        erased: true,
      ), // Partial programming.
      const HardwareEvidence(
        caught: true,
        erased: true,
        wrote: true,
      ), // Verify failed.
    ]) {
      test(
        '$platform interrupted flash preserves original and Retry only prepares recovery: '
        '${evidence.erased}/${evidence.wrote}',
        () async {
          final backend = _Backend()..outcome = HardwareResult(1, evidence);
          final c = await _controller(backend, root, platform: platform);
          addTearDown(c.dispose);
          c.setDefaultAutoRetry(1);
          await c.start();
          expect(c.compatRecoveryPending, isTrue);
          expect(c.showingCompatRecovery, isTrue);
          expect(c.autoRetryArmed, isFalse);
          expect(c.sub, contains('Restore a known-good full image'));
          expect(c.sub, isNot(contains('press Retry')));
          // The raw failure detail stays OUT of the hero — it overflowed the
          // phone card — but must still be reachable in the console.
          expect(c.sub, isNot(contains('simulated interrupted flash')));
          expect(c.console.join('\n'), contains('simulated interrupted flash'));
          final originalPath = c.resultPath;
          final originalCount = backend.requests.length;
          await c.retry(auto: true);
          expect(backend.requests, hasLength(originalCount));
          await c.retry();
          expect(c.actionId, 'flash_only');
          expect(c.flashScope, FlashScope.fullImage);
          expect(backend.requests, hasLength(originalCount));
          expect(
            platform == 'desktop'
                ? File(c.firmwarePath!).readAsBytesSync()
                : c.firmwareBytes,
            backend.original,
          );
          c.dismiss();
          c.selectAction('check');
          await c.start();
          expect(c.compatRecoveryPending, isTrue);
          c.selectAction('flash_compat');
          await c.start();
          expect(c.resultPath, originalPath);
          expect(
            backend.requests.where(
              (r) => r.operation == HardwareOperation.dump,
            ),
            hasLength(1),
          );
          await c.retry();
          backend.outcome = _success;
          await c.start();
          expect(c.stage, StageState.ok);
          expect(c.compatRecoveryPending, isFalse);
        },
      );
    }

    test(
      '$platform unidentified firmware cannot reach patch or flash',
      () async {
        final backend = _Backend()..original = _image(identified: false);
        final c = await _controller(backend, root, platform: platform);
        addTearDown(c.dispose);
        await c.start();
        expect(c.stage, StageState.fail);
        expect(
          c.sub,
          contains('requires an identified, supported firmware version'),
        );
        expect(c.compatRecoveryPending, isFalse);
        expect(backend.requests, hasLength(1));
      },
    );
  }

  test(
    'thrown USB disconnect enters recovery despite missing result evidence',
    () async {
      final backend = _Backend()
        ..failure = const HardwareException(
          HardwareFailureKind.deviceDisconnected,
          'unplugged',
        );
      final c = await _controller(backend, root);
      addTearDown(c.dispose);
      await c.start();
      expect(c.showingCompatRecovery, isTrue);
      expect(c.resultPath, isNotNull);
      expect(c.sub, isNot(contains('press Retry')));
      expect(c.autoRetryArmed, isFalse);
    },
  );

  test('contradictory ROM versions refuse without an override', () async {
    final backend = _Backend()..original = _image(identified: false);
    backend.original.setRange(
      kSlotBannerOffset,
      kSlotBannerOffset + kBannerLength,
      'SCOOTER_VCU_xxU2'.codeUnits,
    );
    backend.original.setRange(0x3000, 0x3004, [0x40, 0xf2, 0x4b, 0x10]);
    backend.original.setRange(0x3100, 0x3104, [0x40, 0xf2, 0x52, 0x10]);
    final c = await _controller(backend, root, platform: 'web');
    addTearDown(c.dispose);
    await c.start();
    expect(
      c.sub,
      contains('requires an identified, supported firmware version'),
    );
    expect(backend.requests, hasLength(1));
    expect(c.compatRecoveryPending, isFalse);
  });

  test('verified bytes with failed reset have a distinct outcome', () async {
    final backend = _Backend()
      ..outcome = const HardwareResult(
        1,
        HardwareEvidence(
          caught: true,
          erased: true,
          wrote: true,
          verified: true,
        ),
      );
    final c = await _controller(backend, root);
    addTearDown(c.dispose);
    await c.start();
    expect(c.title, 'Image verified; reset unconfirmed');
    expect(c.sub, isNot(contains('incomplete firmware')));
  });

  test(
    'cancelled flash ignores late success and late error messages',
    () async {
      final backend = _Backend()..pending = Completer<HardwareResult>();
      final c = await _controller(backend, root);
      addTearDown(c.dispose);
      final run = c.start();
      await backend.flashStarted.future;
      c.cancel();
      final message = c.sub;
      final originalPath = c.resultPath;
      backend.flashCallbacks!.onLine('[fail] late stale error');
      backend.pending!.complete(_success);
      await run;
      expect(c.showingCompatRecovery, isTrue);
      expect(c.sub, message);
      expect(c.resultPath, originalPath);
      expect(c.compatRecoveryPending, isTrue);
    },
  );

  test('cancel during patch pacing never dispatches flash', () async {
    final backend = _Backend();
    final c = await _controller(backend, root);
    addTearDown(c.dispose);
    void listener() {
      if (c.sub == 'SHU patch applied. Ready to flash...') {
        c.removeListener(listener);
        c.cancel();
      }
    }

    c.addListener(listener);
    await c.start();
    c.removeListener(listener);
    expect(backend.requests, hasLength(1));
    expect(c.compatRecoveryPending, isFalse);
    expect(c.stage, StageState.idle);
  });

  test('changed original backup is refused when preparing recovery', () async {
    final backend = _Backend();
    final c = await _controller(backend, root);
    addTearDown(c.dispose);
    await c.start();
    final changed = Uint8List.fromList(backend.original)..[0x1800] ^= 1;
    File(c.resultPath!).writeAsBytesSync(changed);
    await c.retry();
    expect(c.actionId, 'flash_only');
    expect(c.firmwarePath, isNull);
    expect(c.sub, contains('changed since capture'));
    expect(c.compatRecoveryPending, isTrue);
    expect(backend.requests, hasLength(2));
  });

  test(
    'connection failure before the Compat flash stage remains retryable',
    () async {
      final backend = _Backend()..dumpFails = true;
      final c = await _controller(backend, root);
      addTearDown(c.dispose);
      c.setDefaultAutoRetry(1);
      await c.start();
      expect(c.autoRetryArmed, isTrue);
      expect(c.compatRecoveryPending, isFalse);
      expect(c.failurePrimaryLabel, 'Retry');
      c.setDefaultAutoRetry(0);
      backend.dumpFails = false;
      backend.outcome = _success;
      await c.retry();
      expect(c.stage, StageState.ok);
    },
  );

  test(
    'Backup, Backup + Flash, and slot-0 Flash Only preserve the original recovery record',
    () async {
      final backend = _Backend();
      final c = await _controller(backend, root);
      addTearDown(c.dispose);
      await c.start();
      final originalPath = c.resultPath!;
      c.selectAction('dump');
      await c.start();
      expect(c.stage, StageState.ok);
      expect(c.compatRecoveryPending, isTrue);
      backend.outcome = _success;
      c.selectAction('flash_backup');
      expect(c.selectFirmwareBin(originalPath).ok, isTrue);
      await c.start();
      expect(c.stage, StageState.ok);
      expect(c.compatRecoveryPending, isTrue);
      c.selectAction('flash_only');
      c.setFlashScope(FlashScope.slot0);
      final slot = File('${root.path}/slot.bin')
        ..writeAsBytesSync(backend.original.sublist(0x1000, 0xf000));
      expect(c.selectFirmwareBin(slot.path).ok, isTrue);
      await c.start();
      expect(c.stage, StageState.ok);
      expect(c.compatRecoveryPending, isTrue);
      c.selectAction('flash_compat');
      final calls = backend.requests.length;
      await c.start();
      expect(backend.requests, hasLength(calls));
      expect(c.resultPath, originalPath);
    },
  );

  test(
    'changed patched file aborts before dispatch while the original stays intact',
    () async {
      final backend = _Backend();
      final c = await _controller(backend, root);
      addTearDown(c.dispose);
      void listener() {
        if (c.sub != 'SHU patch applied. Ready to flash...') return;
        c.removeListener(listener);
        final patched = Directory('${root.path}/compat')
            .listSync()
            .whereType<File>()
            .singleWhere((f) => f.path.endsWith('_patched.bin'));
        final bytes = patched.readAsBytesSync()..[0x1f020] ^= 1;
        patched.writeAsBytesSync(bytes);
      }

      c.addListener(listener);
      await c.start();
      c.removeListener(listener);
      expect(c.stage, StageState.fail);
      expect(c.sub, contains('outside its field'));
      expect(backend.requests, hasLength(1));
      expect(c.compatRecoveryPending, isFalse);
      expect(File(c.resultPath!).readAsBytesSync(), backend.original);
    },
  );

  test('cancelled MCU model dialog cannot resume Compat', () async {
    final backend = _Backend();
    backend.original.setRange(
      kSlotBannerOffset,
      kSlotBannerOffset + kBannerLength,
      'SCOOTER_MCU_0001'.codeUnits,
    );
    final c = await _controller(backend, root);
    addTearDown(c.dispose);
    final asked = Completer<void>();
    final answer = Completer<String?>();
    final run = c.start(
      askMcuModel: (_) {
        asked.complete();
        return answer.future;
      },
    );
    await asked.future;
    c.cancel();
    answer.complete('g3');
    await run;
    expect(c.stage, StageState.idle);
    expect(backend.requests, hasLength(1));
    expect(c.compatRecoveryPending, isFalse);
  });

  test('a failed recovery does not clear the Compat hold', () async {
    final c = await _controller(_Backend(), root);
    addTearDown(c.dispose);
    await c.start();
    await c.retry();
    await c.start();
    expect(c.compatRecoveryPending, isTrue);
  });

  test('recovery rechecks the selected file at Start', () async {
    final backend = _Backend();
    final c = await _controller(backend, root);
    addTearDown(c.dispose);
    await c.start();
    await c.retry();
    final changed = File(c.firmwarePath!).readAsBytesSync()..[0x1800] ^= 1;
    File(c.firmwarePath!).writeAsBytesSync(changed);
    await c.start();
    expect(c.stage, StageState.fail);
    expect(c.sub, contains('recovery image changed'));
    expect(backend.requests, hasLength(2));
    expect(c.compatRecoveryPending, isTrue);
  });

  test(
    'patch comparison accepts only the intended field including an already-patched image',
    () {
      final original = _image();
      final (_, patched) = CompatPatch.applyBytes(original);
      expect(CompatPatch.validateChange(original, patched!).ok, isTrue);
      expect(CompatPatch.validateChange(patched, patched).ok, isTrue);
      for (final offset in [0, 0x141f, 0x1430, 0x1f020, 131071]) {
        final changed = Uint8List.fromList(patched)..[offset] ^= 1;
        expect(CompatPatch.validateChange(original, changed).ok, isFalse);
      }
      expect(
        CompatPatch.validateChange(original, patched.sublist(1)).ok,
        isFalse,
      );
      expect(CompatPatch.validateChange(original, original).ok, isFalse);
    },
  );

  testWidgets(
    'recovery UI and Enter prepare Flash Only without starting another run',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _Backend();
      late AppController c;
      await tester.runAsync(() async {
        c = await _controller(backend, root);
        await c.start();
      });
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
      await tester.pump();
      expect(find.text('Open recovery setup'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Patch anyway'), findsNothing);
      expect(
        find.text('Backup saved before this flash attempt'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.actionId, 'flash_only');
      expect(backend.requests, hasLength(2));
      expect(c.compatRecoveryPending, isTrue);
      c.selectAction('flash_compat');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.showingCompatRecovery, isTrue);
      expect(backend.requests, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
