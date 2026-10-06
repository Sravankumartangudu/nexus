#!/bin/bash
# Builds Nexus.app next to this script. Pass --universal for an Apple Silicon + Intel build.
set -euo pipefail
cd "$(dirname "$0")"

APP="Nexus.app"
ARCHS="$(uname -m)"
[[ "${1:-}" == "--universal" ]] && ARCHS="arm64 x86_64"

# Regenerate the icon if it's missing.
[[ -f Icon/AppIcon.icns ]] || swift Icon/make_icon.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SRC="main.swift Fleet.swift Voice.swift beacon/NexusBeacon.swift"
BINS=()
for arch in $ARCHS; do
  swiftc -O -target "$arch-apple-macos13.0" \
    -framework AppKit -framework WebKit -framework ServiceManagement \
    -framework AVFoundation -framework Speech \
    $SRC -o "$APP/Contents/MacOS/Nexus-$arch"
  BINS+=("$APP/Contents/MacOS/Nexus-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Nexus"
rm "${BINS[@]}"

cp dashboard.html orb.html "$APP/Contents/Resources/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nexus</string>
  <key>CFBundleDisplayName</key><string>Nexus</string>
  <key>CFBundleIdentifier</key><string>com.stangudu.nexus</string>
  <key>CFBundleExecutable</key><string>Nexus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Nexus listens for its wake word and your spoken commands to control your agents.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Nexus transcribes your spoken commands, on-device when supported.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the microphone / speech permission grant sticks to a stable identity.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
