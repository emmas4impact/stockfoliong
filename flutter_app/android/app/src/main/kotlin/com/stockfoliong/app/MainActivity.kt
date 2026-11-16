package com.stockfoliong.app

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val vault = BiometricVault(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "stockfolio/biometric_session")
            .setMethodCallHandler(vault::handle)
    }
}
