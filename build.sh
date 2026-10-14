#!/bin/bash
# Builds DeskPet.app into ./build (requires the Xcode Command Line Tools).
# Usage: ./build.sh            build only (ARCHS="arm64 x86_64" for a universal binary, VERSION=1.2.3)
#        ./build.sh install    build and copy the app to /Applications (or ~/Applications)
set -euo pipefail

cd "$(dirname "$0")"
APP="build/DeskPet.app"

# Prefer the macOS 26 SDK of the Command Line Tools when present, otherwise the default SDK.
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"

# Front-end libraries (pinned, checksum-verified).
[ -f Resources/web/vendor/marked.min.js ] || scripts/fetch-vendor.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS="${ARCHS:-$(uname -m)}"
VERSION="${VERSION:-$( (git describe --tags --abbrev=0 2>/dev/null || echo v0.1.0) | sed 's/^v//')}"
SLICES=()
for arch in $ARCHS; do
    swiftc -O -swift-version 5 \
        -sdk "$SDK" \
        -target "$arch-apple-macos14.0" \
        Sources/Core/*.swift Sources/LLM/*.swift Sources/App/*.swift \
        -o "$APP/Contents/MacOS/DeskPet-$arch"
    SLICES+=("$APP/Contents/MacOS/DeskPet-$arch")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/DeskPet"
rm -f "${SLICES[@]}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.yu-xiang-yang.deskpet</string>
    <key>CFBundleName</key><string>DeskPet</string>
    <key>CFBundleDisplayName</key><string>DeskPet</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleExecutable</key><string>DeskPet</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>桌宠通过分析正在播放的声音找出节拍，跟着音乐摇摆。声音只在本机实时分析，不会录制或保存。 DeskPet analyses the sound being played to find the beat and sway along; nothing is recorded or stored.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Web front end, bundled models and the icon.
cp -R Resources/web "$APP/Contents/Resources/web"
mkdir -p "$APP/Contents/Resources/models"
find Resources/models -mindepth 1 -maxdepth 1 -type d -exec cp -R {} "$APP/Contents/Resources/models/" \;
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for entry in "en:DeskPet" "zh-Hans:桌宠"; do
    lang="${entry%%:*}"; name="${entry#*:}"
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$name" "$name" \
        > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

if [ ! -f Resources/web/vendor/live2dcubismcore.min.js ]; then
    echo "Note: the Live2D Cubism Core is not bundled; the app loads it from"
    echo "      ~/Library/Application Support/DeskPet/models/ (install it with scripts/install-live2d.sh, see README.md)."
fi

# A stable signing identity keeps the Keychain's "Always Allow" valid across rebuilds; an ad-hoc signature
# changes with every build, so macOS asks again for the stored API key. Create the identity once in
# Keychain Access (Certificate Assistant → Create a Certificate…, type "Code Signing"); see README.md.
IDENTITY="${SIGN_IDENTITY:-DeskPet Code Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP" && echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "Signed ad hoc (no \"$IDENTITY\" certificate; the Keychain will ask again after each rebuild)"
fi
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; fi
    mkdir -p "$DEST"
    pkill -f "$DEST/DeskPet.app/Contents/MacOS/DeskPet" 2>/dev/null || true
    rm -rf "$DEST/DeskPet.app"
    cp -R "$APP" "$DEST/"
    codesign --verify --deep --strict "$DEST/DeskPet.app" && echo "Signature verified"
    echo "Installed to $DEST/DeskPet.app"
fi
