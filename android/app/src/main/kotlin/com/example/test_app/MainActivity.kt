package com.example.test_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "holiday_resort/version_cache")
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences("holiday_resort_versions", MODE_PRIVATE)
                val key = call.argument<String>("key")
                if (key == null) { result.error("invalid-key", "Missing key", null); return@setMethodCallHandler }
                when (call.method) {
                    "read" -> result.success(prefs.getString(key, null))
                    "write" -> { prefs.edit().putString(key, call.argument<String>("value")).apply(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }
}