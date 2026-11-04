package com.directdrop.app

import android.os.StatFs
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * How much room a volume has, for the receiver to check before it starts.
 *
 * `StatFs.availableBytes` is the figure an app can actually use — it leaves
 * out the blocks the filesystem reserves for the system — which is the right
 * one to compare a transfer against. The destination may not exist yet (the
 * receiver creates folders as files arrive), so the question is asked about
 * the nearest ancestor that does.
 *
 * A failure is reported as an error, never as a number: the Dart side treats
 * that as "unknown" and says so in the log, instead of proceeding as though a
 * check had passed.
 */
class DiskSpacePlugin : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "availableBytes" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("BAD_ARGS", "path required", null)
                    return
                }
                try {
                    result.success(availableBytes(path))
                } catch (e: Exception) {
                    result.error("UNAVAILABLE", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun availableBytes(path: String): Long {
        var directory: File? = File(path)
        while (directory != null && !directory.exists()) {
            directory = directory.parentFile
        }
        val existing = directory
            ?: throw IllegalArgumentException("no existing folder above $path")
        return StatFs(existing.path).availableBytes
    }
}
