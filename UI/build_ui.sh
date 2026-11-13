#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_NAME="Dictation"
BUNDLE_ID="com.macdictation.ui"

echo "Building SwiftUI MenuBar App..."

mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"
cp -R ../Backend "$APP_NAME.app/Contents/Resources/"

swiftc DictationApp.swift MenuView.swift FloatingDictationView.swift QuickDictation.swift PasteDelivery.swift AudioRecorder.swift DictationSessionQueue.swift HotkeyManager.swift NoteFormatter.swift \
    -o "$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    -target arm64-apple-macosx13.0 \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework Carbon \
    -framework FoundationModels

cat <<EOF > "$APP_NAME.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>2.2</string>
    <key>CFBundleShortVersionString</key>
    <string>2.2</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Dictation requires microphone access to record audio for speech transcription.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Dictation converts your voice to text using local on-device models.</string>
</dict>
</plist>
EOF

cat <<EOF > entitlements.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF

echo "Signing app bundle with entitlements..."
SIGNING_IDENTITY=$(security find-identity -p codesigning -v | grep -o 'Apple Development: [^"]*' | head -n 1 || true)
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing with Developer Identity: $SIGNING_IDENTITY"
    codesign --force --options runtime --entitlements entitlements.plist --sign "$SIGNING_IDENTITY" "$APP_NAME.app/Contents/MacOS/$APP_NAME"
    codesign --force --deep --options runtime --entitlements entitlements.plist --sign "$SIGNING_IDENTITY" "$APP_NAME.app"
else
    echo "Signing ad-hoc..."
    codesign --force --entitlements entitlements.plist --sign - "$APP_NAME.app/Contents/MacOS/$APP_NAME"
    codesign --force --deep --entitlements entitlements.plist --sign - "$APP_NAME.app"
fi

echo "Installing to /Applications/$APP_NAME.app..."
# Gracefully kill running instance before copying
pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" || true
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" || true
sleep 1

rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_NAME.app" "/Applications/"

echo "Build complete. Launching /Applications/$APP_NAME.app..."
open "/Applications/$APP_NAME.app"
