package com.directdrop.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
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

    private val mainHandler = Handler(Looper.getMainLooper())
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    /// The join currently in flight, so a retry can withdraw it rather than
    /// stack another system dialog on top of it.
    private var joinCallback: ConnectivityManager.NetworkCallback? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startHotspot" -> startHotspot(result)
            "stopHotspot" -> stopHotspot(result)
            "joinHotspot" -> joinHotspot(call, result)
            "leaveHotspot" -> leaveHotspot(result)
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
        leaveHotspot(result)
    }

    private fun leaveHotspot(result: MethodChannel.Result) {
        joinCallback?.let {
            val connectivity = context.applicationContext
                .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            try {
                connectivity.unregisterNetworkCallback(it)
                connectivity.bindProcessToNetwork(null)
            } catch (_: IllegalArgumentException) {
                // Already gone.
            }
        }
        joinCallback = null
        result.success(null)
    }

    private fun joinHotspot(call: MethodCall, result: MethodChannel.Result) {
        val ssid = call.argument<String>("ssid")
        if (ssid.isNullOrEmpty()) {
            result.error("BAD_ARGS", "joinHotspot needs an ssid", null)
            return
        }
        val passphrase = call.argument<String>("passphrase") ?: ""
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            joinWithSpecifier(ssid, passphrase, result)
        } else {
            joinLegacy(ssid, passphrase, result)
        }
    }

    /**
     * Joins a network the other device raised.
     *
     * WifiNetworkSpecifier is the only way in since Android 10, and it shows
     * a system dialog with the matching network — one tap the person makes,
     * because the OS does not trust an app to move the device between
     * networks on its own. The dialog is answered by the callback, so the
     * Dart side gets its result when the join actually happened, not when it
     * was asked for.
     *
     * The process is bound to the network on arrival: a local-only hotspot
     * has no internet, and without the binding Android routes around it —
     * the exact failure that made this look like "connected, but the
     * transfer cannot start".
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun joinWithSpecifier(
        ssid: String,
        passphrase: String,
        result: MethodChannel.Result,
    ) {
        // The permission changed names in 33; either way an app joining a
        // specific network has to hold it, and a bare SecurityException is
        // the reward for not checking first.
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            result.error(
                "PERMISSION_DENIED",
                "Joining a Wi-Fi network needs the nearby-devices permission",
                null,
            )
            return
        }

        val connectivity = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        // A retry replaces the request rather than queueing behind it: the
        // dialog it raises is modal in practice, and two of them is one
        // confusion too many.
        joinCallback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: IllegalArgumentException) {
                // Already gone.
            }
        }

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()
        // The hotspot carries no internet, and it must still satisfy the
        // request — without this removal Android matches only networks it
        // would route the web over.
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        var answered = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val bound = connectivity.bindProcessToNetwork(network)
                if (!answered) {
                    answered = true
                    if (bound) {
                        result.success(null)
                    } else {
                        result.error(
                            "BIND_FAILED",
                            "Could not bind process to the hotspot network",
                            null,
                        )
                    }
                }
            }

            override fun onUnavailable() {
                if (!answered) {
                    answered = true
                    result.error(
                        "JOIN_FAILED",
                        "The network was not found, or the join was declined",
                        null,
                    )
                }
            }
        }
        joinCallback = callback

        try {
            connectivity.requestNetwork(request, callback, mainHandler)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: RuntimeException) {
            result.error("JOIN_FAILED", e.message, null)
        }
    }

    /** The pre-10 way: describe the network and ask to be moved to it. */
    @Suppress("DEPRECATION")
    private fun joinLegacy(
        ssid: String,
        passphrase: String,
        result: MethodChannel.Result,
    ) {
        if (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            result.error(
                "PERMISSION_DENIED",
                "Joining a Wi-Fi network needs the location permission",
                null,
            )
            return
        }
        val wifiManager =
            context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val config = WifiConfiguration()
        config.SSID = "\"$ssid\""
        config.preSharedKey = "\"$passphrase\""
        val networkId = wifiManager.addNetwork(config)
        if (networkId < 0) {
            result.error("JOIN_FAILED", "Android refused the network configuration", null)
            return
        }
        wifiManager.disconnect()
        val moved = wifiManager.enableNetwork(networkId, true)
        wifiManager.reconnect()
        if (moved) {
            result.success(null)
        } else {
            result.error("JOIN_FAILED", "Android would not move to the network", null)
        }
    }

    /** Called when the engine goes away, so a hotspot never outlives the app. */
    fun dispose() {
        reservation?.close()
        reservation = null
        joinCallback?.let {
            val connectivity = context.applicationContext
                .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            try {
                connectivity.unregisterNetworkCallback(it)
                connectivity.bindProcessToNetwork(null)
            } catch (_: IllegalArgumentException) {
                // Already gone.
            }
        }
        joinCallback = null
    }
}
