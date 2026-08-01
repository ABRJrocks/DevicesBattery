#!/bin/bash
# Build release and package as a menu bar .app in /Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="/Applications/DevicesBattery.app"
pkill -f "$APP" 2>/dev/null || true
sleep 1  # let LaunchServices notice the old instance is gone (avoids open error -600)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DevicesBattery "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.devices-battery</string>
    <key>CFBundleName</key><string>DevicesBattery</string>
    <key>CFBundleExecutable</key><string>DevicesBattery</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Reads nearby AirPods battery levels from their Bluetooth broadcasts.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Installed $APP — launching."
open "$APP"
