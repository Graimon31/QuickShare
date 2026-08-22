package com.directdrop.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var hotspotPlugin: HotspotPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val plugin = HotspotPlugin(applicationContext)
        hotspotPlugin = plugin
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quickshare/hotspot")
            .setMethodCallHandler(plugin)
    }

    override fun onDestroy() {
        // A local-only hotspot outliving the screen that created it would keep
        // the Wi-Fi radio in AP mode with nobody watching.
        hotspotPlugin?.dispose()
        hotspotPlugin = null
        super.onDestroy()
    }
}
