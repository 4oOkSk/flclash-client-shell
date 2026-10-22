package com.follow.clash.service.models

import org.junit.Assert.assertEquals
import org.junit.Test

class TrafficTest {
    @Test
    fun notificationSpeedUsesProxyCounters() {
        val requested = mutableListOf<Boolean>()
        val text = getSpeedTrafficText { onlyProxy ->
            requested.add(onlyProxy)
            if (onlyProxy) {
                """{"up":128,"down":256}"""
            } else {
                """{"up":8192,"down":16384}"""
            }
        }

        assertEquals(listOf(true), requested)
        assertEquals("128B/s↑  256B/s↓", text)
    }
}
