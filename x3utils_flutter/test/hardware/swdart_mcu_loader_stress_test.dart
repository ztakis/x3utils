// Destructive diagnostic test for an explicitly sacrificial AT32F415RBT7 MCU.
//
// The sibling CBT7 test exercises the loader on a VCU. This one targets the MCU
// deliberately, because the MCU is the board where the DMA-corruption bug was
// real: its firmware runs an ADC ring buffer at 0x20000FA8, inside the loader's
// staging window at 0x20000800. The VCU has active DMA too, but its buffers sit
// outside that window, so a regression in the reset catch is INVISIBLE there and
// visible here. That is the whole reason this file exists.
//
// What it proves, per cycle:
//   1. the reset catch held        — baseline VTOR must read 0x00000000
//   2. no bus master was left live — no DMA channels stopped at staging
//   3. no staged chunk was touched — no staging-corruption restage
//   4. flash matches the golden    — independent fresh-session readback
//   5. the loader did the writing  — all 16 chunks completed, no direct fallback
//
// (1) is the invariant the fix rests on: the core is caught at the reset vector,
// so the firmware never runs and never configures DMA. (2) and (3) are the
// fallbacks; on a healthy build they must never fire, so if they do, the reset
// catch has regressed and this test says so before (4) has to catch it the hard
// way.
//
// NB the hazard cannot be armed through the public API — Probe.program() always
// resets and catches the core first, so the firmware cannot be running by the
// time a chunk is staged. Proving the fallbacks themselves still needs the
// manual fault injection described in the .agent write-up. This test proves the
// production path stays correct on the board that would show it failing.
//
// Use the guarded launcher from the package root:
//   dart run tool/swdart_mcu_stress.dart \
//     --confirm-sacrificial --cycles 100
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/swd/swd.dart';

const _confirmed = bool.fromEnvironment('X3UTILS_MCU_STRESS_CONFIRMED');
const _cycles = int.fromEnvironment('X3UTILS_MCU_STRESS_CYCLES');
const _outputOption = String.fromEnvironment('X3UTILS_MCU_STRESS_OUT');
const _expectedIdcode = 0x700301c4; // AT32F415RBT7
const _expectedFlashBytes = 128 * 1024;
// Mirrors At32Flash.loaderBufferSize, which caps the staging buffer at 0x2000.
// Deliberately asserted rather than derived: a silent change to the chunk size
// changes what "all chunks completed" means. If that cap moves — e.g. to 16 KiB
// to cut Android's round trips — update this and the count follows.
const _loaderChunkBytes = 8 * 1024;
const _expectedLoaderChunks = _expectedFlashBytes ~/ _loaderChunkBytes;

/// Log shapes the cycle watcher keys on. Kept beside each other so a change to
/// the engine's wording is a one-place fix and an obviously breaking one.
final _reVtor = RegExp(r'baseline VTOR=0x([0-9A-Fa-f]{8})');
final _reDmaStopped = RegExp(r'stopped (\d+) active DMA channel');
final _reLoaderChunkCompleted = RegExp(
  r'\[flash:loader\] chunk (\d+)/(\d+) complete '
  r'dst=0x([0-9A-Fa-f]{8}), bytes=(\d+),',
);
const _stagingCorrupted = 'staging corrupted';
const _directWriteFallback = 'using direct word writes';

/// Per-cycle evidence scraped from the engine's own diagnostic lines.
///
/// Reading the transcript rather than poking registers keeps the test to the
/// public API, and it fails loudly if the diagnostics ever stop being emitted:
/// a missing VTOR is treated as a failure, not as a pass by default.
class _CycleSignals {
  int? vtor;
  int dmaChannelsStopped = 0;
  int stagingCorruptions = 0;
  int loaderChunksCompleted = 0;
  bool directWriteFallback = false;
  String? loaderChunkProblem;
  final findings = <String>[];

  void observe(String line) {
    final vtorMatch = _reVtor.firstMatch(line);
    if (vtorMatch != null) {
      vtor = int.parse(vtorMatch.group(1)!, radix: 16);
    }
    final dmaMatch = _reDmaStopped.firstMatch(line);
    if (dmaMatch != null) {
      dmaChannelsStopped += int.parse(dmaMatch.group(1)!);
      findings.add(line);
    }
    if (line.contains(_stagingCorrupted)) {
      stagingCorruptions++;
      findings.add(line);
    }
    if (line.contains(_directWriteFallback)) {
      directWriteFallback = true;
      findings.add(line);
    }
    final chunkMatch = _reLoaderChunkCompleted.firstMatch(line);
    if (chunkMatch != null) {
      final index = int.parse(chunkMatch.group(1)!);
      final total = int.parse(chunkMatch.group(2)!);
      final destination = int.parse(chunkMatch.group(3)!, radix: 16);
      final bytes = int.parse(chunkMatch.group(4)!);
      final expectedIndex = loaderChunksCompleted + 1;
      final expectedDestination =
          0x08000000 + loaderChunksCompleted * _loaderChunkBytes;
      if (index != expectedIndex ||
          total != _expectedLoaderChunks ||
          destination != expectedDestination ||
          bytes != _loaderChunkBytes) {
        loaderChunkProblem ??=
            'unexpected loader chunk completion; expected chunk '
            '$expectedIndex/$_expectedLoaderChunks at '
            '0x${expectedDestination.toRadixString(16).padLeft(8, '0')} '
            'with $_loaderChunkBytes bytes: $line';
        findings.add(line);
      }
      loaderChunksCompleted++;
    }
  }

  /// Null when the cycle is clean, otherwise why it is not.
  String? get problem {
    if (directWriteFallback) {
      return 'direct word-write fallback was used; this cycle does not '
          'validate SRAM-loader programming';
    }
    if (vtor == null) {
      return 'no "baseline VTOR=" line was emitted — loader diagnostics are '
          'off, or the programming path changed; the reset catch could not be '
          'checked';
    }
    if (vtor != 0) {
      return 'reset catch did NOT hold: baseline VTOR=0x'
          '${vtor!.toRadixString(16).padLeft(8, '0')} means firmware ran before '
          'the halt and had time to configure DMA';
    }
    if (dmaChannelsStopped != 0) {
      return '$dmaChannelsStopped DMA channel(s) were live at staging; with '
          'the core caught at the reset vector there should be none';
    }
    if (stagingCorruptions != 0) {
      return '$stagingCorruptions staged chunk(s) came back corrupted; '
          'something wrote SRAM while the core was halted';
    }
    if (loaderChunkProblem != null) return loaderChunkProblem;
    if (loaderChunksCompleted != _expectedLoaderChunks) {
      return 'observed $loaderChunksCompleted/$_expectedLoaderChunks loader '
          'chunk completions; all $_expectedLoaderChunks chunks must complete';
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'vtor': vtor == null
        ? null
        : '0x${vtor!.toRadixString(16).padLeft(8, '0')}',
    'dmaChannelsStopped': dmaChannelsStopped,
    'stagingCorruptions': stagingCorruptions,
    'loaderChunksCompleted': loaderChunksCompleted,
    'expectedLoaderChunks': _expectedLoaderChunks,
    'directWriteFallback': directWriteFallback,
    if (loaderChunkProblem != null) 'loaderChunkProblem': loaderChunkProblem,
    if (findings.isNotEmpty) 'findings': findings,
  };
}

class _Transcript {
  _Transcript(File file) : _sink = file.openWrite();

  final IOSink _sink;

  /// Set for the duration of a cycle so engine lines are scraped as they are
  /// logged; null between cycles, when nothing is being measured.
  _CycleSignals? watching;

  void log(String line) {
    watching?.observe(line);
    final stamped = '${DateTime.now().toIso8601String()} $line';
    // Keep live hardware progress visible in flutter test output.
    // ignore: avoid_print
    print(stamped);
    _sink.writeln(stamped);
  }

  Future<void> flush() => _sink.flush();
  Future<void> close() => _sink.close();
}

String _timestampForPath() =>
    DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

int _u32le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

void _validateTarget(TargetInfo target) {
  if (target.family != 'AT32' ||
      target.idcode != _expectedIdcode ||
      target.flashKB * 1024 != _expectedFlashBytes ||
      target.flashBase != 0x08000000 ||
      !target.tested) {
    throw SwdException(
      'refusing destructive test on ${target.name}: expected the MCU '
      'AT32F415RBT7, IDCODE 0x${_expectedIdcode.toRadixString(16)}, '
      '$_expectedFlashBytes bytes',
    );
  }
}

void _validateGolden(Uint8List bytes) {
  if (bytes.length != _expectedFlashBytes) {
    throw SwdException(
      'golden capture has ${bytes.length} bytes, expected '
      '$_expectedFlashBytes',
    );
  }
  if (bytes.every((byte) => byte == 0xff) ||
      bytes.every((byte) => byte == 0x00)) {
    throw SwdException('golden capture is uniformly blank or masked');
  }
  final initialSp = _u32le(bytes, 0);
  final resetVector = _u32le(bytes, 4);
  final stackIsSram = initialSp >= 0x20000000 && initialSp <= 0x20008000;
  final resetIsFlash = resetVector >= 0x08000001 && resetVector < 0x08020000;
  if (!stackIsSram || !resetIsFlash || resetVector.isEven) {
    throw SwdException(
      'golden vector table is not plausible: '
      'SP=0x${initialSp.toRadixString(16)}, '
      'reset=0x${resetVector.toRadixString(16)}',
    );
  }
}

Probe _newProbe(_Transcript transcript, String session) {
  final probe = Probe(useAt32Loader: true, loaderDiagnostics: true);
  probe.onLog((line) => transcript.log('[$session] $line'));
  return probe;
}

Future<Uint8List> _captureGolden(_Transcript transcript) async {
  final probe = _newProbe(transcript, 'capture');
  try {
    final target = await probe.connect(ConnectMode.normal);
    _validateTarget(target);
    final bytes = await probe.readFlash(
      address: target.flashBase,
      length: _expectedFlashBytes,
    );
    _validateGolden(bytes);
    return bytes;
  } finally {
    await probe.disconnect();
  }
}

Future<void> _programCycle(
  int cycle,
  Uint8List golden,
  _Transcript transcript,
) async {
  final probe = _newProbe(transcript, 'cycle-$cycle-program');
  try {
    final target = await probe.connect(ConnectMode.normal);
    _validateTarget(target);
    await probe.program(
      target.flashBase,
      golden,
      onStage: (stage) => transcript.log('[cycle $cycle] stage=$stage'),
    );
  } finally {
    // Keep the target halted so application-owned flash cannot change before
    // the fresh-session readback. Never retry or attempt recovery here.
    await probe.disconnect();
  }
}

Future<Uint8List> _readbackCycle(int cycle, _Transcript transcript) async {
  final probe = _newProbe(transcript, 'cycle-$cycle-readback');
  try {
    final target = await probe.connect(ConnectMode.normal);
    _validateTarget(target);
    return await probe.readFlash(
      address: target.flashBase,
      length: _expectedFlashBytes,
    );
  } finally {
    await probe.disconnect();
  }
}

class _DifferenceSummary {
  const _DifferenceSummary({
    required this.count,
    required this.first,
    required this.last,
  });

  final int count;
  final int first;
  final int last;
}

_DifferenceSummary? _differences(Uint8List expected, Uint8List actual) {
  final common = expected.length < actual.length
      ? expected.length
      : actual.length;
  var count = 0;
  int? first;
  int? last;
  for (var i = 0; i < common; i++) {
    if (expected[i] != actual[i]) {
      first ??= i;
      last = i;
      count++;
    }
  }
  if (expected.length != actual.length) {
    first ??= common;
    last =
        (expected.length > actual.length ? expected.length : actual.length) - 1;
    count += (expected.length - actual.length).abs();
  }
  return first == null
      ? null
      : _DifferenceSummary(count: count, first: first, last: last!);
}

Future<void> _writeSummary(File file, Map<String, Object?> summary) =>
    file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
      flush: true,
    );

Future<void> _runStress() async {
  final output = Directory(
    _outputOption.isNotEmpty
        ? _outputOption
        : 'build${Platform.pathSeparator}mcu_loader_stress'
              '${Platform.pathSeparator}${_timestampForPath()}',
  );
  await output.create(recursive: true);
  final transcript = _Transcript(
    File('${output.path}${Platform.pathSeparator}transcript.log'),
  );
  final summaryFile = File(
    '${output.path}${Platform.pathSeparator}summary.json',
  );
  final started = DateTime.now();
  final summary = <String, Object?>{
    'started': started.toIso8601String(),
    'target': 'AT32F415RBT7 (MCU)',
    'requestedCycles': _cycles,
    'completedCycles': 0,
    'result': 'running',
    'outputDirectory': output.absolute.path,
    'cycles': <Map<String, Object?>>[],
  };

  transcript.log('== swdart SRAM-loader destructive stress test (MCU) ==');
  transcript.log('output=${output.absolute.path}');
  transcript.log('requested cycles=$_cycles; stop on first failure');
  transcript.log(
    'per cycle: VTOR must be 0x00000000, no DMA stops, no staging corruption, '
    'all $_expectedLoaderChunks loader chunks must complete with no direct '
    'fallback, readback must match golden',
  );
  transcript.log(
    'target remains halted between program and readback; power-cycle it after '
    'the test',
  );

  Object? failure;
  StackTrace? failureStack;
  try {
    transcript.log('capturing full flash before any destructive action');
    final golden = await _captureGolden(transcript);
    final goldenHash = _hash(golden);
    final goldenFile = File(
      '${output.path}${Platform.pathSeparator}golden_128k.bin',
    );
    await goldenFile.writeAsBytes(golden, flush: true);
    summary['goldenSha256'] = goldenHash;
    summary['goldenBytes'] = golden.length;
    await _writeSummary(summaryFile, summary);
    await transcript.flush();
    transcript.log('golden saved; sha256=$goldenHash');

    final cycleResults = summary['cycles']! as List<Map<String, Object?>>;
    for (var cycle = 1; cycle <= _cycles; cycle++) {
      final cycleResult = <String, Object?>{'cycle': cycle};
      cycleResults.add(cycleResult);
      transcript.log('== cycle $cycle/$_cycles: program ==');

      // Scrape only the programming session: the readback session does not
      // stage anything, so its lines would say nothing about the defences.
      final signals = _CycleSignals();
      transcript.watching = signals;
      final programWatch = Stopwatch()..start();
      try {
        await _programCycle(cycle, golden, transcript);
      } finally {
        programWatch.stop();
        transcript.watching = null;
      }
      cycleResult['programMs'] = programWatch.elapsedMilliseconds;
      cycleResult['signals'] = signals.toJson();
      await transcript.flush();

      // Checked before the readback: these say WHY a cycle is about to fail,
      // and on a healthy build they catch a regression even in the cycles
      // where the corruption happens to miss anything that matters.
      final problem = signals.problem;
      if (problem != null) {
        cycleResult['result'] = 'fail';
        cycleResult['failure'] = problem;
        transcript.log('cycle $cycle DEFENCE FAILURE: $problem');
        throw SwdException('cycle $cycle: $problem');
      }

      transcript.log('== cycle $cycle/$_cycles: fresh halted readback ==');
      final readWatch = Stopwatch()..start();
      final readback = await _readbackCycle(cycle, transcript);
      readWatch.stop();
      final readbackHash = _hash(readback);
      final differences = _differences(golden, readback);
      cycleResult['readbackMs'] = readWatch.elapsedMilliseconds;
      cycleResult['readbackSha256'] = readbackHash;
      if (differences != null) {
        final failedReadbackFile = File(
          '${output.path}${Platform.pathSeparator}'
          'cycle_${cycle.toString().padLeft(3, '0')}_failed_readback.bin',
        );
        await failedReadbackFile.writeAsBytes(readback, flush: true);
        cycleResult['result'] = 'fail';
        cycleResult['differenceCount'] = differences.count;
        cycleResult['firstDifferenceOffset'] = differences.first;
        cycleResult['lastDifferenceOffset'] = differences.last;
        cycleResult['failedReadbackFile'] = failedReadbackFile.absolute.path;
        transcript.log(
          'cycle $cycle mismatch evidence saved to '
          '${failedReadbackFile.absolute.path}; differences=${differences.count}, '
          'first=0x${differences.first.toRadixString(16)}, '
          'last=0x${differences.last.toRadixString(16)}',
        );
        throw SwdException(
          'cycle $cycle independent readback differs at '
          '0x${differences.first.toRadixString(16)} '
          '(${differences.count} differing bytes, last at '
          '0x${differences.last.toRadixString(16)}); '
          'expected sha256=$goldenHash, actual sha256=$readbackHash',
        );
      }
      cycleResult['result'] = 'pass';
      summary['completedCycles'] = cycle;
      transcript.log(
        'cycle $cycle PASS; program=${programWatch.elapsedMilliseconds} ms, '
        'readback=${readWatch.elapsedMilliseconds} ms, VTOR=0x00000000, '
        'loader chunks=${signals.loaderChunksCompleted}/$_expectedLoaderChunks, '
        'sha256=$readbackHash',
      );
      await _writeSummary(summaryFile, summary);
      await transcript.flush();
    }

    summary['result'] = 'pass';
    transcript.log('PASS: completed all $_cycles cycles');
    transcript.log('Target is halted; power-cycle it before normal use.');
  } catch (error, stackTrace) {
    failure = error;
    failureStack = stackTrace;
    summary['result'] = 'fail';
    summary['failure'] = '$error';
    summary['stackTrace'] = '$stackTrace';
    transcript.log('FAIL: $error');
    transcript.log('No retry or recovery was attempted.');
    transcript.log(
      'Preserve the output directory; unplug/replug ST-Link and power-cycle '
      'the sacrificial target before manual recovery.',
    );
  } finally {
    transcript.watching = null;
    summary['finished'] = DateTime.now().toIso8601String();
    summary['elapsedMs'] = DateTime.now().difference(started).inMilliseconds;
    await _writeSummary(summaryFile, summary);
    await transcript.close();
  }
  if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
}

void main() {
  group('MCU cycle signals', () {
    String chunkLine(
      int index, {
      int total = 16,
      int? destination,
      int bytes = 8192,
    }) {
      final address = destination ?? 0x08000000 + (index - 1) * 8192;
      return '[cycle-1-program] [flash:loader] chunk $index/$total complete '
          'dst=0x${address.toRadixString(16).padLeft(8, '0')}, bytes=$bytes, '
          'chunk=200 ms, elapsed=400 ms';
    }

    _CycleSignals cleanSignals({int chunks = 16}) {
      final signals = _CycleSignals()
        ..observe('[flash:loader] baseline VTOR=0x00000000, CRM_CTRLSTS=0');
      for (var index = 1; index <= chunks; index++) {
        signals.observe(chunkLine(index));
      }
      return signals;
    }

    test('accepts all 16 complete loader chunks', () {
      final signals = cleanSignals();
      expect(signals.problem, isNull);
      expect(signals.toJson()['loaderChunksCompleted'], 16);
      expect(signals.toJson()['directWriteFallback'], isFalse);
    });

    test('rejects missing or incomplete loader execution', () {
      for (final count in [0, 15, 17]) {
        final signals = cleanSignals(chunks: count);
        expect(signals.problem, contains('$count/16'));
      }
    });

    test('rejects direct fallback even with complete chunk evidence', () {
      final signals = _CycleSignals()
        ..observe(
          '[flash] SRAM loader preflight failed before erase; '
          'using direct word writes: preflight timeout',
        )
        ..observe('[flash:loader] baseline VTOR=0x00000000');
      for (var index = 1; index <= 16; index++) {
        signals.observe(chunkLine(index));
      }
      expect(signals.problem, contains('direct word-write fallback'));
      expect(signals.toJson()['directWriteFallback'], isTrue);
    });

    test('rejects a duplicate instead of the last chunk', () {
      final signals = cleanSignals(chunks: 15)..observe(chunkLine(15));
      expect(signals.loaderChunksCompleted, 16);
      expect(signals.problem, contains('unexpected loader chunk completion'));
    });

    test('rejects incorrect totals, addresses, or byte counts', () {
      for (final invalid in [
        chunkLine(16, total: 17),
        chunkLine(16, destination: 0x08000000),
        chunkLine(16, bytes: 4096),
      ]) {
        final signals = cleanSignals(chunks: 15)..observe(invalid);
        expect(signals.problem, contains('unexpected loader chunk completion'));
      }
    });

    test('chunk starts cannot substitute for completion', () {
      final signals = cleanSignals(chunks: 0);
      for (var index = 1; index <= 16; index++) {
        signals.observe(chunkLine(index).replaceFirst(' complete ', ' start '));
      }
      expect(signals.problem, contains('0/16'));
    });

    test('complete loader evidence preserves the existing failure checks', () {
      expect((cleanSignals()..vtor = null).problem, contains('no "baseline'));
      expect((cleanSignals()..vtor = 0x1000).problem, contains('reset catch'));
      expect(
        (cleanSignals()..observe('[flash] stopped 1 active DMA channel(s)'))
            .problem,
        contains('1 DMA channel(s)'),
      );
      expect(
        (cleanSignals()
              ..observe('[flash:loader] staging corrupted — restaging'))
            .problem,
        contains('1 staged chunk(s)'),
      );
    });
  });

  test(
    'sacrificial AT32 MCU SRAM-loader stress',
    _runStress,
    skip: _confirmed && _cycles > 0
        ? false
        : 'requires the guarded swdart_mcu_stress.dart launcher',
    timeout: Timeout.none,
  );
}
