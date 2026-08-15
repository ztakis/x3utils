import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/android_backup_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(androidBackupStoreChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'publishes validated bytes to the fixed Android backup folder',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'publishBackup');
        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments['bytes'], bytes);
        expect(arguments['fileName'], 'dump_2026-08-14_12-00-00.bin');
        return '$androidBackupDirectoryLabel/dump_2026-08-14_12-00-00.bin';
      });

      final path = await publishAndroidBackup(
        bytes,
        'dump_2026-08-14_12-00-00.bin',
      );

      expect(path, '$androidBackupDirectoryLabel/dump_2026-08-14_12-00-00.bin');
    },
  );

  test('turns native storage failures into an Android storage error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'storage_failed',
        message: 'Downloads is unavailable.',
      );
    });

    await expectLater(
      publishAndroidBackup(Uint8List(4), 'dump_test.bin'),
      throwsA(
        isA<AndroidBackupStoreException>().having(
          (error) => error.message,
          'message',
          contains('Downloads is unavailable'),
        ),
      ),
    );
  });
}
