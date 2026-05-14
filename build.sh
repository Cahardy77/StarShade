#!/bin/bash
# Build StarShade — Post-processing shader overlay for macOS games
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/StarShade.app"
BINARY_NAME="StarShade"
SHADERS_DIR="$SCRIPT_DIR/Shaders"

echo "Building StarShade..."

# Compile with Swift
swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    -framework Cocoa \
    -framework Metal \
    -framework MetalKit \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework IOSurface \
    -framework CoreImage \
    -framework QuartzCore \
    -o "$SCRIPT_DIR/$BINARY_NAME" \
    "$SCRIPT_DIR/main.swift" \
    "$SCRIPT_DIR/PresetConverter.swift"

# Create .app bundle
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Shaders"

cp "$SCRIPT_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Embed shader files in bundle (these get copied to user dir on first run)
if [ -d "$SHADERS_DIR" ]; then
    SHADER_COUNT=$(ls -1 "$SHADERS_DIR"/*.metal 2>/dev/null | wc -l | tr -d ' ')
    cp "$SHADERS_DIR"/*.metal "$APP_BUNDLE/Contents/Resources/Shaders/"
    echo "📦 Embedded $SHADER_COUNT shader(s) in app bundle"
else
    echo "⚠️  No Shaders/ directory found — app will start with no shaders"
fi

# Sign the bundle — prefer a stable identity so Screen Recording permission persists across rebuilds
CERT_NAME="StarShade Dev"
SIGNING_IDENTITY=""

# Look for our self-signed cert first
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    SIGNING_IDENTITY="$CERT_NAME"
fi

# Fall back to any Apple Development cert (from Xcode)
if [ -z "$SIGNING_IDENTITY" ]; then
    DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Apple Development|Developer ID Application|Mac Developer" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [ -n "$DEV_IDENTITY" ]; then
        SIGNING_IDENTITY="$DEV_IDENTITY"
    fi
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "🔐 Signing with: $SIGNING_IDENTITY"
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
    echo "   ✅ Stable identity — Screen Recording permission persists across rebuilds"
else
    echo "🔐 Using ad-hoc signing (no stable certificate found)"
    codesign --force --deep --sign - "$APP_BUNDLE"
    echo ""
    echo "⚠️  Ad-hoc signing means Screen Recording permission resets on each rebuild."
    echo "   To fix this, run:  ./setup-signing.sh"
    echo "   This creates a self-signed certificate for persistent permissions."
fi

# Clean up loose binary
rm -f "$SCRIPT_DIR/$BINARY_NAME"

echo ""
echo "✅ Built: $APP_BUNDLE"
echo ""
echo "Usage:"
echo "  # Double-click or run:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "  # Or run with options:"
echo "  \"$APP_BUNDLE/Contents/MacOS/$BINARY_NAME\" --shader cas"
echo "  \"$APP_BUNDLE/Contents/MacOS/$BINARY_NAME\" --window \"SSOClient\" --fps 60"
echo ""
echo "Shaders:"
echo "  Built-in shaders are copied to ~/Library/Application Support/StarShade/Shaders/"
echo "  on first launch. Add new shaders at any time:"
echo "    .metal files  — Custom Metal shaders (fragment functions)"
echo "    .txt files    — ReShade preset files (auto-converted to Metal)"
echo "  Use Ctrl+Shift+L to reload shaders without restarting."
echo ""
echo "Hotkeys:"
echo "  Ctrl+Shift+Q   Emergency Quit"
echo "  Ctrl+Shift+R   Toggle overlay on/off"
echo "  Ctrl+Shift+[   Previous shader"
echo "  Ctrl+Shift+]   Next shader"
echo "  Ctrl+Shift+↑   Increase sharpness"
echo "  Ctrl+Shift+↓   Decrease sharpness"
echo "  Ctrl+Shift+L   Reload shaders from disk"
echo ""
echo "Permissions:"
echo "  On first run, macOS will prompt for Screen Recording permission."
echo "  Grant it in System Settings → Privacy & Security → Screen Recording."
echo ""
echo "  If permission keeps re-prompting after rebuilds, run:"
echo "    ./setup-signing.sh    # One-time: creates a stable signing certificate"
echo "    ./build.sh            # Rebuild with stable identity"
echo "    tccutil reset ScreenCapture com.starshade.app  # Clear stale permission"
