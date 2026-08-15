package dev.x3utils.x3utils_flutter

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class AndroidBackupBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "publishBackup") {
            result.notImplemented()
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "unsupported",
                "Android Backup requires Android 10 or newer.",
                null,
            )
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = call.argument<String>("fileName")
        if (bytes == null || fileName == null || !VALID_FILE_NAME.matches(fileName)) {
            result.error("invalid_backup", "The Android backup request was invalid.", null)
            return
        }
        executor.execute {
            try {
                val displayPath = publish(bytes, fileName)
                mainHandler.post { result.success(displayPath) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error(
                        "storage_failed",
                        error.message ?: "Android could not save the backup.",
                        null,
                    )
                }
            }
        }
    }

    private fun publish(bytes: ByteArray, fileName: String): String {
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )
        if (backupExists(collection, fileName)) {
            throw IOException("A backup named $fileName already exists.")
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
            put(MediaStore.Downloads.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IOException("Android could not create the backup file.")
        try {
            resolver.openOutputStream(uri, "w")?.use { stream ->
                stream.write(bytes)
                stream.flush()
            } ?: throw IOException("Android could not open the backup file.")
            val published = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            if (resolver.update(uri, published, null, null) != 1) {
                throw IOException("Android could not publish the completed backup.")
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        return "$DISPLAY_DIRECTORY/$fileName"
    }

    private fun backupExists(collection: android.net.Uri, fileName: String): Boolean {
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection =
            "${MediaStore.Downloads.DISPLAY_NAME} = ? AND " +
                "${MediaStore.Downloads.RELATIVE_PATH} = ?"
        context.contentResolver.query(
            collection,
            projection,
            selection,
            arrayOf(fileName, RELATIVE_PATH),
            null,
        )?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    companion object {
        private const val CHANNEL_NAME = "dev.x3utils/backup_store"
        private const val DISPLAY_DIRECTORY = "Downloads/x3utils/backup"
        private val RELATIVE_PATH =
            "${Environment.DIRECTORY_DOWNLOADS}/x3utils/backup/"
        private val VALID_FILE_NAME = Regex("^[A-Za-z0-9._-]+\\.bin$")
    }
}
