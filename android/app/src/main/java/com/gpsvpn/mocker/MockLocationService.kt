package com.gpsvpn.mocker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Criteria
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow

class MockLocationService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var fetchJob: Job? = null
    private var injectJob: Job? = null
    @Volatile
    private var latestLocation: ApiLocation? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action ?: ACTION_START) {
            ACTION_START -> {
                startAsForeground()
                startWork()
                return START_STICKY
            }
            ACTION_STOP -> {
                stopMockLocation()
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running.value = false
        fetchJob = null
        injectJob = null
        latestLocation = null
        scope.cancel()
        super.onDestroy()
    }

    private fun startAsForeground() {
        ensureNotificationChannel()
        val notification = buildNotification("Starting location mock")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startWork() {
        val endpoint = prefs().getString("endpoint", "").orEmpty().trim()
        val token = prefs().getString("token", "").orEmpty().trim()
        val intervalSeconds = prefs().getInt("intervalSeconds", 30).coerceIn(5, 3600)

        if (endpoint.isBlank() || token.isBlank()) {
            error.value = "Endpoint and token are required"
            stopMockLocation()
            return
        }

        val normalizedEndpoint = if (endpoint.endsWith("/v1/location")) {
            endpoint
        } else {
            endpoint.trimEnd('/') + "/v1/location"
        }

        if (!normalizedEndpoint.startsWith("https://")) {
            error.value = "Endpoint must use HTTPS"
            stopMockLocation()
            return
        }

        if (running.value && fetchJob?.isActive == true) {
            return
        }

        running.value = true
        error.value = null
        status.value = "Connecting to macOS agent"
        setupMockProviders()

        fetchJob = scope.launch {
            while (isActive) {
                try {
                    val location = ApiClient.fetchLocation(normalizedEndpoint, token)
                    latestLocation = location
                    status.value = "Using ${location.source}: %.5f, %.5f".format(location.latitude, location.longitude)
                    error.value = null
                } catch (caught: Exception) {
                    error.value = caught.message ?: caught.javaClass.simpleName
                    status.value = "Location update failed"
                }
                delay(intervalSeconds * 1_000L)
            }
        }

        injectJob = scope.launch {
            while (isActive) {
                latestLocation?.let { location ->
                    injectLocation(location)
                }
                delay(1_000L)
            }
        }
    }

    private fun setupMockProviders() {
        try {
            providers().forEach { providerName ->
                addMockProvider(providerName)
            }
        } catch (caught: SecurityException) {
            error.value = "Select this app as the mock location app in Developer options"
            stopMockLocation()
        } catch (caught: Exception) {
            error.value = "Unable to initialize mock providers: ${caught.message}"
            stopMockLocation()
        }
    }

    private fun addMockProvider(providerName: String) {
        val manager = getSystemService(LocationManager::class.java)
        manager.addTestProvider(
            providerName,
            false,
            true,
            false,
            false,
            true,
            true,
            true,
            Criteria.POWER_LOW,
            Criteria.ACCURACY_FINE
        )
        manager.setTestProviderEnabled(providerName, true)
    }

    private fun injectLocation(apiLocation: ApiLocation) {
        providers().forEach { providerName ->
            try {
                val manager = getSystemService(LocationManager::class.java)
                val location = Location(providerName)
                location.latitude = apiLocation.latitude
                location.longitude = apiLocation.longitude
                location.accuracy = apiLocation.accuracyMeters.toFloat()
                location.altitude = apiLocation.altitudeMeters ?: 0.0
                location.bearing = 0f
                location.speed = 0f
                location.time = System.currentTimeMillis()
                location.elapsedRealtimeNanos = System.nanoTime()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    location.isMock = true
                }
                manager.setTestProviderLocation(providerName, location)
            } catch (caught: IllegalArgumentException) {
                try {
                    addMockProvider(providerName)
                } catch (_: Exception) {
                    error.value = "Mock provider $providerName is unavailable"
                }
            } catch (caught: SecurityException) {
                error.value = "Mock-location permission was revoked"
                stopMockLocation()
                return
            }
        }
    }

    private fun stopMockLocation() {
        fetchJob?.cancel()
        injectJob?.cancel()
        fetchJob = null
        injectJob = null
        latestLocation = null

        providers().forEach { providerName ->
            try {
                val manager = getSystemService(LocationManager::class.java)
                manager.removeTestProvider(providerName)
            } catch (_: Exception) {
            }
        }

        running.value = false
        status.value = "Mock location stopped"
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun providers(): List<String> {
        val values = mutableListOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            values.add(LocationManager.FUSED_PROVIDER)
        }
        return values
    }

    private fun prefs() = getSharedPreferences("gps_vpn_mock", MODE_PRIVATE)

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Mock location service",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("GPSVPN mock location")
            .setContentText(text)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_START = "com.gpsvpn.mocker.START"
        const val ACTION_STOP = "com.gpsvpn.mocker.STOP"
        private const val CHANNEL_ID = "mock_location"
        private const val NOTIFICATION_ID = 1

        val running = MutableStateFlow(false)
        val status = MutableStateFlow("Mock location stopped")
        val error = MutableStateFlow<String?>(null)
    }
}
