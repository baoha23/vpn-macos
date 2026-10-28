package com.gpsvpn.mocker

import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL

internal data class ApiLocation(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Double,
    val altitudeMeters: Double?,
    val source: String,
    val capturedAt: String
)

internal object ApiClient {
    private const val TAG = "GPSVPNApiClient"

    fun fetchLocation(endpoint: String, token: String): ApiLocation {
        val url = URL(endpoint)
        val connection = url.openConnection() as HttpURLConnection

        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 5_000
            connection.readTimeout = 10_000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Authorization", "Bearer $token")

            val code = connection.responseCode
            if (code !in 200..299) {
                val errorBody = connection.errorStream?.bufferedReader()?.use(BufferedReader::readText).orEmpty()
                throw IllegalStateException("Location API returned $code: $errorBody")
            }

            val body = connection.inputStream.bufferedReader().use(BufferedReader::readText)
            return parseLocation(body)
        } catch (error: Exception) {
            Log.w(TAG, "Location fetch failed", error)
            throw error
        } finally {
            connection.disconnect()
        }
    }

    internal fun parseLocation(body: String): ApiLocation {
        val json = JSONObject(body)
        val latitude = json.getDouble("latitude")
        val longitude = json.getDouble("longitude")
        require(latitude in -90.0..90.0) { "Invalid latitude" }
        require(longitude in -180.0..180.0) { "Invalid longitude" }
        return ApiLocation(
            latitude = latitude,
            longitude = longitude,
            accuracyMeters = json.optDouble("accuracyMeters", 100.0),
            altitudeMeters = if (json.isNull("altitudeMeters")) null else json.optDouble("altitudeMeters"),
            source = json.optString("source", "unknown"),
            capturedAt = json.optString("capturedAt", "")
        )
    }
}
