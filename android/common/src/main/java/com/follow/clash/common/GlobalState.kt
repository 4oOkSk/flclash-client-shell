package com.follow.clash.common

import android.app.Application
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

object GlobalState : CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    private const val DIAGNOSTIC_LOG_LIMIT = 200
    private val diagnosticLogs = ArrayDeque<String>()

    const val NOTIFICATION_CHANNEL = "HarborProxy"
    const val NOTIFICATION_ID = 1

    val packageName: String
        get() = application.packageName

    val receiveBroadcastPermission: String
        get() = "$packageName.permission.RECEIVE_BROADCASTS"

    val application: Application
        get() = checkNotNull(appInstance) { "GlobalState is not initialized" }

    @Volatile
    private var appInstance: Application? = null

    fun init(application: Application) {
        appInstance = application
    }

    fun log(text: String) {
        Log.d("HarborProxy", text)
        synchronized(diagnosticLogs) {
            while (diagnosticLogs.size >= DIAGNOSTIC_LOG_LIMIT) {
                diagnosticLogs.removeFirst()
            }
            diagnosticLogs.addLast(text.take(1024))
        }
    }

    fun getDiagnosticLogs(): String = synchronized(diagnosticLogs) {
        diagnosticLogs.joinToString("\n")
    }

    fun didCrashOnPreviousExecution(): Boolean = false
}
