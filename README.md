# GPS VPN Location

This repository contains two components:

- `macos/`: a macOS menu-bar agent that serves the Mac's location over a token-protected local HTTP API.
- `android/`: an Android mock-location app that consumes that API and reports the Mac's location to the device.

Android network traffic is routed through Tailscale with the Mac selected as an Exit Node, so services see the Mac's public IP. The mock-location app makes location-aware apps see the Mac's coordinates.

See `docs/SETUP.md` for build and deployment instructions.
