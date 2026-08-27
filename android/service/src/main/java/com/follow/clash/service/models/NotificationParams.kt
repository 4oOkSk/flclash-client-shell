package com.follow.clash.service.models

data class NotificationParams(
    val title: String = "HarborProxy",
    val stopText: String = "STOP",
    val onlyStatisticsProxy: Boolean = false,
)
