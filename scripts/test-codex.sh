#!/bin/bash
# Uses only the Command Line Tools; no Xcode/XCTest installation required.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/VibeIsland/CodexTranscript.swift Sources/VibeIsland/ProcessCapture.swift \
    Tests/VibeIslandTests/CodexWatcherTests.swift -o "$TEST_DIR/test-codex"
"$TEST_DIR/test-codex"
