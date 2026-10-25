#!/bin/bash
# Builds build/Toolset.app and signs it.
#   ./build.sh             build only
#   ./build.sh --run       build, quit the running copy, and open the new one from build/
#   ./build.sh --install   build, quit the running copy, copy the app to /Applications, and open it from there
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Toolset.app

swift build -c release --product ToolsetApp
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ToolsetApp" "$APP/Contents/MacOS/Toolset"
cp Resources/Toolset/Info.plist "$APP/Contents/Info.plist"
cp Resources/Toolset/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM writes the deployment target (14.0) as the SDK version of the binary.
# macOS then runs the app in compatibility mode, with the old window design.
# Write the real SDK version, so the app gets the current design.
SDK_VERSION=$(xcrun --show-sdk-version)
vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/Toolset" "$APP/Contents/MacOS/Toolset"

# macOS ties the Accessibility permission to the code signature.
# The Apple Development identity gives the same signature on every build, so the permission stays.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "WARNING: No Apple Development identity found. The app gets an ad-hoc signature." >&2
    echo "WARNING: You must grant the Accessibility permission again after each build." >&2
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

case "${1:-}" in
    --run)
        pkill -x Toolset || true
        sleep 0.5
        open "$APP"
        ;;
    --install)
        INSTALLED="/Applications/Toolset.app"
        pkill -x Toolset || true
        sleep 0.5
        rm -rf "$INSTALLED"
        ditto "$APP" "$INSTALLED"
        open "$INSTALLED"
        echo "Installed $INSTALLED"
        ;;
esac
