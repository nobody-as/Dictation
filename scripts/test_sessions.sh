#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/dictation-session-tests.XXXXXX")"
swiftc "$ROOT/UI/AudioRecorder.swift" "$ROOT/UI/DictationSessionQueue.swift" "$ROOT/Tests/SessionTests.swift" \
    -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$ROOT/build/test-module-cache" -framework AVFoundation -o "$OUTPUT/SessionTests"
"$OUTPUT/SessionTests"
