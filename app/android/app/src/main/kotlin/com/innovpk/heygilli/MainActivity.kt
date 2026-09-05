package com.innovpk.heygilli

import android.app.ActivityManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Hosts Flutter and exposes best-effort screen pinning for kid mode.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "heygilli/lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startLockTask" -> result.success(tryStartLockTask())
                    "stopLockTask" -> {
                        tryStopLockTask()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // startLockTask pins silently only for a device owner; for everyone else
    // Android asks the user to confirm. Either way, never crash the kid screen.
    private fun tryStartLockTask(): Boolean {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (am.lockTaskModeState == ActivityManager.LOCK_TASK_MODE_NONE) {
                startLockTask()
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun tryStopLockTask() {
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE) {
                stopLockTask()
            }
        } catch (_: Exception) {
        }
    }
}
