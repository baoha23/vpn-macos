package com.gpsvpn.mocker

import org.junit.Assert.assertEquals
import org.junit.Test

class ApiClientTest {
    @Test
    fun parsesLocationResponse() {
        val location = ApiClient.parseLocation(
            """
            {
              "latitude": 10.123456,
              "longitude": 106.654321,
              "accuracyMeters": 42.0,
              "altitudeMeters": null,
              "source": "core_location",
              "capturedAt": "2026-01-01T00:00:00Z"
            }
            """.trimIndent()
        )

        assertEquals(10.123456, location.latitude, 0.0)
        assertEquals(106.654321, location.longitude, 0.0)
        assertEquals(42.0, location.accuracyMeters, 0.0)
        assertEquals(null, location.altitudeMeters)
        assertEquals("core_location", location.source)
    }
}
