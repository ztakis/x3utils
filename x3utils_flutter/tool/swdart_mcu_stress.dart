// ignore_for_file: avoid_print
//
// Guarded launcher for the destructive MCU SRAM-loader hardware test. The
// actual test runs under flutter_tester because the shared transport layer
// includes Flutter's Android USB-host implementation as well as desktop libusb.
//
// Sibling of swdart_loader_stress.dart, which targets the CBT7 VCU. This one
// targets the RBT7 MCU, the board where a regression in the reset catch
// actually corrupts flash.
import 'dart:io';

class _Options {
  const _Options({required this.cycles, this.outputDirectory});

  final int cycles;
  final String? outputDirectory;
}

String _usage() =>
    'Usage: dart run tool/swdart_mcu_stress.dart '
    '--confirm-sacrificial --cycles <positive integer> [--out <directory>]';

_Options _parseOptions(List<String> args) {
  var confirmed = false;
  int? cycles;
  String? outputDirectory;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--confirm-sacrificial':
        confirmed = true;
      case '--cycles':
        if (++i >= args.length) throw FormatException(_usage());
        cycles = int.tryParse(args[i]);
      case '--out':
        if (++i >= args.length) throw FormatException(_usage());
        outputDirectory = args[i];
      case '--help':
      case '-h':
        print(_usage());
        exit(0);
      default:
        throw FormatException('Unknown argument: ${args[i]}\n${_usage()}');
    }
  }
  if (!confirmed) {
    throw FormatException(
      'Refusing destructive hardware test without --confirm-sacrificial.\n'
      '${_usage()}',
    );
  }
  if (cycles == null || cycles <= 0) {
    throw FormatException('--cycles must be a positive integer.\n${_usage()}');
  }
  return _Options(cycles: cycles, outputDirectory: outputDirectory);
}

Future<void> main(List<String> args) async {
  late final _Options options;
  try {
    options = _parseOptions(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }

  final flutterArgs = <String>[
    'test',
    'test/hardware/swdart_mcu_loader_stress_test.dart',
    '--dart-define=X3UTILS_MCU_STRESS_CONFIRMED=true',
    '--dart-define=X3UTILS_MCU_STRESS_CYCLES=${options.cycles}',
    if (options.outputDirectory != null)
      '--dart-define=X3UTILS_MCU_STRESS_OUT=${options.outputDirectory}',
  ];
  final process = await Process.start(
    Platform.isWindows ? 'flutter.bat' : 'flutter',
    flutterArgs,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
