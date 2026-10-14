#!/bin/bash
# Runs both providers against a local mock of the streaming APIs; the literature tools call the live
# arXiv and Semantic Scholar APIs (network required).
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
WORK="$(mktemp -d)"
PORT="${PORT:-8799}"
python3 Tests/mock_server.py "$PORT" "$WORK" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
    Sources/Core/*.swift Sources/LLM/*.swift Tests/Integration/main.swift -o "$WORK/integration"
MOCK_URL="http://127.0.0.1:$PORT" MOCK_LOG="$WORK/requests.jsonl" DESKPET_DIR="$WORK" "$WORK/integration"
