package dev.x3utils.x3utils_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var usbHostBridge: AndroidUsbHostBridge? = null
    private var backupBridge: AndroidBackupBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbHostBridge = AndroidUsbHostBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        backupBridge = AndroidBackupBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        usbHostBridge?.dispose()
        usbHostBridge = null
        backupBridge?.dispose()
        backupBridge = null
        super.onDestroy()
    }
}
