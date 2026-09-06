// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'dart:typed_data';

import 'cortexm.dart';
import 'debug_probe.dart';
import 'loader.dart';
import 'util.dart';

typedef ProgressFn = void Function(int done, int total);

abstract class FlashDriver {
  int get programAlign;
  Future<void> prepareProgram();
  Future<void> erase(int address, int length, [ProgressFn? progress]);
  Future<void> program(int address, Uint8List data, [ProgressFn? progress]);
  Future<void> verify(int address, Uint8List data, [ProgressFn? progress]);
}

const _atBase = 0x40022000;
const _atUnlock = _atBase + 0x04;
const _atUsdUnlock = _atBase + 0x08;
const _atSts = _atBase + 0x0c;
const _atCtrl = _atBase + 0x10;
const _atAddr = _atBase + 0x14;

const _key1 = 0x45670123;
const _key2 = 0xcdef89ab;

const _ctrlFprgm = 1 << 0;
const _ctrlSecers = 1 << 1;
const _ctrlUsdprgm = 1 << 4;
const _ctrlUsders = 1 << 5;
const _ctrlErstr = 1 << 6;
const _ctrlOplk = 1 << 7;
const _ctrlUsdulks = 1 << 9;

const _stsObf = 1 << 0;
const _stsPrgmerr = 1 << 2;
const _stsEpperr = 1 << 4;

const _crmCtrl = 0x40021000;
const _crmCtrlsts = 0x40021024;

// DMA controllers. Halting the core stops the CPU, not the DMA engines: a
// firmware that had already started an ADC ring buffer keeps writing SRAM while
// we stage the loader's chunk there, and the loader then programs whatever DMA
// left behind. These are chip constants, so quiescing them needs no knowledge
// of which firmware or which board role is on the other end of the cable.
const _dma1Base = 0x40020000;
const _dma2Base = 0x40020400;
const _dmaChannels = 7;
const _dmaChannelStride = 0x14;
const _dmaChannelCtrl = 0x08;
const _dmaChannelEnable = 1 << 0;
const _crmHicken = 1 << 0;
const _crmHickstbl = 1 << 1;
const _dbgmcuCr = 0xe0042004;
const _vtor = 0xe000ed08;
const _wdtBase = 0x40003000;
const _wdtReload = 0xaaaa;

class At32Flash implements FlashDriver {
  At32Flash(
    this._probe,
    this._core,
    this._pageSize,
    this._sramBytes, {
    this.useLoader = false,
    this.onLog,
    this.loaderTimeoutMs = 10000,
    this.loaderDiagnostics = false,
  }) : assert(_sramBytes > 0);

  final DebugProbe _probe;
  final CortexM _core;
  final int _pageSize;
  final int _sramBytes;
  final bool useLoader;
  final void Function(String line)? onLog;
  final int loaderTimeoutMs;
  final bool loaderDiagnostics;
  bool _programPathPrepared = false;
  bool _usePreparedLoader = false;
  int? _loaderBaselineResetFlags;

  static const _sramBase = 0x20000000;
  static const _vectorTableAddr = _sramBase;
  static const _loaderAddr = _sramBase + loaderVectorTableBytes;
  static const _bufferAddr = _sramBase + 0x800;
  static const _loaderStackTop = _bufferAddr;

  @override
  int get programAlign => 4;

  int get loaderBufferSize {
    final reserved = _bufferAddr - _sramBase;
    final usable = ((_sramBytes - reserved) >> 2) << 2;
    final size = usable < 0x2000 ? usable : 0x2000;
    if (size < 0x400) {
      throw SwdException(
        'target SRAM ($_sramBytes B) is too small for the flash loader; '
        'the direct word-write path does not need it',
      );
    }
    return size;
  }

  Future<void> preflightProgram() async {
    if (!await _core.isHalted()) {
      throw SwdException('core must be halted to preflight the flash loader');
    }
    await _reloadWatchdog('preflight');
    await runLoader(
      _probe,
      _core,
      wordLoader,
      vectorTableAddr: _vectorTableAddr,
      loaderAddr: _loaderAddr,
      stackTop: _loaderStackTop,
      srcAddr: _bufferAddr,
      dstAddr: 0x08000000,
      count: 0,
      flashRegBase: _atBase,
      timeoutMs: loaderTimeoutMs,
      context: 'preflight',
      baselineResetFlags: _loaderBaselineResetFlags,
    );
  }

  /// Stop every DMA channel before anything is staged in SRAM.
  ///
  /// Halting the core does not stop the DMA engines. A motor-controller
  /// firmware that reached its ADC setup keeps writing its ring buffer while
  /// halted, and if that buffer overlaps [_bufferAddr] the loader programs the
  /// samples into flash instead of the image. Measured on a ZT3 MCU: a ring at
  /// `0x20000FA8` corrupted the same ~390 bytes of every 8 KiB chunk.
  ///
  /// Nothing re-enables the channels afterwards — the core is halted and the
  /// only code it runs from here is our own loader.
  ///
  /// Supported AT32F415 parts implement both DMA controllers. A failed read
  /// leaves the channel's state unknown; it does not establish absence. Every
  /// channel must be confirmed disabled before programming can proceed.
  ///
  /// The disable is read back rather than assumed. A write that faults, or one
  /// the controller ignores, would otherwise leave a live channel behind while
  /// the log claimed it was stopped — and the staged-buffer check cannot cover
  /// that, being a point-in-time comparison: DMA can land between the readback
  /// and the loader consuming the buffer.
  Future<void> quiesceBusMasters() async {
    var stopped = 0;
    final unresolved = <String>[];
    for (final base in const [_dma1Base, _dma2Base]) {
      for (var channel = 0; channel < _dmaChannels; channel++) {
        final ctrl = base + _dmaChannelCtrl + channel * _dmaChannelStride;
        final int value;
        try {
          value = await _probe.readDebugReg(ctrl);
        } catch (error) {
          unresolved.add('${hex(ctrl)} (read failed: $error)');
          continue;
        }
        if (value & _dmaChannelEnable == 0) continue;
        try {
          await _probe.writeDebugReg(ctrl, value & ~_dmaChannelEnable);
          final after = await _probe.readDebugReg(ctrl);
          if (after & _dmaChannelEnable != 0) {
            unresolved.add('${hex(ctrl)} (still enabled, CTRL=${hex(after)})');
            continue;
          }
          stopped++;
        } catch (error) {
          unresolved.add('${hex(ctrl)} ($error)');
        }
      }
    }
    if (stopped != 0) {
      onLog?.call(
        '[flash] stopped $stopped active DMA channel(s) before staging',
      );
    }
    if (unresolved.isNotEmpty) {
      throw SwdException(
        'could not confirm ${unresolved.length} DMA channel(s) disabled before '
        'staging: ${unresolved.join(', ')}. Programming aborted — a live DMA '
        'channel can overwrite the loader buffer and put its data into flash.',
      );
    }
  }

  Future<void> _reloadWatchdog(String context) async {
    // DBGMCU_CR freezes WDT only while the core is halted. Give every
    // target-side loader run a full watchdog period before resuming it.
    await _probe.writeDebugReg(_wdtBase, _wdtReload);
    if (loaderDiagnostics) {
      onLog?.call('[flash:loader] watchdog reloaded before $context');
    }
  }

  Future<int?> _tryDiagnosticRead(int address) async {
    try {
      return await _probe.readDebugReg(address);
    } catch (_) {
      return null;
    }
  }

  String _diagnostic(String name, int? value) =>
      '$name=${value == null ? "unavailable" : hex(value)}';

  Future<void> _captureLoaderBaseline() async {
    final vtor = await _tryDiagnosticRead(_vtor);
    final crmCtrlsts = await _tryDiagnosticRead(_crmCtrlsts);
    final dbgmcuCr = await _tryDiagnosticRead(_dbgmcuCr);
    final wdtDiv = await _tryDiagnosticRead(_wdtBase + 0x04);
    final wdtRld = await _tryDiagnosticRead(_wdtBase + 0x08);
    final wdtSts = await _tryDiagnosticRead(_wdtBase + 0x0c);
    final wdtWin = await _tryDiagnosticRead(_wdtBase + 0x10);
    final flashSts = await _tryDiagnosticRead(_atSts);
    final flashCtrl = await _tryDiagnosticRead(_atCtrl);
    final flashAddr = await _tryDiagnosticRead(_atAddr);
    _loaderBaselineResetFlags = crmCtrlsts;
    onLog?.call(
      '[flash:loader] baseline '
      '${_diagnostic("VTOR", vtor)}, '
      '${_diagnostic("CRM_CTRLSTS", crmCtrlsts)} '
      '(reset=${crmCtrlsts == null ? "unavailable" : decodeAt32ResetFlags(crmCtrlsts)}), '
      '${_diagnostic("DBGMCU_CR", dbgmcuCr)}, '
      '${_diagnostic("WDT_DIV", wdtDiv)}, '
      '${_diagnostic("WDT_RLD", wdtRld)}, '
      '${_diagnostic("WDT_STS", wdtSts)}, '
      '${_diagnostic("WDT_WIN", wdtWin)}, '
      '${_diagnostic("FLASH_STS", flashSts)}, '
      '${_diagnostic("FLASH_CTRL", flashCtrl)}, '
      '${_diagnostic("FLASH_ADDR", flashAddr)}',
    );
  }

  @override
  Future<void> prepareProgram() async {
    _programPathPrepared = false;
    _usePreparedLoader = false;
    _loaderBaselineResetFlags = null;
    if (!useLoader) {
      _programPathPrepared = true;
      return;
    }
    if (loaderDiagnostics) await _captureLoaderBaseline();
    // Before the preflight, not after: the preflight itself stages and runs
    // from SRAM.
    await quiesceBusMasters();
    try {
      await preflightProgram();
      _usePreparedLoader = true;
      _programPathPrepared = true;
    } on LoaderHaltTimeout catch (error) {
      if (!error.forcedHalt) rethrow;
      _programPathPrepared = true;
      onLog?.call(
        '[flash] SRAM loader preflight failed before erase; '
        'using direct word writes: $error',
      );
    }
  }

  Future<int> _waitBusy(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    for (;;) {
      final sts = await _probe.readDebugReg(_atSts);
      if ((sts & _stsObf) == 0) return sts;
      if (DateTime.now().isAfter(deadline)) {
        throw SwdException('AT32 flash busy after $timeoutMs ms');
      }
      await sleep(2);
    }
  }

  Future<void> _enableHick() async {
    var ctrl = await _probe.readDebugReg(_crmCtrl);
    if (ctrl & _crmHickstbl != 0) return;
    await _probe.writeDebugReg(_crmCtrl, ctrl | _crmHicken);
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    do {
      ctrl = await _probe.readDebugReg(_crmCtrl);
      if (ctrl & _crmHickstbl != 0) return;
      await sleep(2);
    } while (DateTime.now().isBefore(deadline));
    throw SwdException('AT32 HICK clock did not stabilize');
  }

  Future<void> _unlockFlash() async {
    if ((await _probe.readDebugReg(_atCtrl) & _ctrlOplk) == 0) return;
    await _probe.writeDebugReg(_atUnlock, _key1);
    await _probe.writeDebugReg(_atUnlock, _key2);
    if (await _probe.readDebugReg(_atCtrl) & _ctrlOplk != 0) {
      throw SwdException('AT32 flash unlock failed (OPLK still set)');
    }
  }

  Future<void> _unlockUsd() async {
    if (await _probe.readDebugReg(_atCtrl) & _ctrlUsdulks != 0) return;
    await _probe.writeDebugReg(_atUsdUnlock, _key1);
    await _probe.writeDebugReg(_atUsdUnlock, _key2);
    if (await _probe.readDebugReg(_atCtrl) & _ctrlUsdulks == 0) {
      throw SwdException('AT32 user-system-data unlock failed');
    }
  }

  Future<void> _initFlash() async {
    await _enableHick();
    await _unlockFlash();
    await _unlockUsd();
  }

  Future<void> _deinitFlash() async {
    var ctrl = await _probe.readDebugReg(_atCtrl);
    if (ctrl & _ctrlUsdulks != 0) {
      await _probe.writeDebugReg(_atCtrl, ctrl & ~_ctrlUsdulks);
    }
    ctrl = await _probe.readDebugReg(_atCtrl);
    if (ctrl & _ctrlOplk == 0) {
      await _probe.writeDebugReg(_atCtrl, ctrl | _ctrlOplk);
    }
  }

  void _checkErr(int sts, String what) {
    if (sts & _stsEpperr != 0) {
      throw SwdException('$what: erase/program protection error (EPPERR)');
    }
    if (sts & _stsPrgmerr != 0) {
      throw SwdException('$what: programming error (PRGMERR)');
    }
  }

  /// Erase the complete user-system-data area and program only the FAP
  /// halfword as A5/5A (unlocked).
  ///
  /// On a *protected* part, writing the FAP halfword makes the device
  /// mass-erase main flash and reset, which tears down the SWD link mid-write —
  /// so that write faulting is the expected signature of success, not a
  /// failure. Everything that can genuinely fail is validated before the
  /// destructive erase; the FAP write and the relock after it are tolerated. On
  /// an already-unprotected part the write acknowledges cleanly and the
  /// controller is relocked normally.
  Future<void> rewriteFapUnlocked({
    required void Function(ProtectionRewriteStage stage) onStage,
  }) async {
    if (!await _core.isHalted()) {
      throw SwdException('core must be halted to rewrite AT32 protection');
    }
    // The FAP rewrite needs a 16-bit option write. Prove it before erasing: the
    // erase is destructive and the halfword write is the only thing that makes
    // the outcome meaningful.
    if (!_probe.hasMem16) {
      throw SwdException(
        'Disabling FAP needs 16-bit memory access, which this probe does not '
        'have (${_probe.version.text}; needs ST-Link V2 firmware J26+ or a V3 '
        'probe). The option area was left untouched.',
      );
    }
    await _enableHick();

    // Erase phase. FAP is still non-0xA5, so nothing irreversible to the part
    // has happened yet — a fault here is a real failure, and the controller can
    // still be relocked before it propagates.
    try {
      await _unlockFlash();
      await _unlockUsd();
      await _waitBusy(50);
      await _probe.writeDebugReg(_atSts, _stsEpperr | _stsPrgmerr);

      // Match the field-tested OpenOCD raw-register sequence:
      // CTRL=0x220 (USD unlock + USD erase), then 0x260 (start erase).
      await _probe.writeDebugReg(_atCtrl, _ctrlUsdulks | _ctrlUsders);
      await _probe.writeDebugReg(
        _atCtrl,
        _ctrlUsdulks | _ctrlUsders | _ctrlErstr,
      );
      _checkErr(await _waitBusy(1000), 'erase AT32 user-system-data');
    } catch (error, stackTrace) {
      try {
        await _probe.writeDebugReg(_atCtrl, _ctrlOplk);
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
    onStage(ProtectionRewriteStage.usdErased);

    // FAP program phase — the reset zone. Program only FAP/nFAP; do not copy
    // masked WRP/SSB/data bytes back. On a protected part this write triggers
    // the mass-erase and reset, so any fault from here on (the write, the busy
    // wait, or the relock) is tolerated — the chip resets itself and there is
    // nothing left to verify or lock. On an unprotected part it completes and
    // relocks normally.
    await _probe.writeDebugReg(_atCtrl, _ctrlUsdulks | _ctrlUsdprgm);
    try {
      await _probe.writeMem16(
        0x1ffff800,
        Uint8List.fromList(const [0xa5, 0x5a]),
      );
      _checkErr(await _waitBusy(1000), 'program AT32 FAP halfword');
      await _probe.writeDebugReg(_atCtrl, _ctrlOplk);
    } catch (_) {
      // Reset in flight — expected on a protected part; nothing left to do.
    }
    onStage(ProtectionRewriteStage.fapProgrammed);
  }

  @override
  Future<void> erase(int address, int length, [ProgressFn? progress]) async {
    final first = ((address - 0x08000000) / _pageSize).floor();
    final last = (((address + length - 0x08000000) / _pageSize).ceil()) - 1;
    final total = last - first + 1;
    await _initFlash();
    try {
      await _probe.writeDebugReg(_atSts, _stsEpperr);
      await _waitBusy(50);
      var done = 0;
      for (var page = first; page <= last; page++) {
        final pageAddr = 0x08000000 + page * _pageSize;
        await _probe.writeDebugReg(_atAddr, pageAddr);
        await _probe.writeDebugReg(_atCtrl, _ctrlSecers | _ctrlErstr);
        _checkErr(await _waitBusy(500), 'erase page ${hex(pageAddr)}');
        progress?.call(++done, total);
      }
    } finally {
      await _deinitFlash();
    }
  }

  @override
  Future<void> program(
    int address,
    Uint8List data, [
    ProgressFn? progress,
  ]) async {
    if (!_programPathPrepared) await prepareProgram();
    final usePreparedLoader = _usePreparedLoader;
    _programPathPrepared = false;
    _usePreparedLoader = false;

    if (address % 4 != 0) {
      throw SwdException('AT32 program address must be word-aligned');
    }
    if (!await _core.isHalted()) {
      throw SwdException('core must be halted to program flash');
    }

    final paddedLength = ((data.length + 3) >> 2) << 2;
    final padded = Uint8List(paddedLength)
      ..fillRange(0, paddedLength, 0xff)
      ..setRange(0, data.length, data);

    if (usePreparedLoader) {
      return _programViaLoader(address, padded, progress);
    }

    await _initFlash();
    try {
      await _waitBusy(5);
      await _probe.writeDebugReg(_atSts, _stsPrgmerr | _stsEpperr);
      await _probe.writeDebugReg(_atCtrl, _ctrlFprgm);
      final total = padded.length;
      for (var off = 0; off < total; off += 4) {
        final word = Uint8List.sublistView(padded, off, off + 4);
        if (u32le(word, 0) != 0xffffffff) {
          await _probe.writeMem32(address + off, word);
          _checkErr(await _waitBusy(5), 'program at ${hex(address + off)}');
        }
        if (((off + 4) & 0x3ff) == 0) {
          progress?.call(off + 4, total);
          await sleep(0);
        }
      }
      progress?.call(total, total);
    } finally {
      try {
        await _probe.writeDebugReg(_atCtrl, 0);
      } finally {
        await _deinitFlash();
      }
    }
  }

  /// Write one chunk into the SRAM staging buffer and prove it is still there.
  ///
  /// The loader programs whatever these bytes are, so a silent SRAM write from
  /// anything else on the bus becomes flash content with no error raised
  /// anywhere. The readback turns that into a caught failure, and it does so
  /// without needing to know what did the writing — DMA, another bus master, or
  /// a short USB transfer all look the same here.
  ///
  /// One retry, because the plausible causes are transient. [quiesceBusMasters]
  /// has already stopped the engines we know about, so a second corruption
  /// means something is still running and the run must not continue.
  Future<void> _stageChunk(Uint8List chunk, int index, int total) async {
    for (var attempt = 1; ; attempt++) {
      await _probe.writeMem32(_bufferAddr, chunk);
      final staged = await _probe.readMem32(_bufferAddr, chunk.length);
      var bad = -1;
      for (var i = 0; i < chunk.length; i++) {
        if (staged[i] != chunk[i]) {
          bad = i;
          break;
        }
      }
      if (bad < 0) return;
      final detail =
          'chunk $index/$total staging corrupted at SRAM '
          '${hex(_bufferAddr + bad)} (wrote '
          '0x${chunk[bad].toRadixString(16).padLeft(2, "0")}, read back '
          '0x${staged[bad].toRadixString(16).padLeft(2, "0")})';
      if (attempt >= 2) {
        throw SwdException(
          '$detail after $attempt attempts. Something is still writing SRAM '
          'while the core is halted — flash was NOT completed.',
        );
      }
      onLog?.call('[flash:loader] $detail — restaging');
      await quiesceBusMasters();
    }
  }

  Future<void> _programViaLoader(
    int address,
    Uint8List padded,
    ProgressFn? progress,
  ) async {
    final bufferSize = loaderBufferSize;
    final totalStopwatch = Stopwatch()..start();
    await _initFlash();
    try {
      await _waitBusy(5);
      await _probe.writeDebugReg(_atSts, _stsPrgmerr | _stsEpperr);
      final total = padded.length;
      final chunks = (total + bufferSize - 1) ~/ bufferSize;
      var done = 0;
      var chunkIndex = 0;
      while (done < total) {
        chunkIndex++;
        final chunkLen = total - done < bufferSize ? total - done : bufferSize;
        final destination = address + done;
        final chunkStopwatch = Stopwatch()..start();
        if (loaderDiagnostics) {
          onLog?.call(
            '[flash:loader] chunk $chunkIndex/$chunks start '
            'dst=${hex(destination)}, bytes=$chunkLen, '
            'words=${chunkLen >> 2}, '
            'elapsed=${totalStopwatch.elapsedMilliseconds} ms',
          );
        }
        final chunk = Uint8List.sublistView(padded, done, done + chunkLen);
        await _stageChunk(chunk, chunkIndex, chunks);
        await _probe.writeDebugReg(_atCtrl, _ctrlFprgm);
        try {
          await _reloadWatchdog('chunk $chunkIndex/$chunks');
          await runLoader(
            _probe,
            _core,
            wordLoader,
            vectorTableAddr: _vectorTableAddr,
            loaderAddr: _loaderAddr,
            stackTop: _loaderStackTop,
            srcAddr: _bufferAddr,
            dstAddr: destination,
            count: chunkLen >> 2,
            flashRegBase: _atBase,
            timeoutMs: loaderTimeoutMs,
            context: 'chunk $chunkIndex/$chunks',
            baselineResetFlags: _loaderBaselineResetFlags,
          );
          _checkErr(
            await _probe.readDebugReg(_atSts),
            'program at ${hex(destination)}',
          );
        } finally {
          await _probe.writeDebugReg(_atCtrl, 0);
        }
        done += chunkLen;
        if (loaderDiagnostics) {
          onLog?.call(
            '[flash:loader] chunk $chunkIndex/$chunks complete '
            'dst=${hex(destination)}, bytes=$chunkLen, '
            'chunk=${chunkStopwatch.elapsedMilliseconds} ms, '
            'elapsed=${totalStopwatch.elapsedMilliseconds} ms',
          );
        }
        progress?.call(done, total);
        await sleep(0);
      }
    } finally {
      await _deinitFlash();
    }
  }

  @override
  Future<void> verify(
    int address,
    Uint8List data, [
    ProgressFn? progress,
  ]) async {
    final total = data.length;
    var done = 0;
    while (done < total) {
      final chunkLen = total - done < 1024 ? total - done : 1024;
      final readLen = ((chunkLen + 3) >> 2) << 2;
      final read = await _probe.readMem32(address + done, readLen);
      for (var i = 0; i < chunkLen; i++) {
        if (read[i] != data[done + i]) {
          throw SwdException(
            'verify FAILED at ${hex(address + done + i)}: '
            'wrote 0x${data[done + i].toRadixString(16).padLeft(2, "0")}, '
            'read 0x${read[i].toRadixString(16).padLeft(2, "0")}',
          );
        }
      }
      done += chunkLen;
      progress?.call(done, total);
      await sleep(0);
    }
  }
}

enum ProtectionRewriteStage { usdErased, fapProgrammed }
