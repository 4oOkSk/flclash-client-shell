package com.follow.clash

import android.content.Intent
import android.os.Bundle
import com.follow.clash.common.QuickAction
import com.follow.clash.common.action
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var pendingInvisibleQuickStart = false

    private val quickStartBackgroundFallback = Runnable {
        if (pendingInvisibleQuickStart) {
            backgroundPendingQuickStart()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        captureQuickStart(intent)
        if (pendingInvisibleQuickStart) {
            updateWindowVisibility(false)
        }
        super.onCreate(savedInstanceState)
        if (pendingInvisibleQuickStart) {
            updateWindowVisibility(false)
            window.decorView.postDelayed(quickStartBackgroundFallback, 10_000L)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action != QuickAction.START.action) {
            ServiceState.cancelPendingFlutterStart()
            restoreQuickStartWindow()
        }
        setIntent(intent)
        captureQuickStart(intent)
    }

    fun backgroundPendingQuickStart(): Boolean {
        if (!pendingInvisibleQuickStart) {
            return false
        }
        val moved = moveTaskToBack(true)
        if (!moved) {
            restoreQuickStartWindow()
        }
        return moved
    }

    private fun captureQuickStart(intent: Intent?) {
        pendingInvisibleQuickStart =
            intent?.action == QuickAction.START.action &&
            ServiceState.prepareFlutterBootstrapStart()
    }

    private fun updateWindowVisibility(visible: Boolean) {
        window.attributes = window.attributes.apply {
            alpha = if (visible) 1f else 0f
        }
    }

    private fun restoreQuickStartWindow() {
        if (!pendingInvisibleQuickStart) {
            return
        }
        pendingInvisibleQuickStart = false
        window.decorView.removeCallbacks(quickStartBackgroundFallback)
        updateWindowVisibility(true)
    }

    override fun onStop() {
        restoreQuickStartWindow()
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AppPlugin())
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        ServiceState.attachFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        window.decorView.removeCallbacks(quickStartBackgroundFallback)
        flutterEngine?.let(ServiceState::detachFlutterEngine)
        super.onDestroy()
    }
}
