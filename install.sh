#!/bin/bash
set -euo pipefail

RELEASE_URL="https://github.com/nobody-as/Dictation/releases/latest/download"
ARCH="$(uname -m)"
ARCHIVE="Dictation-macos-$ARCH.zip"
SUPPORT_DIR="$HOME/Library/Application Support/MacLocalDictation"
VENV="$SUPPORT_DIR/venv"

fail() { echo "Dictation install: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "This installer runs on macOS only."
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || fail "This Mac processor is not supported."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "macOS 13 or newer is required."
command -v curl >/dev/null || fail "curl is required."

tmp_dir="$(mktemp -d)"
staging_dir=""
restore_and_clean() {
    if [[ -n "$staging_dir" && -d "$staging_dir/previous.app" && ! -e "$application_dir/Dictation.app" ]]; then
        mv "$staging_dir/previous.app" "$application_dir/Dictation.app"
    fi
    [[ -z "$staging_dir" ]] || rm -rf "$staging_dir"
    rm -rf "$tmp_dir"
}
trap restore_and_clean EXIT

echo "Downloading the prebuilt Dictation app…"
curl -fLsS --retry 3 "$RELEASE_URL/$ARCHIVE" -o "$tmp_dir/$ARCHIVE" || fail "Could not download the latest Mac release."
curl -fLsS --retry 3 "$RELEASE_URL/$ARCHIVE.sha256" -o "$tmp_dir/$ARCHIVE.sha256" || fail "Could not download its checksum."
expected="$(awk 'NR == 1 {print $1}' "$tmp_dir/$ARCHIVE.sha256")"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || fail "Release checksum is invalid."
actual="$(shasum -a 256 "$tmp_dir/$ARCHIVE" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || fail "Release download failed checksum verification."
ditto -x -k "$tmp_dir/$ARCHIVE" "$tmp_dir/unpacked"
source_app="$tmp_dir/unpacked/Dictation.app"
[[ -x "$source_app/Contents/MacOS/Dictation" ]] || fail "The release does not contain a Dictation app."
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
[[ "$bundle_id" == com.macdictation.ui ]] || fail "The downloaded app has the wrong bundle identifier."
codesign --verify --deep --strict "$source_app" || fail "The downloaded app failed code signature verification."

mkdir -p "$SUPPORT_DIR"
if command -v uv >/dev/null 2>&1; then
    uv_bin="$(command -v uv)"
else
    echo "Installing the Python setup tool…"
    mkdir -p "$SUPPORT_DIR/bin"
    curl -fLsS --retry 3 https://astral.sh/uv/install.sh -o "$tmp_dir/uv-install.sh" || fail "Could not download the Python setup tool."
    UV_INSTALL_DIR="$SUPPORT_DIR/bin" sh "$tmp_dir/uv-install.sh"
    uv_bin="$SUPPORT_DIR/bin/uv"
fi
[[ -x "$uv_bin" ]] || fail "The Python setup tool did not install."

echo "Setting up the local speech engine (this may take several minutes)…"
"$uv_bin" python install 3.12
"$uv_bin" venv --python 3.12 "$VENV"
if [[ "$ARCH" == arm64 ]]; then
    "$uv_bin" pip install --only-binary :all: --python "$VENV/bin/python3" \
        'mlx-whisper==0.4.3' 'speechbrain==1.1.1' 'torch' 'torchaudio' 'soundfile'
else
    "$uv_bin" pip install --only-binary :all: --python "$VENV/bin/python3" 'faster-whisper==1.2.1'
fi

if [[ -w /Applications ]]; then
    application_dir=/Applications
else
    application_dir="$HOME/Applications"
    mkdir -p "$application_dir"
fi
destination="$application_dir/Dictation.app"
if [[ -e "$destination" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$existing_id" == com.macdictation.ui ]] || fail "$destination belongs to a different app."
    osascript -e 'tell application id "com.macdictation.ui" to quit' >/dev/null 2>&1 || true
fi

staging_dir="$(mktemp -d "$application_dir/.dictation-install.XXXXXX")"
ditto "$source_app" "$staging_dir/Dictation.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging_dir/previous.app"
fi
mv "$staging_dir/Dictation.app" "$destination"

echo "Installed $destination"
echo "The speech model downloads on first launch. Grant microphone and accessibility access when prompted."
open "$destination"
