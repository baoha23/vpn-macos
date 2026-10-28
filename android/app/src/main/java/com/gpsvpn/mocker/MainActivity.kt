package com.gpsvpn.mocker

import android.Manifest
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    AppScreen()
                }
            }
        }
    }
}

@Composable
private fun AppScreen() {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("gps_vpn_mock", Context.MODE_PRIVATE) }
    var endpoint by remember { mutableStateOf(prefs.getString("endpoint", "").orEmpty()) }
    var token by remember { mutableStateOf(prefs.getString("token", "").orEmpty()) }
    var intervalSeconds by remember { mutableStateOf(prefs.getInt("intervalSeconds", 30).toString()) }
    val serviceRunning by MockLocationService.running.collectAsState()
    val serviceStatus by MockLocationService.status.collectAsState()
    val serviceError by MockLocationService.error.collectAsState()

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        if (grants[Manifest.permission.ACCESS_FINE_LOCATION] == true) {
            startMockService(context)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text(text = "GPSVPN Mocker", style = MaterialTheme.typography.headlineSmall)
        Text(text = serviceStatus, style = MaterialTheme.typography.bodyMedium)

        serviceError?.let { message ->
            Text(text = message, color = MaterialTheme.colorScheme.error)
        }

        OutlinedTextField(
            value = endpoint,
            onValueChange = { endpoint = it },
            label = { Text("Tailscale Mac URL") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )

        OutlinedTextField(
            value = token,
            onValueChange = { token = it },
            label = { Text("API token") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )

        OutlinedTextField(
            value = intervalSeconds,
            onValueChange = { intervalSeconds = it.filter(Char::isDigit) },
            label = { Text("Update interval (seconds)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = {
                prefs.edit()
                    .putString("endpoint", endpoint.trim())
                    .putString("token", token.trim())
                    .putInt("intervalSeconds", intervalSeconds.toIntOrNull() ?: 30)
                    .apply()

                val permissions = requiredPermissions()
                if (permissions.all { ContextCompat.checkSelfPermission(context, it) == android.content.pm.PackageManager.PERMISSION_GRANTED }) {
                    startMockService(context)
                } else {
                    permissionLauncher.launch(permissions)
                }
            },
            enabled = !serviceRunning,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Start")
        }

        OutlinedButton(
            onClick = {
                context.startService(
                    Intent(context, MockLocationService::class.java).setAction(MockLocationService.ACTION_STOP)
                )
            },
            enabled = serviceRunning,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Stop")
        }

        Text(
            text = "In Developer options, choose this app as the mock location app. Install and connect Tailscale before starting.",
            style = MaterialTheme.typography.bodySmall
        )
    }
}

private fun startMockService(context: Context) {
    val intent = Intent(context, MockLocationService::class.java).setAction(MockLocationService.ACTION_START)
    context.startForegroundService(intent)
}

private fun requiredPermissions(): Array<String> {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.POST_NOTIFICATIONS
        )
    } else {
        arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
    }
}
