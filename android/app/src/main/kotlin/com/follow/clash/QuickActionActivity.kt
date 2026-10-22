package com.follow.clash

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.core.content.pm.ShortcutManagerCompat
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.common.QuickAction
import com.follow.clash.common.action
import com.follow.clash.common.intent
import kotlinx.coroutines.launch

class QuickActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.action) {
            QuickAction.START.action -> startOrBootstrap()
            QuickAction.STOP.action -> GlobalState.launch { ServiceState.handleStopAction() }
            QuickAction.TOGGLE.action -> {
                ShortcutManagerCompat.reportShortcutUsed(this, SHORTCUT_ID)
                if (ServiceState.prepareFlutterBootstrapStart()) {
                    launchFlutterBootstrap()
                } else {
                    GlobalState.launch { ServiceState.handleToggleAction() }
                }
            }
        }
        finish()
    }

    private fun startOrBootstrap() {
        if (ServiceState.prepareFlutterBootstrapStart()) {
            launchFlutterBootstrap()
        } else {
            GlobalState.launch { ServiceState.handleStartAction() }
        }
    }

    private fun launchFlutterBootstrap() {
        runCatching {
            startActivity(
                Components.mainActivity.intent.apply {
                    action = QuickAction.START.action
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                },
            )
        }.onFailure {
            ServiceState.cancelPendingFlutterStart()
        }
    }

    private companion object {
        const val SHORTCUT_ID = "toggle"
    }
}
