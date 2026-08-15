package dev.x3utils.x3utils_flutter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class AndroidUsbHostBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val connectionLock = Any()

    private var connection: UsbDeviceConnection? = null
    private var claimedInterface: UsbInterface? = null
    private var endpointOut: UsbEndpoint? = null
    private var endpointIn: UsbEndpoint? = null
    private var activeDeviceId: Int? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionDeviceId: Int? = null
    private var permissionCompletionScheduled = false
    private var disposed = false

    private val permissionAction = "${context.packageName}.USB_PERMISSION"

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            if (intent.action != permissionAction) return
            val result = pendingPermissionResult ?: return
            if (permissionCompletionScheduled) return
            permissionCompletionScheduled = true
            mainHandler.postDelayed({
                if (pendingPermissionResult !== result) return@postDelayed
                val requestedDeviceId = pendingPermissionDeviceId
                pendingPermissionResult = null
                pendingPermissionDeviceId = null
                permissionCompletionScheduled = false
                val device = stlinkDevices().singleOrNull {
                    it.deviceId == requestedDeviceId
                }
                if (device != null && usbManager.hasPermission(device)) {
                    result.success(
                        mapOf(
                            "state" to "ready",
                            "productName" to productName(device),
                        ),
                    )
                } else {
                    result.error(
                        "permission_required",
                        "USB permission was not granted for the ST-Link.",
                        null,
                    )
                }
                publishDeviceChanged()
            }, PERMISSION_SETTLE_DELAY_MS)
        }
    }

    private val deviceReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            val detached = intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED
            val device = usbDeviceExtra(intent)
            if (detached && device?.deviceId == activeDeviceId) {
                executor.execute { closeActiveConnection() }
            }
            publishDeviceChanged()
        }
    }

    init {
        channel.setMethodCallHandler(this)
        registerReceivers()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(statusFor(stlinkDevices()))
            "requestPermission" -> requestPermission(result)
            "open" -> open(call, result)
            "transfer" -> transfer(call, result)
            "close" -> close(result)
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (!usbHostSupported()) {
            result.error("unsupported", "This Android device does not support USB host mode.", null)
            return
        }
        val devices = stlinkDevices()
        if (devices.isEmpty()) {
            result.error("disconnected", "No supported ST-Link is connected over USB OTG.", null)
            return
        }
        if (devices.size != 1) {
            result.error(
                "ambiguous",
                "Multiple supported ST-Links are connected. Leave one attached and try again.",
                null,
            )
            return
        }
        val device = devices.single()
        if (usbManager.hasPermission(device)) {
            result.success(statusFor(devices))
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "A USB permission request is already in progress.", null)
            return
        }
        pendingPermissionResult = result
        pendingPermissionDeviceId = device.deviceId
        permissionCompletionScheduled = false
        val intent = Intent(permissionAction).setPackage(context.packageName)
        val permissionIntent = PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        usbManager.requestPermission(device, permissionIntent)
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        if (call.arguments != null) {
            result.error("unavailable", "Android USB open takes no arguments.", null)
            return
        }
        if (!usbHostSupported()) {
            result.error("unsupported", "This Android device does not support USB host mode.", null)
            return
        }
        val devices = stlinkDevices()
        if (devices.isEmpty()) {
            result.error("disconnected", "No supported ST-Link is connected over USB OTG.", null)
            return
        }
        if (devices.size != 1) {
            result.error(
                "ambiguous",
                "Multiple supported ST-Links are connected. Leave one attached and try again.",
                null,
            )
            return
        }
        val device = devices.single()
        if (!usbManager.hasPermission(device)) {
            result.error("permission_required", "USB permission is required for the ST-Link.", null)
            return
        }
        executor.execute {
            try {
                val opened = openDevice(device)
                postSuccess(result, opened)
            } catch (error: UsbBridgeException) {
                postError(result, error.code, error.message ?: "Could not open the ST-Link.")
            } catch (error: Throwable) {
                postError(result, "unavailable", error.message ?: "Could not open the ST-Link.")
            }
        }
    }

    private fun transfer(call: MethodCall, result: MethodChannel.Result) {
        val command = call.argument<ByteArray>("command")
        val data = call.argument<ByteArray>("data")
        val rxLen = call.argument<Int>("rxLen") ?: 0
        if (command == null || command.size > COMMAND_PACKET_LENGTH || rxLen < 0) {
            result.error("unavailable", "Invalid ST-Link USB transfer arguments.", null)
            return
        }
        executor.execute {
            try {
                val response = transferOnWorker(command, data, rxLen)
                postSuccess(result, response)
            } catch (error: UsbBridgeException) {
                postError(result, error.code, error.message ?: "ST-Link USB transfer failed.")
            } catch (error: Throwable) {
                postError(result, "unavailable", error.message ?: "ST-Link USB transfer failed.")
            }
        }
    }

    private fun close(result: MethodChannel.Result) {
        executor.execute {
            closeActiveConnection()
            postSuccess(result, null)
        }
    }

    private fun openDevice(device: UsbDevice): Map<String, Any> {
        synchronized(connectionLock) {
            closeActiveConnectionLocked()
            val usbInterface = device.getInterface(0)
                ?: throw UsbBridgeException("unavailable", "The ST-Link has no USB interface 0.")
            val wantedOut = outEndpointAddress(device.productId)
            var foundOut: UsbEndpoint? = null
            var foundIn: UsbEndpoint? = null
            for (index in 0 until usbInterface.endpointCount) {
                val endpoint = usbInterface.getEndpoint(index)
                if (endpoint.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (endpoint.address == wantedOut) foundOut = endpoint
                if (endpoint.address == ENDPOINT_IN) foundIn = endpoint
            }
            val out = foundOut ?: throw UsbBridgeException(
                "unavailable",
                "The ST-Link bulk OUT endpoint 0x${wantedOut.toString(16)} is missing.",
            )
            val input = foundIn ?: throw UsbBridgeException(
                "unavailable",
                "The ST-Link bulk IN endpoint 0x${ENDPOINT_IN.toString(16)} is missing.",
            )
            val opened = usbManager.openDevice(device)
                ?: throw UsbBridgeException("busy", "Android could not open the ST-Link.")
            if (!opened.claimInterface(usbInterface, true)) {
                opened.close()
                throw UsbBridgeException("busy", "Android could not claim the ST-Link interface.")
            }
            connection = opened
            claimedInterface = usbInterface
            endpointOut = out
            endpointIn = input
            activeDeviceId = device.deviceId
            return deviceDetails(device)
        }
    }

    private fun transferOnWorker(command: ByteArray, data: ByteArray?, rxLen: Int): ByteArray {
        synchronized(connectionLock) {
            val opened = connection
                ?: throw UsbBridgeException("disconnected", "The ST-Link USB connection is closed.")
            val out = endpointOut
                ?: throw UsbBridgeException("disconnected", "The ST-Link OUT endpoint is unavailable.")
            val input = endpointIn
                ?: throw UsbBridgeException("disconnected", "The ST-Link IN endpoint is unavailable.")

            val packet = ByteArray(COMMAND_PACKET_LENGTH)
            command.copyInto(packet)
            requireFullOut(opened, out, packet, "command")
            if (data != null && data.isNotEmpty()) requireFullOut(opened, out, data, "data")
            if (rxLen == 0) return ByteArray(0)

            val response = ByteArray(rxLen)
            val transferred = opened.bulkTransfer(input, response, response.size, TRANSFER_TIMEOUT_MS)
            if (transferred < 0) {
                throw UsbBridgeException("disconnected", "ST-Link bulk IN transfer failed or timed out.")
            }
            return response.copyOf(transferred)
        }
    }

    private fun requireFullOut(
        opened: UsbDeviceConnection,
        endpoint: UsbEndpoint,
        bytes: ByteArray,
        label: String,
    ) {
        val transferred = opened.bulkTransfer(endpoint, bytes, bytes.size, TRANSFER_TIMEOUT_MS)
        if (transferred != bytes.size) {
            throw UsbBridgeException(
                "disconnected",
                "ST-Link bulk OUT $label transferred $transferred of ${bytes.size} bytes.",
            )
        }
    }

    private fun closeActiveConnection() {
        synchronized(connectionLock) { closeActiveConnectionLocked() }
    }

    private fun closeActiveConnectionLocked() {
        val opened = connection
        val usbInterface = claimedInterface
        if (opened != null && usbInterface != null) {
            runCatching { opened.releaseInterface(usbInterface) }
        }
        runCatching { opened?.close() }
        connection = null
        claimedInterface = null
        endpointOut = null
        endpointIn = null
        activeDeviceId = null
    }

    private fun statusFor(devices: List<UsbDevice>): Map<String, Any?> {
        if (!usbHostSupported()) return mapOf("state" to "unsupported")
        if (devices.isEmpty()) return mapOf("state" to "disconnected")
        if (devices.size > 1) return mapOf("state" to "ambiguous")
        val device = devices.single()
        return if (usbManager.hasPermission(device)) {
            mapOf(
                "state" to "ready",
                "productName" to productName(device),
            )
        } else {
            mapOf(
                "state" to "selectionRequired",
                "productName" to productName(device),
            )
        }
    }

    private fun deviceDetails(device: UsbDevice): Map<String, Any> = mapOf(
        "productId" to device.productId,
        "productName" to productName(device),
    )

    private fun productName(device: UsbDevice): String = when {
        !device.productName.isNullOrBlank() -> device.productName!!
        device.productId in V3_PIDS -> "STLINK-V3"
        device.productId == 0x3748 -> "ST-Link/V2"
        else -> "ST-Link/V2-1"
    }

    private fun stlinkDevices(): List<UsbDevice> = usbManager.deviceList.values
        .filter { it.vendorId == STLINK_VID && it.productId in STLINK_PIDS }
        .sortedBy { it.deviceId }

    private fun usbHostSupported(): Boolean = context.packageManager.hasSystemFeature(
        PackageManager.FEATURE_USB_HOST,
    )

    private fun outEndpointAddress(productId: Int): Int =
        if (productId in OUT_ENDPOINT_01_PIDS) 0x01 else 0x02

    private fun publishDeviceChanged() {
        mainHandler.post {
            if (!disposed) channel.invokeMethod("deviceChanged", null)
        }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { if (!disposed) result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { if (!disposed) result.error(code, message, null) }
    }

    private fun registerReceivers() {
        val permissionFilter = IntentFilter(permissionAction)
        val deviceFilter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(permissionReceiver, permissionFilter, Context.RECEIVER_NOT_EXPORTED)
            context.registerReceiver(deviceReceiver, deviceFilter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(permissionReceiver, permissionFilter)
            @Suppress("DEPRECATION")
            context.registerReceiver(deviceReceiver, deviceFilter)
        }
    }

    @Suppress("DEPRECATION")
    private fun usbDeviceExtra(intent: Intent): UsbDevice? =
        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        pendingPermissionResult?.error("unavailable", "Android USB host bridge closed.", null)
        pendingPermissionResult = null
        pendingPermissionDeviceId = null
        permissionCompletionScheduled = false
        runCatching { context.unregisterReceiver(permissionReceiver) }
        runCatching { context.unregisterReceiver(deviceReceiver) }
        executor.execute { closeActiveConnection() }
        executor.shutdown()
    }

    private class UsbBridgeException(val code: String, message: String) : Exception(message)

    companion object {
        private const val CHANNEL_NAME = "dev.x3utils/usb_host"
        private const val STLINK_VID = 0x0483
        private const val COMMAND_PACKET_LENGTH = 16
        private const val ENDPOINT_IN = 0x81
        private const val TRANSFER_TIMEOUT_MS = 2000
        private const val PERMISSION_SETTLE_DELAY_MS = 200L

        private val STLINK_PIDS = setOf(
            0x3748,
            0x374b,
            0x3752,
            0x374d,
            0x374e,
            0x374f,
            0x3753,
            0x3754,
            0x3755,
            0x3757,
        )
        private val V3_PIDS = setOf(0x374d, 0x374e, 0x374f, 0x3753, 0x3754, 0x3755, 0x3757)
        private val OUT_ENDPOINT_01_PIDS = setOf(
            0x374b,
            0x3752,
            0x374d,
            0x374e,
            0x374f,
            0x3753,
            0x3754,
            0x3755,
            0x3757,
        )
    }
}
