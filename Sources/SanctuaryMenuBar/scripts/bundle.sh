#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_NAME="SanctuaryMenuBar"
APP_BUNDLE="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LAUNCH_DAEMONS_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
EXECUTABLE="$ROOT_DIR/.build/release/$APP_NAME"
DAEMON_EXECUTABLE="$ROOT_DIR/.build/release/sanctuaryd"
DAEMON_LABEL="ai.hardener.sanctuary.daemon"
DAEMON_DEST="$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL"
DAEMON_PLIST="$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist"
ENTITLEMENTS="$ROOT_DIR/Sources/SanctuaryMenuBar/scripts/SanctuaryMenuBar.entitlements"

cd "$ROOT_DIR"

swift build -c release --product "$APP_NAME"
swift build -c release --product sanctuaryd

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$LAUNCH_DAEMONS_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod 0755 "$MACOS_DIR/$APP_NAME"
cp "$DAEMON_EXECUTABLE" "$DAEMON_DEST"
chmod 0755 "$DAEMON_DEST"

APP_BUNDLE_ABSOLUTE="$(cd "$ROOT_DIR/dist" && pwd)/${APP_NAME}.app"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SanctuaryMenuBar</string>
    <key>CFBundleIdentifier</key>
    <string>ai.hardener.sanctuary.menubar</string>
    <key>CFBundleName</key>
    <string>Sanctuary</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$DAEMON_LABEL</string>
    <key>Program</key>
    <string>$APP_BUNDLE_ABSOLUTE/Contents/Library/LaunchDaemons/$DAEMON_LABEL</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/sanctuaryd.err.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/sanctuaryd.out.log</string>
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    developer_id="$(security find-identity -p codesigning -v 2>/dev/null | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
    if [[ -n "$developer_id" ]]; then
        echo "Signing with Developer ID Application: $developer_id"
        codesign --force --sign "$developer_id" --options runtime --entitlements "$ENTITLEMENTS" "$DAEMON_DEST" >/dev/null
        codesign --force --sign "$developer_id" --options runtime --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
    else
        echo "Warning: no Developer ID Application identity found; using ad-hoc signing."
        echo "Production SMAppService install flow requires a Developer ID signed app."
        codesign --force --sign - "$DAEMON_DEST" >/dev/null
        codesign --force --sign - "$APP_BUNDLE" >/dev/null
    fi
fi

echo "Built $APP_BUNDLE"
