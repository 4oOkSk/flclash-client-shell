package com.follow.clash.plugins

import com.follow.clash.ServiceController
import com.follow.clash.ServiceState
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.models.SharedState
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.util.concurrent.ConcurrentHashMap

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var scope: CoroutineScope
    private val gson = Gson()
    private val starts = ConcurrentHashMap<Long, ServiceState.RunRequest>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        channel = MethodChannel(binding.binaryMessenger, "${Components.PACKAGE_NAME}/service")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
        starts.clear()
        ServiceController.setEventListener(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> initialize(result)
            "shutdown" -> shutdown(result)
            "invokeMethod" -> invokeMethod(call, result)
            "getRunTime" -> getRunTime(result)
            "syncState" -> syncState(call, result)
            "start" -> start(call, result)
            "cancelStart" -> cancelStart(call, result)
            "stop" -> stop(result)
            "getDiagnosticLogs" -> result.success(GlobalState.getDiagnosticLogs())
            else -> result.notImplemented()
        }
    }

    private fun initialize(result: MethodChannel.Result) {
        ServiceController.setEventListener(::sendEvent)
            .onSuccess { result.success("") }
            .onFailure { error -> result.success(error.message.orEmpty()) }
    }

    private fun shutdown(result: MethodChannel.Result) {
        val operation = ServiceState.requestStop()
        scope.launch {
            if (!operation.await()) {
                result.success(false)
                return@launch
            }
            ServiceController.unbind()
            result.success(true)
        }
    }

    private fun invokeMethod(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments as? String
        if (data == null) {
            result.error("INVALID_ARGUMENT", "Method call payload must be a string", null)
            return
        }
        scope.launch {
            ServiceController.invokeMethod(data) { response ->
                result.success(response)
            }.onFailure { error ->
                result.error("CORE_ERROR", error.message, null)
            }
        }
    }

    private fun getRunTime(result: MethodChannel.Result) {
        scope.launch {
            result.success(ServiceState.refresh())
        }
    }

    private fun syncState(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments as? String
        val state = runCatching {
            gson.fromJson(data, SharedState::class.java)
        }.getOrNull()
        if (state == null) {
            result.success("Invalid shared state")
            return
        }
        scope.launch {
            ServiceState.syncSharedState(state)
            result.success("")
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val requestId = call.argument<Number>("requestId")?.toLong()
        if (requestId == null) {
            result.error("INVALID_ARGUMENT", "Start request identity is required", null)
            return
        }
        val (token, operation) = ServiceState.requestStartWithToken()
        starts[requestId] = token
        result.success(true)
        scope.launch {
            val started = runCatching { withTimeout(75_000) { operation.await() } }
                .onFailure { ServiceState.cancelStart(token) }.getOrDefault(false)
            launch(Dispatchers.Main) {
                channel.invokeMethod("startCompleted", mapOf(
                    "requestId" to requestId,
                    "started" to started,
                ), object : MethodChannel.Result {
                    override fun success(result: Any?) { starts.remove(requestId, token) }
                    override fun error(code: String, message: String?, details: Any?) {
                        ServiceState.cancelStart(token)
                        starts.remove(requestId, token)
                    }
                    override fun notImplemented() {
                        ServiceState.cancelStart(token)
                        starts.remove(requestId, token)
                    }
                })
            }
        }
    }

    private fun cancelStart(call: MethodCall, result: MethodChannel.Result) {
        val requestId = call.argument<Number>("requestId")?.toLong()
        val token = requestId?.let(starts::remove)
        if (token == null) {
            result.success(false)
            return
        }
        val operation = ServiceState.cancelStart(token)
        scope.launch { result.success(operation.await()) }
    }

    private fun stop(result: MethodChannel.Result) {
        val operation = ServiceState.requestStop()
        scope.launch {
            result.success(operation.await())
        }
    }

    private fun sendEvent(value: String?) {
        scope.launch(Dispatchers.Main) {
            channel.invokeMethod("event", value)
        }
    }
}
