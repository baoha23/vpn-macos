# Deployment Guide

## 1. Build and run the macOS agent

From `macos/`:

```bash
bash scripts/build-app.sh
open build/GPSVPNAgent.app
```

The first launch asks for location permission. The menu-bar icon shows location state and lets you copy the API token and URL.

The agent listens only on `127.0.0.1:8787`. Do not expose this port directly to a public network.

Requirements: macOS 13 or later and Swift 5.9 or later.

## 2. Publish the agent over Tailscale

On the Mac:

```bash
tailscale up --advertise-exit-node
tailscale serve --bg 8787
```

Approve the exit node in the Tailscale admin console. Note the HTTPS hostname printed by Tailscale Serve; it looks like:

```text
https://mac-name.tailnet-name.ts.net/v1/location
```

## 3. Configure Android

Build the Android app from `android/` with JDK 17 and Gradle 8.7 or later:

```bash
gradle assembleDebug testDebugUnitTest
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`.

1. Install Tailscale from Play Store.
2. Sign in to the same tailnet.
3. Select the Mac as the Exit Node.
4. Enable Tailscale DNS, Always-on VPN, and **Block connections without VPN**.
5. Install the Android app from `android/app/build/outputs/apk/debug/app-debug.apk`.
6. Enter the Mac's Tailscale URL, such as `https://mac-name.tailnet-name.ts.net`, and the API token.
7. Grant precise-location permission.
8. In **Developer options**, choose this app as the **Mock location app**.
9. Start the mock-location service.

## 4. Validate

- With Tailscale disabled, an IP lookup site should show the mobile/Wi-Fi ISP.
- With the Mac exit node enabled, an IP lookup site should show the Mac's public IP and network location.
- With the mock service running, Google Maps or another location-testing app should show the coordinates returned by the Mac agent.
- Stop the service or turn off mock-location mode before returning the phone to real GPS use.

To watch Android API calls on the Mac without logging tokens:

```bash
log stream --predicate 'subsystem == "local.gps-vpn.agent"' --info
```

## Security Notes

- The token is required on every location request.
- Tailscale Serve keeps the API private to your tailnet.
- The token is stored in `~/Library/Application Support/GPSVPNAgent/api-token` with `0600` permissions.
- If the token is compromised, delete that file, restart the agent, and update Android with the new token.
