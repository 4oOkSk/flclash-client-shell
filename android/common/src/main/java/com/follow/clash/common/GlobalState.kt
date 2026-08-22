package com.follow.clash.common


import android.app.Application
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

object GlobalState : CoroutineScope by CoroutineScope(Dispatchers.Default) {

    private const val DIAGNOSTIC_LOG_LIMIT = 200

    private val diagnosticLogs = ArrayDeque<String>()

    const val NOTIFICATION_CHANNEL = "HarborProxy"

    const val NOTIFICATION_ID = 1

    val packageName: String
        get() = application.packageName

    val RECEIVE_BROADCASTS_PERMISSIONS: String
        get() = "${packageName}.permission.RECEIVE_BROADCASTS"


    private var _application: Application? = null

    val application: Application
        get() = _application!!


    fun log(text: String) {
        Log.d("[HarborProxy]", text)
        synchronized(diagnosticLogs) {
            while (diagnosticLogs.size >= DIAGNOSTIC_LOG_LIMIT) {
                diagnosticLogs.removeFirst()
            }
            diagnosticLogs.addLast("${System.currentTimeMillis()} $text")
        }
    }

    fun getDiagnosticLogs(): String {
        return synchronized(diagnosticLogs) {
            diagnosticLogs.joinToString("\n")
        }
    }

    fun init(application: Application) {
        _application = application
    }
}
