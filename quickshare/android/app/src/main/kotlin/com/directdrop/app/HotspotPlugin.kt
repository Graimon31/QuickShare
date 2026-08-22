package com.directdrop.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Raises a local-only Wi-Fi hotspot so a phone that cannot reach us over the
 * internet can reach us over the air instead.
 *
 * `startLocalOnlyHotspot` is the right API here rather than the tethering one:
 * it needs no root and no carrier permission, it does not disturb mobile data,
 * and Android tears it down automatically when the app goes away — which is
 * exactly the lifetime a file transfer wants.
 */
class HotspotPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startHotspot" -> startHotspot(result)
            "stopHotspot" -> stopHotspot(result)
            "joinHotspot" -> result.success(null) // Android joins by scanning the QR.
            else -> result.notImplemented()
        }
    }

    private fun startHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error(
                "UNSUPPORTED",
                "Local-only hotspot needs Android 8.0 or newer",
                null,
            )
            return
        }

        // The permission is genuinely required: without it the framework
        // rejects the request with a bare SecurityException, which surfaces to
        // the user as an unexplained failure.
        if (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            result.error(
                "PERMISSION_DENIED",
                "Creating a Wi-Fi network needs the location permission. " +
                    "Android ties hotspot control to it because the network is " +
                    "identifiable by position.",
                null,
            )
            return
        }

        val wifiManager =
            context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        if (reservation != null) {
            result.error("ALREADY_RUNNING", "A hotspot is already running", null)
            return
        }

        try {
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                        reservation = res
                        result.success(credentialsOf(res))
                    }

                    override fun onFailed(reason: Int) {
                        reservation = null
                        result.error("START_FAILED", describeFailure(reason), null)
                    }

                    override fun onStopped() {
                        reservation = null
                    }
                },
                null,
            )
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: IllegalStateException) {
            // Thrown when Wi-Fi is off, or another app already holds a hotspot.
            result.error("UNAVAILABLE", e.message, null)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun credentialsOf(
        res: WifiManager.LocalOnlyHotspotReservation,
    ): Map<String, Any?> {
        // SoftApConfiguration replaced WifiConfiguration in API 30; the old
        // accessor throws on newer releases rather than returning null.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = res.softApConfiguration
            return mapOf(
                "ssid" to config.ssid,
                "passphrase" to (config.passphrase ?: ""),
            )
        }

        @Suppress("DEPRECATION")
        val legacy = res.wifiConfiguration
        return mapOf(
            "ssid" to legacy?.SSID,
            "passphrase" to (legacy?.preSharedKey ?: ""),
        )
    }

    private fun describeFailure(reason: Int): String = when (reason) {
        WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL ->
            "No Wi-Fi channel is free for a hotspot right now"
        WifiManager.LocalOnlyHotspotCallback.ERROR_GENERIC ->
            "Android refused to start the hotspot"
        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE ->
            "The Wi-Fi hardware cannot host while it is doing something else"
        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED ->
            "Hotspot creation is disallowed on this device, often by policy"
        else -> "Hotspot failed to start (code $reason)"
    }

    private fun stopHotspot(result: MethodChannel.Result) {
        reservation?.close()
        reservation = null
        result.success(null)
    }

    /** Called when the engine goes away, so a hotspot never outlives the app. */
    fun dispose() {
        reservation?.close()
        reservation = null
    }
}
