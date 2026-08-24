package com.follow.clash

import android.content.Intent
import android.os.Bundle
import com.follow.clash.common.GlobalState
import com.follow.clash.common.QuickAction
import com.follow.clash.common.action
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity(),
    CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    private var pendingInvisibleQuickStart = false

    private val quickStartBackgroundFallback = Runnable {
        if (pendingInvisibleQuickStart) {
            backgroundPendingQuickStart()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingInvisibleQuickStart = intent?.action == QuickAction.START.action
        if (pendingInvisibleQuickStart) {
            updateWindowVisibility(false)
        }
        super.onCreate(savedInstanceState)
        if (pendingInvisibleQuickStart) {
            updateWindowVisibility(false)
        }
        captureQuickStart(intent)
        if (pendingInvisibleQuickStart) {
            window.decorView.postDelayed(quickStartBackgroundFallback, 10_000L)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action != QuickAction.START.action) {
            State.clearPendingQuickStart()
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

    private fun captureQuickStart(intent: Intent?) {
        if (intent?.action == QuickAction.START.action) {
            State.markPendingQuickStart()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AppPlugin())
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        State.flutterEngine = flutterEngine
    }

    override fun onDestroy() {
        window.decorView.removeCallbacks(quickStartBackgroundFallback)
        GlobalState.launch {
            Service.setEventListener(null)
        }
        State.flutterEngine = null
        super.onDestroy()
    }
}
