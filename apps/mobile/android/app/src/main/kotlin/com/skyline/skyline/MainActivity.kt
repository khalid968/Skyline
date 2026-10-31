package com.skyline.skyline

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity: the biometric prompt (app lock, local_auth) needs
// a FragmentActivity host.
class MainActivity : FlutterFragmentActivity() {
    private val ringer by lazy { Ringer(applicationContext) }

    // Decline on the phone's call screen opens the app (the patched
    // flutter_callkit_incoming, third_party/.../SKYLINE-PATCH.md), because only
    // the app can send the encrypted decline. The call's id waits here until
    // Dart takes it. If Skyline was not on screen, it goes back once done.
    private var launch: MethodChannel? = null
    private var declinedId: String? = null
    private var backAfterDecline = false
    private var onScreen = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Not when Android recreates the activity or it is reopened from
        // recent apps: that intent's decline was handled long ago.
        val fromHistory = intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory) takeDecline(intent, back = true)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (takeDecline(intent, back = !onScreen)) launch?.invokeMethod("declined", null)
    }

    override fun onStart() {
        super.onStart()
        onScreen = true
    }

    override fun onStop() {
        onScreen = false
        super.onStop()
    }

    private fun takeDecline(intent: Intent?, back: Boolean): Boolean {
        if (intent?.action?.endsWith("com.hiennv.flutter_callkit_incoming.ACTION_CALL_DECLINE") != true) return false
        @Suppress("DEPRECATION")
        val data = intent.getBundleExtra("EXTRA_CALLKIT_CALL_DATA")
        val id = data?.getString("EXTRA_CALLKIT_ID") ?: return false
        declinedId = id
        backAfterDecline = backAfterDecline || back
        return true
    }

    override fun onDestroy() {
        ringer.stop()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        launch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "skyline/launch").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeDeclined" -> { result.success(declinedId); declinedId = null }
                    "declineHandled" -> {
                        if (backAfterDecline) moveTaskToBack(true)
                        backAfterDecline = false
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // An incoming call while the app is open (see Ringer).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "skyline/ringer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> { ringer.start(); result.success(true) }
                    "stop" -> { ringer.stop(); result.success(true) }
                    else -> result.notImplemented()
                }
            }
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
        // Screen sharing in a call: the foreground service Android requires
        // while the screen is captured (see ScreenShareService).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "skyline/screen_share")
            .setMethodCallHandler { call, result ->
                val intent = Intent(this, ScreenShareService::class.java)
                when (call.method) {
                    "start" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
