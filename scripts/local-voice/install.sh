#!/bin/bash
# Installs DeskPet's local voice (server.py): a Python environment with mlx-audio (PyPI through the Tsinghua mirror),
# Qwen3-TTS 1.7B Base (6-bit, through the ModelScope mirror, or cloned from an existing copy) and a reference voice.
# DeskPet starts the service itself while its cloud voice points to 127.0.0.1:8790; nothing is added to the login
# items. Apple Silicon only. Run again to update or to add a voice.
#
# Usage: scripts/local-voice/install.sh <ref.wav> "<what ref.wav says>" [voice name, default "default"] [existing model dir]
set -euo pipefail
cd "$(dirname "$0")"
REF=$1; REF_TEXT=$2; VOICE=${3:-default}; EXISTING=${4:-}
HOME_DIR="$HOME/Library/Application Support/DeskPet/local-voice"
MODEL_REPO=mlx-community/Qwen3-TTS-12Hz-1.7B-Base-6bit
MODEL_DIR="$HOME_DIR/models/Qwen3-TTS-12Hz-1.7B-Base-6bit"
INDEX=${UV_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}

[ "$(uname -m)" = arm64 ] || { echo "The local voice needs Apple Silicon (MLX)."; exit 1; }
command -v uv >/dev/null || { echo "uv is missing: brew install uv"; exit 1; }
mkdir -p "$HOME_DIR/models" "$HOME_DIR/voices/$VOICE"

# Python environment.
[ -x "$HOME_DIR/.venv/bin/python" ] || uv venv --python 3.12 "$HOME_DIR/.venv"
uv pip install --python "$HOME_DIR/.venv/bin/python" --index-url "$INDEX" mlx-audio soundfile soxr
cp server.py "$HOME_DIR/server.py"

# The model: a clone of an existing copy (no extra space on APFS), otherwise from ModelScope, resuming partial files.
if [ ! -f "$MODEL_DIR/config.json" ]; then
    if [ -n "$EXISTING" ] && [ -f "$EXISTING/config.json" ]; then
        cp -cR "$EXISTING" "$MODEL_DIR"
    else
        mkdir -p "$MODEL_DIR"
        curl -s -m 30 "https://www.modelscope.cn/api/v1/models/$MODEL_REPO/repo/files?Recursive=true" | python3 -c "
import json, sys
for f in json.load(sys.stdin)['Data']['Files']:
    if f['Type'] == 'blob': print(f['Path'] + '\t' + str(f['Size']))" | while IFS=$'\t' read -r path size; do
            out="$MODEL_DIR/$path"; mkdir -p "$(dirname "$out")"
            [ -f "$out" ] && [ "$(stat -f %z "$out")" = "$size" ] && continue
            echo "  $path"
            curl -s -L --retry 5 -C - -o "$out" "https://www.modelscope.cn/models/$MODEL_REPO/resolve/master/$path"
        done
    fi
fi

# The voice.
cp "$REF" "$HOME_DIR/voices/$VOICE/ref.wav"
printf '%s\n' "$REF_TEXT" > "$HOME_DIR/voices/$VOICE/ref.txt"
[ -f "$HOME_DIR/voices/default/ref.wav" ] || cp -R "$HOME_DIR/voices/$VOICE/." "$HOME_DIR/voices/default/"

echo "Installed in $HOME_DIR."
echo "In DeskPet: Settings → General → Voice → voice source: cloud → Presets → 本机千问 (voice \"$VOICE\")."
