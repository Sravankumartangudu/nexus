#!/bin/bash
# Packages Nexus into dist/Nexus-<version>.dmg, a drag-to-Applications installer.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Nexus.app/Contents/Info.plist)
DMG="dist/Nexus-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R Nexus.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'TXT'
Installing Nexus

1. Drag Nexus onto the Applications folder.
2. Open Nexus from Applications. Nexus isn't notarized by Apple, so if macOS says it can't be
   verified, go to System Settings > Privacy & Security, scroll down, click "Open Anyway", and
   confirm. You only need to do this once.
3. Nexus runs in the menu bar (no Dock icon). Click its icon for the fleet list and
   "Open Dashboard…" for the full window.
4. (Optional) Turn on Voice Control from the menu to listen for the wake word "Nexus" and run
   spoken commands. Allow Microphone and Speech Recognition when asked.
5. (Optional) Turn on "Launch Nexus at Login" so it's always watching your fleet.

Full guide: https://github.com/Sravankumartangudu/nexus/blob/main/README.md
TXT

mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname "Nexus" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
echo "Packaged $(pwd)/$DMG"
