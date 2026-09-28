#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:?Usage: scripts/package_app.sh OUTPUT_DIR [VERSION] [arm64|x86_64]}"
VERSION="${2:-2.2}"
ARCH="${3:-$(uname -m)}"
APP="$OUTPUT_DIR/Dictation.app"

if [[ "$(uname -s)" != Darwin || ( "$ARCH" != arm64 && "$ARCH" != x86_64 ) ]]; then
    echo "Packaging requires macOS and an arm64 or x86_64 target." >&2
    exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Backend"
cp "$ROOT/Backend/server.py" "$APP/Contents/Resources/Backend/server.py"
cp "$ROOT/Backend/server_intel.py" "$APP/Contents/Resources/Backend/server_intel.py"

sources=(DictationApp.swift MenuView.swift FloatingDictationView.swift QuickDictation.swift AudioRecorder.swift HotkeyManager.swift NoteFormatter.swift)
if [[ -f "$ROOT/UI/ShortcutRecorderView.swift" ]]; then
    sources+=(ShortcutRecorderView.swift)
fi
for i in "${!sources[@]}"; do
    sources[$i]="$ROOT/UI/${sources[$i]}"
done

swiftc "${sources[@]}" \
    -o "$APP/Contents/MacOS/Dictation" \
    -target "$ARCH-apple-macosx13.0" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework Carbon \
    -framework FoundationModels

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.macdictation.ui</string>
<key>CFBundleName</key><string>Dictation</string>
<key>CFBundleExecutable</key><string>Dictation</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Dictation needs microphone access to transcribe your voice locally.</string>
</dict></plist>
EOF

codesign --force --deep --entitlements "$ROOT/UI/entitlements.plist" --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
