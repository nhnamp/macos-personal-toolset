#!/bin/bash
# Draws the app icon and writes Resources/Toolset/AppIcon.icns.
# Run it after a change of Sources/ToolsetApp/ToolsetGlyph.swift or Icon/make_icon/main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -O Icon/make_icon/main.swift Sources/ToolsetApp/ToolsetGlyph.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/Toolset/AppIcon.icns
echo "Wrote Resources/Toolset/AppIcon.icns"
