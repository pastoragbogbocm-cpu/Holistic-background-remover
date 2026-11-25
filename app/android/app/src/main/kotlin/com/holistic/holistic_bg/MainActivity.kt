package com.holistic.holistic_bg

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Launch arguments (video / background picture paths) for on-device tests.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "holistic/launch").setMethodCallHandler { call, result ->
            if (call.method == "args") {
                val video = intent?.getStringExtra("video")
                result.success(if (video == null) null else mapOf("video" to video, "image" to intent?.getStringExtra("image")))
            } else result.notImplemented()
        }
    }
}
