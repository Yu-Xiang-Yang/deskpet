#!/bin/bash
# Removes DeskPet's local voice: its environment, model and voices (DeskPet stops the service when it quits).
set -euo pipefail
pkill -f "DeskPet/local-voice/server.py" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/DeskPet/local-voice"
echo "Removed the local voice."
