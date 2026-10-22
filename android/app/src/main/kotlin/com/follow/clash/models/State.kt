package com.follow.clash.models

import com.follow.clash.service.models.VpnOptions
import com.google.gson.annotations.SerializedName
import com.google.gson.JsonObject

data class SharedState(
    val startTip: String = "Starting VPN...",
    val stopTip: String = "Stopping VPN...",
    val currentProfileName: String = "HarborProxy",
    val stopText: String = "Stop",
    val vpnOptions: VpnOptions? = null,
    val setupParams: SetupParams? = null,
)

data class SetupParams(
    @SerializedName("test-url")
    val testUrl: String,
    @SerializedName("selected-map")
    val selectedMap: Map<String, String>,
    @SerializedName("runtime-params")
    val runtimeParams: JsonObject? = null,
)
