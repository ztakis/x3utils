// Destructive diagnostic test for an explicitly sacrificial AT32F415CBT7.
// It captures the board's full flash before the first erase, then performs
// fresh-session erase/program/verify cycles followed by independent full-flash
// readbacks while the target remains halted. It stops on the first failure,
// never retries after erase, and leaves the target halted for a power cycle.
//
// Use the guarded launcher from the package root:
//   dart run tool/swdart_loader_stress.dart \
//     --confirm-sacrificial --cycles 20
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/swd/swd.dart';

const _confirmed = bool.fromEnvironment('X3UTILS_LOADER_STRESS_CONFIRMED');
const _cycles = int.fromEnvironment('X3UTILS_LOADER_STRESS_CYCLES');
const _outputOption = String.fromEnvironment('X3UTILS_LOADER_STRESS_OUT');
const _expectedIdcode = 0x700301c5;
const _expectedFlashBytes = 128 * 1024;

class _Transcript {
  _Transcript(File file) : _sink = file.openWrite();

  final IOSink _sink;

  void log(String line) {
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
      'refusing destructive test on ${target.name}: expected the tested '
      'AT32F415CBT7, IDCODE 0x${_expectedIdcode.toRadixString(16)}, '
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
        : 'build${Platform.pathSeparator}loader_stress${Platform.pathSeparator}'
              '${_timestampForPath()}',
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
    'requestedCycles': _cycles,
    'completedCycles': 0,
    'result': 'running',
    'outputDirectory': output.absolute.path,
    'cycles': <Map<String, Object?>>[],
  };

  transcript.log('== swdart SRAM-loader destructive stress test ==');
  transcript.log('output=${output.absolute.path}');
  transcript.log('requested cycles=$_cycles; stop on first failure');
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
      final programWatch = Stopwatch()..start();
      await _programCycle(cycle, golden, transcript);
      programWatch.stop();
      cycleResult['programMs'] = programWatch.elapsedMilliseconds;
      await transcript.flush();

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
        'readback=${readWatch.elapsedMilliseconds} ms, sha256=$readbackHash',
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
    summary['finished'] = DateTime.now().toIso8601String();
    summary['elapsedMs'] = DateTime.now().difference(started).inMilliseconds;
    await _writeSummary(summaryFile, summary);
    await transcript.close();
  }
  if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
}

void main() {
  test(
    'sacrificial AT32 SRAM-loader stress',
    _runStress,
    skip: _confirmed && _cycles > 0
        ? false
        : 'requires the guarded swdart_loader_stress.dart launcher',
    timeout: Timeout.none,
  );
}
