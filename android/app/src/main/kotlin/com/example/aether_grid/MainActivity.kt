package com.example.aether_grid

import android.os.Environment
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aether_grid/export")
            .setMethodCallHandler { call, result ->
                if (call.method == "getExportDirectory") {
                    val directory = getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS)
                        ?: filesDir
                    if (!directory.exists()) directory.mkdirs()
                    result.success(directory.absolutePath)
                } else {
                    result.notImplemented()
                }
            }
    }
}
