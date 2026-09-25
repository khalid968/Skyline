package com.skyline.skyline

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity: the biometric prompt (app lock, local_auth) needs
// a FragmentActivity host.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // View-once media (board 24): while it is on screen, the window is
        // secure: no screenshots, no screen recording, blank in the app switcher.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "skyline/screen")
            .setMethodCallHandler { call, result ->
                if (call.method == "protect") {
                    if (call.arguments as? Boolean == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }
    }
}
