# StarShade for macOS

A lightweight post-processing shader overlay for macOS games. Captures a target game window using ScreenCaptureKit, applies Metal fragment shaders in real-time, and composites the result in a transparent overlay window.

Built for Apple Silicon Macs running macOS 14.0+.

## Features

- **Real-time shader effects** — CAS sharpening, LUT color grading, and custom effects at 60 FPS
- **Hot-swappable shaders** — Switch shaders with hotkeys, no restart needed
- **ReShade preset conversion** — Drop `.txt` ReShade presets and they auto-convert to Metal
- **Menu bar app** — Runs as a lightweight status bar icon (no Dock clutter)
- **Global hotkeys** — Control everything with Ctrl+Shift shortcuts, even while the game has focus
- **Auto-detection** — Finds the game window automatically and tracks it as it moves/resizes

## Quick Start

```bash
# Build
./build.sh

# Launch
open "StarShade.app"
```

On first launch, macOS will prompt for **Screen Recording** permission. Grant it in System Settings → Privacy & Security → Screen Recording.

## Hotkeys

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+Q` | Emergency Quit |
| `Ctrl+Shift+R` | Toggle overlay on/off |
| `Ctrl+Shift+[` | Previous shader |
| `Ctrl+Shift+]` | Next shader |
| `Ctrl+Shift+Up` | Increase sharpness |
| `Ctrl+Shift+Down` | Decrease sharpness |
| `Ctrl+Shift+L` | Reload shaders from disk |

## Shaders

Built-in shaders are copied to `~/Library/Application Support/StarShade/Shaders/` on first launch.
These shaders were inspired by popular ReShade custom creations. Feel free to modify or add your own!

| Shader | Description |
|---|---|
| `cas.metal` | AMD FidelityFX Contrast Adaptive Sharpening |
| `lut.metal` | Color grading via lookup table |
| `passthrough.metal` | No-op (useful for testing) |
| `flowergarden.metal` | Warm color grading preset |
| `perdue.metal` | Cool/cinematic color grading preset |
|        |             |
|        |       

### Adding Custom Shaders

Drop `.txt` shader preset files into the shaders directory:

```
~/Library/Application Support/StarShade/Shaders/
```

Press `Ctrl+Shift+L` to reload shaders without restarting. Or click reload shaders from the app icon in your task bar.

They are automatically parsed and converted to Metal shaders at load time.

## Persistent Permissions

By default, macOS Screen Recording permission resets every time you rebuild (ad-hoc signing). To make it persist:

```bash
# One-time: create a self-signed code signing certificate
./setup-signing.sh

# Rebuild with stable identity
./build.sh
```

After this, permission persists across rebuilds.

## Configuration

```bash
# Target a different game window - I placed in Applications for easy access, but you can put it anywhere
/Applications/StarShade.app/Contents/MacOS/StarShade --window "Google Chrome"

# Use a specific bundle ID
/Applications/StarShade.app/Contents/MacOS/StarShade  --bundle "com.game.app"

# Start with a specific shader
/Applications/StarShade.app/Contents/MacOS/StarShade  --shader lut

# Custom frame rate
/Applications/StarShade.app/Contents/MacOS/StarShade  --fps 30
```

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (arm64)
- Swift 5.9+ (included with Xcode 15+)
- Screen Recording permission

## Architecture

```
main.swift              — App delegate, overlay controller, capture engine, Metal renderer
PresetConverter.swift   — ReShade .txt preset → Metal shader converter
Shaders/                — Built-in Metal fragment shaders
build.sh                — Build script (compile, bundle, sign)
setup-signing.sh        — Self-signed certificate for persistent permissions
Info.plist              — App bundle metadata
```

## License

MIT
