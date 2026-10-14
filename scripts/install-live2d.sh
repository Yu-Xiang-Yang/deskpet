#!/bin/bash
# Installs the Live2D Cubism Core and the Tororo / Hijiki sample models into DeskPet's model folder,
# together with the motion maps from Resources/model-maps.
#
# Both downloads come from live2d.com and require accepting Live2D's terms there; they are not part of
# this repository and must not be redistributed (see README.md, "Live2D").
#
# Usage: scripts/install-live2d.sh <Cubism SDK for Web: zip or folder> [<Tororo & Hijiki: zip or folder>]
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
    echo "Usage: $0 <CubismSdkForWeb zip/folder> [<tororo_hijiki zip/folder>]" >&2
    exit 1
fi

DEST="${DESKPET_DIR:-$HOME/Library/Application Support/DeskPet}/models"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DEST"

# A folder is used as is; a zip is extracted into its own empty directory (nothing from it is executed).
unpack() {
    local source="$1" name="$2"
    if [ -d "$source" ]; then
        echo "$source"
    elif [ -f "$source" ]; then
        mkdir -p "$WORK/$name"
        ditto -x -k "$source" "$WORK/$name"
        echo "$WORK/$name"
    else
        echo "Not found: $source" >&2
        exit 1
    fi
}

# Cubism Core
SDK="$(unpack "$1" sdk)"
CORE="$(find "$SDK" -type f -name live2dcubismcore.min.js -not -path "*/__MACOSX/*" | head -1)"
if [ -z "$CORE" ]; then
    echo "live2dcubismcore.min.js was not found in $1" >&2
    exit 1
fi
cp "$CORE" "$DEST/live2dcubismcore.min.js"
echo "Installed Cubism Core"

# Sample models (runtime files only) and their motion maps
if [ $# -ge 2 ]; then
    MODELS="$(unpack "$2" models)"
    for pair in "tororo:Tororo" "hijiki:Hijiki"; do
        file="${pair%%:*}.model3.json"; name="${pair#*:}"
        settings="$(find "$MODELS" -type f -name "$file" -not -path "*/__MACOSX/*" | head -1)"
        if [ -z "$settings" ]; then
            echo "Skipped $name: $file was not found" >&2
            continue
        fi
        mkdir -p "$DEST/$name"
        cp -R "$(dirname "$settings")/." "$DEST/$name/"
        cp "Resources/model-maps/$name/pet-map.json" "$DEST/$name/pet-map.json"
        echo "Installed $name"
    done
fi

echo "Done: $DEST"
echo "Restart DeskPet and choose the model under Settings → General → Character."
