package com.follow.clash

import android.app.Activity
import android.os.Bundle
import com.follow.clash.common.QuickAction
import com.follow.clash.common.action
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class TempActivity : Activity(),
    CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.action) {
            QuickAction.START.action -> {
                if (State.flutterEngine == null && State.runStateFlow.value == RunState.STOP) {
                    State.launchClientForPendingStart()
                } else {
                    launch {
                        State.handleStartServiceAction()
                    }
                }
            }

            QuickAction.STOP.action -> {
                launch {
                    State.handleStopServiceAction()
                }
            }

            QuickAction.TOGGLE.action -> {
                if (State.flutterEngine == null && State.runStateFlow.value == RunState.STOP) {
                    State.launchClientForPendingStart()
                } else {
                    launch {
                        State.handleToggleAction()
                    }
                }
            }
        }
        finish()
    }
}
