import 'package:universal_io/universal_io.dart';
import '../models.dart';

/// Per-OS OpenOCD config paths.
///
/// Windows + Linux share the `at32f415xx*` cfg names (same bundled OpenOCD
/// scripts). macOS ships the xpack OpenOCD 0.12 whose Artery target lives at
/// `target/artery/at32f4x*`. Only the paths differ — the commands + guided
/// procs are identical across OSes.
class Cfg {
  static const interface = 'interface/stlink.cfg';

  static String _base() =>
      Platform.isMacOS ? 'target/artery/at32f4x' : 'target/at32f415xx';

  /// Target cfg for a connection mode: guided C45, genuine nRST, or plain SWD.
  static String target(ConnectionMode mode) => switch (mode) {
    ConnectionMode.cloneC45 => '${_base()}_c45.cfg',
    ConnectionMode.genuineC45 => '${_base()}_nrst.cfg',
    _ => '${_base()}.cfg',
  };

  /// The guided C45 cfg (always the _c45 variant).
  static String get c45 => '${_base()}_c45.cfg';

  /// The power-race respawn cfg (holds the race_connect proc).
  static String get race => '${_base()}_race.cfg';
}
