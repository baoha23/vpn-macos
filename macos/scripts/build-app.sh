#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/GPSVPNAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "Info.plist" "$APP/Contents/Info.plist"
cp ".build/release/GPSVPNAgent" "$APP/Contents/MacOS/GPSVPNAgent"
codesign --force --sign - "$APP"

echo "Created $APP"
