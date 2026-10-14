#!/bin/bash
# Compiles and runs the self-test of the platform-independent logic (Sources/Core, Sources/LLM)
# and of the memory bank store.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d)/deskpet-selftest"
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
    Sources/Core/*.swift Sources/LLM/*.swift Sources/App/MemoryStore.swift Tests/main.swift -o "$OUT"
DESKPET_DIR="$(mktemp -d)" "$OUT"
