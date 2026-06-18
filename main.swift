// StarShade — Dynamic Shader Loading
// Captures a target game window, applies Metal post-processing shaders,
// and composites the result in a transparent overlay window.
//
// Shaders: Drop .metal files into ~/Library/Application Support/StarShade/Shaders/
// Build: ./build.sh
// Run:   open "StarShade.app"

import Cocoa
import Metal
import MetalKit
import ScreenCaptureKit
import CoreImage
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Diagnostic File Logger

let diagLogPath = "/tmp/starshade_diag.log"

func diagLog(_ message: String) {
    print(message)
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    if FileManager.default.fileExists(atPath: diagLogPath) {
        if let handle = FileHandle(forWritingAtPath: diagLogPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        }
    } else {
        try? line.write(toFile: diagLogPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Configuration

struct OverlayConfig {
    var targetWindowTitle: String = "SSOClient"
    var targetBundleId: String = "com.starstable.client"
    var shaderName: String = "cas"
    var captureFrameRate: Double = 60.0
    var showStats: Bool = true
}

// MARK: - Shader Manager

struct ShaderInfo {
    let id: String           // filename without extension (e.g. "cas")
    let name: String         // from // Name: header (e.g. "CAS Sharpening")
    let description: String  // from // Description: header
    let source: String       // raw .metal file content (fragment only)
    let needsParams: Bool    // true if source contains [[buffer(0)]]
    let filePath: URL        // path to the .metal file on disk
}

class ShaderManager {
    static let appSupportName = "StarShade"
    static let shadersDirName = "Shaders"

    private(set) var shaders: [ShaderInfo] = []
    private(set) var shaderIDs: [String] = []

    /// Common vertex shader + structs prepended to every fragment shader
    let vertexPrefix = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct ShaderParams {
        float sharpness;
        float texelWidth;
        float texelHeight;
        float pad;
    };

    vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
        VertexOut out;
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.texCoord = float2(
            (positions[vertexID].x + 1.0) * 0.5,
            1.0 - (positions[vertexID].y + 1.0) * 0.5
        );
        return out;
    }

    """

    /// User shader directory: ~/Library/Application Support/StarShade/Shaders/
    var userShadersDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(Self.appSupportName).appendingPathComponent(Self.shadersDirName)
    }

    /// Bundle shader directory: .app/Contents/Resources/Shaders/
    var bundleShadersDir: URL? {
        guard let resourcePath = Bundle.main.resourceURL else { return nil }
        let dir = resourcePath.appendingPathComponent(Self.shadersDirName)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    init() {
        ensureUserShadersDir()
        copyBundledShadersIfNeeded()
        loadShaders()
    }

    /// Create the user shaders directory if it doesn't exist
    private func ensureUserShadersDir() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: userShadersDir.path) {
            do {
                try fm.createDirectory(at: userShadersDir, withIntermediateDirectories: true)
                print("📁 Created shader directory: \(userShadersDir.path)")
            } catch {
                print("⚠️  Could not create shader directory: \(error.localizedDescription)")
            }
        }
    }

    /// Copy bundled shaders to user directory (only if they don't already exist)
    private func copyBundledShadersIfNeeded() {
        guard let bundleDir = bundleShadersDir else { return }
        let fm = FileManager.default

        do {
            let files = try fm.contentsOfDirectory(at: bundleDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "metal" {
                let dest = userShadersDir.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: file, to: dest)
                    print("📋 Copied bundled shader: \(file.lastPathComponent)")
                }
            }
        } catch {
            print("⚠️  Could not copy bundled shaders: \(error.localizedDescription)")
        }
    }

    /// Scan user shaders directory and load all .metal and .txt (preset) files
    func loadShaders() {
        shaders = []
        shaderIDs = []

        let fm = FileManager.default
        do {
            let allFiles = try fm.contentsOfDirectory(at: userShadersDir, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

            let metalFiles = allFiles.filter { $0.pathExtension == "metal" }
            let presetFiles = allFiles.filter { $0.pathExtension == "txt" }

            // Load .metal shader files
            for file in metalFiles {
                if let info = parseShaderFile(file) {
                    shaders.append(info)
                    shaderIDs.append(info.id)
                    print("🎨 Loaded shader: \(info.name) [\(info.id)] — \(info.description)")
                }
            }

            // Convert and load .txt preset files (ReShade format)
            for file in presetFiles {
                if let info = convertPresetFile(file) {
                    shaders.append(info)
                    shaderIDs.append(info.id)
                    print("🎨 Converted preset: \(info.name) [\(info.id)] — \(info.description)")
                }
            }
        } catch {
            print("⚠️  Could not read shader directory: \(error.localizedDescription)")
        }

        if shaders.isEmpty {
            print("⚠️  No shaders found! Add .metal or .txt files to: \(userShadersDir.path)")
        } else {
            print("✅ Loaded \(shaders.count) shader(s)")
        }
    }

    /// Parse a .metal file into a ShaderInfo
    private func parseShaderFile(_ url: URL) -> ShaderInfo? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("⚠️  Could not read: \(url.lastPathComponent)")
            return nil
        }

        let id = url.deletingPathExtension().lastPathComponent.lowercased()
        var name = id.capitalized
        var description = ""

        // Parse // Name: and // Description: headers
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("// Name:") {
                name = String(trimmed.dropFirst("// Name:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("// Description:") {
                description = String(trimmed.dropFirst("// Description:".count)).trimmingCharacters(in: .whitespaces)
            }
            // Stop parsing headers after hitting actual code
            if !trimmed.isEmpty && !trimmed.hasPrefix("//") {
                break
            }
        }

        let needsParams = content.contains("[[buffer(0)]]")

        return ShaderInfo(
            id: id,
            name: name,
            description: description,
            source: content,
            needsParams: needsParams,
            filePath: url
        )
    }

    /// Convert a .txt preset file (ReShade format) into a ShaderInfo
    private func convertPresetFile(_ url: URL) -> ShaderInfo? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("⚠️  Could not read preset: \(url.lastPathComponent)")
            return nil
        }

        let fileName = url.lastPathComponent
        let id = url.deletingPathExtension().lastPathComponent.lowercased()

        print("🔄 Converting preset: \(fileName)")
        let parsed = PresetConverter.parsePreset(content: content, fileName: fileName)
        let converted = PresetConverter.convert(preset: parsed)

        return ShaderInfo(
            id: id,
            name: converted.displayName,
            description: converted.description,
            source: converted.metalSource,
            needsParams: converted.needsParams,
            filePath: url
        )
    }

    /// Get full compilable Metal source for a shader (vertex prefix + fragment)
    func compilableSource(for shaderID: String) -> String? {
        guard let info = shaders.first(where: { $0.id == shaderID }) else { return nil }
        return vertexPrefix + info.source
    }

    /// Get shader info by ID
    func shader(for id: String) -> ShaderInfo? {
        return shaders.first(where: { $0.id == id })
    }

    /// Reload shaders from disk (call when user adds new shaders)
    func reload() {
        print("\n🔄 Reloading shaders...")
        loadShaders()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayController: OverlayController?
    var statusBarController: StatusBarController?
    var config = OverlayConfig()
    var shaderManager: ShaderManager!

    var hasShownPermissionAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArgs()

        // Write diagnostic log — readable at /tmp/starshade_diag.log even when launched via open
        try? "".write(toFile: diagLogPath, atomically: true, encoding: .utf8)  // truncate
        diagLog("=== StarShade Launch ===")
        diagLog("Bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
        diagLog("Path: \(Bundle.main.bundlePath)")
        diagLog("PID: \(ProcessInfo.processInfo.processIdentifier)")
        diagLog("Screen Recording: \(CGPreflightScreenCaptureAccess())")
        diagLog("Accessibility: \(AXIsProcessTrusted())")

        // Activate app so permission dialogs display properly when launched via Finder/open
        NSApp.activate(ignoringOtherApps: true)

        // Pre-flight Screen Recording permission check
        if !CGPreflightScreenCaptureAccess() {
            print("⚠️  Screen Recording permission not granted for this app")
            print("   Requesting access...")
            CGRequestScreenCaptureAccess()

            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = """
            StarShade needs Screen Recording access to capture the game window and apply shader effects.

            Please grant access in:
            System Settings → Privacy & Security → Screen Recording

            After enabling, relaunch the app.

            Tip: If the app is already listed but not working, toggle it off and on, or remove and re-add it.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Quit")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            case .alertThirdButtonReturn:
                NSApp.terminate(nil)
                return
            default:
                break
            }
            // Suppress the secondary permission alert — user is already aware
            hasShownPermissionAlert = true
        } else {
            print("✅ Screen Recording permission verified")
        }

        shaderManager = ShaderManager()

        print("StarShade")
        print("  Target: \(config.targetWindowTitle) (\(config.targetBundleId))")
        print("  Shader: \(config.shaderName)")
        print("  FPS:    \(Int(config.captureFrameRate))")
        print("  Shaders dir: \(shaderManager.userShadersDir.path)")
        print("")
        print("Hotkeys:")
        print("  Ctrl+Shift+Q   EMERGENCY QUIT (always works)")
        print("  Ctrl+Shift+R   Toggle overlay on/off")
        print("  Ctrl+Shift+[   Previous shader")
        print("  Ctrl+Shift+]   Next shader")
        print("  Ctrl+Shift+↑   Increase sharpness")
        print("  Ctrl+Shift+↓   Decrease sharpness")
        print("  Ctrl+Shift+L   Reload shaders from disk")
        print("")

        // If requested shader doesn't exist, fall back to first available
        if shaderManager.shader(for: config.shaderName) == nil && !shaderManager.shaderIDs.isEmpty {
            config.shaderName = shaderManager.shaderIDs[0]
            print("⚠️  Requested shader not found, using: \(config.shaderName)")
        }

        overlayController = OverlayController(config: config, shaderManager: shaderManager)
        statusBarController = StatusBarController(overlayController: overlayController!, shaderManager: shaderManager)
        overlayController?.statusBar = statusBarController
        overlayController?.start()

        // Check Accessibility permission (required for global hotkeys)
        // Use the system's own prompt — it creates the correct TCC entry
        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if AXIsProcessTrustedWithOptions(axOpts) {
            print("✅ Accessibility permission granted (global hotkeys enabled)")
        } else {
            print("⚠️  Accessibility not yet granted — global hotkeys disabled")
            print("   Grant in: System Settings → Privacy & Security → Accessibility")
            print("   Toggle ON 'StarShade', then hotkeys will work immediately.")
            print("   Menu bar controls (🎨 icon) always work regardless.")
        }

        setupGlobalHotkeys()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController?.stop()
    }

    private func parseArgs() {
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--window":
                i += 1; if i < args.count { config.targetWindowTitle = args[i] }
            case "--bundle":
                i += 1; if i < args.count { config.targetBundleId = args[i] }
            case "--shader":
                i += 1; if i < args.count { config.shaderName = args[i] }
            case "--fps":
                i += 1; if i < args.count { config.captureFrameRate = Double(args[i]) ?? 60.0 }
            case "--no-stats":
                config.showStats = false
            case "--help":
                print("Usage: StarShade [options]")
                print("  --window <name>   Window title substring (default: SSOClient)")
                print("  --bundle <id>     Bundle ID (default: com.starstable.client)")
                print("  --shader <name>   Shader filename without .metal (default: cas)")
                print("  --fps <rate>      Capture frame rate (default: 60)")
                print("  --no-stats        Hide FPS overlay")
                print("")
                print("Add shaders by dropping .metal files into:")
                print("  ~/Library/Application Support/StarShade/Shaders/")
                exit(0)
            default: break
            }
            i += 1
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private func setupGlobalHotkeys() {
        // Use CGEventTap — intercepts keyboard events at the system level BEFORE
        // they reach any application. This works even when games consume keyboard input.
        // Requires Accessibility permission (already checked above).

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Ctrl+Shift hotkeys: Q(12), R(15), [(33), ](30), ↑(126), ↓(125), L(37)
        // Store the delegate reference for the callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                // If the tap is disabled by the system, re-enable it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    diagLog("⚠️  Event tap was disabled, re-enabling...")
                    if let refcon = refcon {
                        let del = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = del.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passRetained(event)
                }

                guard type == .keyDown else { return Unmanaged.passRetained(event) }

                let flags = event.flags
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

                // Check for Ctrl+Shift (and no other modifiers like Cmd or Option)
                let hasCtrl = flags.contains(.maskControl)
                let hasShift = flags.contains(.maskShift)
                let hasCmd = flags.contains(.maskCommand)
                let hasOpt = flags.contains(.maskAlternate)

                guard hasCtrl && hasShift && !hasCmd && !hasOpt else {
                    return Unmanaged.passRetained(event)
                }

                // Check if this keyCode is one of our hotkeys
                let hotkeyMap: [UInt16: String] = [
                    12: "quit", 15: "toggle", 33: "prev", 30: "next",
                    126: "sharp_up", 125: "sharp_down", 37: "reload",
                ]

                guard let action = hotkeyMap[keyCode] else {
                    return Unmanaged.passRetained(event)
                }

                diagLog("🎮 CGEventTap: Ctrl+Shift+\(action) (keyCode=\(keyCode))")

                guard let refcon = refcon else { return nil } // consume the event
                let del = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                guard let ctl = del.overlayController else { return nil }

                DispatchQueue.main.async {
                    switch action {
                    case "quit":
                        diagLog("🛑 Emergency quit (Ctrl+Shift+Q)")
                        ctl.stop()
                        NSApp.terminate(nil)
                    case "toggle":
                        diagLog("🎮 Hotkey: Toggle overlay")
                        ctl.toggleOverlay()
                    case "prev":
                        diagLog("🎮 Hotkey: Previous shader")
                        ctl.previousShader()
                    case "next":
                        diagLog("🎮 Hotkey: Next shader")
                        ctl.nextShader()
                    case "sharp_up":
                        diagLog("🎮 Hotkey: Increase sharpness")
                        ctl.adjustSharpness(delta: 0.1)
                    case "sharp_down":
                        diagLog("🎮 Hotkey: Decrease sharpness")
                        ctl.adjustSharpness(delta: -0.1)
                    case "reload":
                        diagLog("🎮 Hotkey: Reload shaders")
                        ctl.reloadShaders()
                    default: break
                    }
                }

                return nil // consume the event (don't pass to game)
            },
            userInfo: refcon
        ) else {
            diagLog("❌ CGEventTap creation FAILED — Accessibility permission may not be working")
            diagLog("   Falling back to menu bar controls only")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        diagLog("✅ CGEventTap installed — global hotkeys active (Ctrl+Shift)")
        diagLog("🎮 Registered hotkeys: Q(quit) R(toggle) [(prev) ](next) ↑(sharp+) ↓(sharp-) L(reload)")
    }
}

// MARK: - Status Bar Controller

class StatusBarController {
    let statusItem: NSStatusItem
    weak var overlayController: OverlayController?
    let shaderManager: ShaderManager
    var shaderMenuItems: [NSMenuItem] = []
    var enabledMenuItem: NSMenuItem?
    var fpsMenuItem: NSMenuItem?
    var sharpnessMenuItem: NSMenuItem?
    var statusMenuItem: NSMenuItem?

    init(overlayController: OverlayController, shaderManager: ShaderManager) {
        self.overlayController = overlayController
        self.shaderManager = shaderManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎨"
        statusItem.button?.toolTip = "StarShade"
        buildMenu()
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        shaderMenuItems = []

        statusMenuItem = NSMenuItem(title: "⏳ Looking for game...", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)

        let permGranted = CGPreflightScreenCaptureAccess()
        let permItem = NSMenuItem(
            title: permGranted ? "✅ Screen Recording: Granted" : "❌ Screen Recording: NOT Granted",
            action: nil, keyEquivalent: "")
        permItem.isEnabled = false
        menu.addItem(permItem)

        fpsMenuItem = NSMenuItem(title: "FPS: —", action: nil, keyEquivalent: "")
        fpsMenuItem?.isEnabled = false
        menu.addItem(fpsMenuItem!)

        menu.addItem(NSMenuItem.separator())

        enabledMenuItem = NSMenuItem(title: "Overlay Enabled", action: #selector(toggleEnabled), keyEquivalent: "r")
        enabledMenuItem?.keyEquivalentModifierMask = [.control, .shift]
        enabledMenuItem?.state = .on
        enabledMenuItem?.target = self
        menu.addItem(enabledMenuItem!)

        menu.addItem(NSMenuItem.separator())

        let shaderHeader = NSMenuItem(title: "Shader:", action: nil, keyEquivalent: "")
        shaderHeader.isEnabled = false
        menu.addItem(shaderHeader)

        // Dynamically build shader list from ShaderManager
        for info in shaderManager.shaders {
            let item = NSMenuItem(title: info.name, action: #selector(selectShader(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = info.id
            if info.id == overlayController?.currentShaderName { item.state = .on }
            shaderMenuItems.append(item)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        sharpnessMenuItem = NSMenuItem(title: "Sharpness: 0.50", action: nil, keyEquivalent: "")
        sharpnessMenuItem?.isEnabled = false
        menu.addItem(sharpnessMenuItem!)

        let inc = NSMenuItem(title: "Increase Sharpness", action: #selector(increaseSharpness), keyEquivalent: "")
        inc.target = self; menu.addItem(inc)
        let dec = NSMenuItem(title: "Decrease Sharpness", action: #selector(decreaseSharpness), keyEquivalent: "")
        dec.target = self; menu.addItem(dec)

        menu.addItem(NSMenuItem.separator())

        let reload = NSMenuItem(title: "🔄 Reload Shaders", action: #selector(doReloadShaders), keyEquivalent: "l")
        reload.keyEquivalentModifierMask = [.control, .shift]
        reload.target = self
        menu.addItem(reload)

        let openFolder = NSMenuItem(title: "📁 Open Shaders Folder", action: #selector(doOpenShadersFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(NSMenuItem.separator())

        // Permissions status
        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = AXIsProcessTrusted()
        let screenItem = NSMenuItem(
            title: screenOK ? "✅ Screen Recording" : "❌ Screen Recording — Click to fix",
            action: screenOK ? nil : #selector(doFixScreenRecording), keyEquivalent: "")
        screenItem.target = self
        screenItem.isEnabled = !screenOK
        menu.addItem(screenItem)

        let axItem = NSMenuItem(
            title: axOK ? "✅ Accessibility (hotkeys)" : "❌ Accessibility (hotkeys) — Click to fix",
            action: axOK ? nil : #selector(doFixAccessibility), keyEquivalent: "")
        axItem.target = self
        axItem.isEnabled = !axOK
        menu.addItem(axItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit StarShade", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc func toggleEnabled() { overlayController?.toggleOverlay() }
    @objc func selectShader(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        overlayController?.setShader(id)
    }
    @objc func increaseSharpness() { overlayController?.adjustSharpness(delta: 0.1) }
    @objc func decreaseSharpness() { overlayController?.adjustSharpness(delta: -0.1) }
    @objc func doReloadShaders() { overlayController?.reloadShaders() }
    @objc func doOpenShadersFolder() {
        NSWorkspace.shared.open(shaderManager.userShadersDir)
    }
    @objc func doFixScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func doFixAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
    @objc func doQuit() { NSApp.terminate(nil) }

    func updateStatus(text: String) { DispatchQueue.main.async { self.statusMenuItem?.title = text } }
    func updateFPS(_ fps: Double) { DispatchQueue.main.async { self.fpsMenuItem?.title = "FPS: \(String(format: "%.1f", fps))" } }
    func updateShader(_ name: String) {
        DispatchQueue.main.async {
            for item in self.shaderMenuItems { item.state = (item.representedObject as? String) == name ? .on : .off }
        }
    }
    func updateEnabled(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.enabledMenuItem?.state = enabled ? .on : .off
            self.statusItem.button?.title = enabled ? "🎨" : "🎨⏸"
        }
    }
    func updateSharpness(_ value: Float) {
        DispatchQueue.main.async { self.sharpnessMenuItem?.title = "Sharpness: \(String(format: "%.2f", value))" }
    }
}

// MARK: - Overlay Controller

class OverlayController: NSObject {
    let config: OverlayConfig
    let shaderManager: ShaderManager
    var overlayWindow: NSWindow?
    var metalLayer: CAMetalLayer?
    var renderer: OverlayRenderer?
    var captureEngine: CaptureEngine?
    var targetWindow: SCWindow?
    var pollTimer: Timer?
    var trackingTimer: Timer?
    var appFocusObserver: Any?
    var targetAppBundleId: String?
    var targetAppFocused: Bool = true
    var statusBar: StatusBarController?
    var isEnabled: Bool = true
    var overlayVisible: Bool = false
    var currentShaderName: String
    var currentSharpness: Float = 0.5

    init(config: OverlayConfig, shaderManager: ShaderManager) {
        self.config = config
        self.shaderManager = shaderManager
        self.currentShaderName = config.shaderName
        super.init()
    }

    func start() { findTargetWindow() }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        trackingTimer?.invalidate(); trackingTimer = nil
        if let obs = appFocusObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        appFocusObserver = nil
        captureEngine?.stop()
        overlayWindow?.close(); overlayWindow = nil
    }

    func toggleOverlay() {
        isEnabled = !isEnabled
        diagLog("toggleOverlay() called — isEnabled=\(isEnabled) captureEngine=\(captureEngine != nil) overlayWindow=\(overlayWindow != nil)")
        if isEnabled {
            // Only show overlay if we have an active capture (prevents stale frames)
            if captureEngine != nil {
                overlayVisible = true
                overlayWindow?.orderFrontRegardless()
                diagLog("✅ Overlay enabled and shown")
            } else {
                diagLog("✅ Overlay enabled (will show when game is running)")
            }
        } else {
            overlayWindow?.orderOut(nil)
            overlayVisible = false
            diagLog("⏸  Overlay disabled")
        }
        statusBar?.updateEnabled(isEnabled)
    }

    func nextShader() {
        let ids = shaderManager.shaderIDs
        guard !ids.isEmpty else { return }
        guard let idx = ids.firstIndex(of: currentShaderName) else {
            setShader(ids[0])
            return
        }
        setShader(ids[(idx + 1) % ids.count])
    }

    func previousShader() {
        let ids = shaderManager.shaderIDs
        guard !ids.isEmpty else { return }
        guard let idx = ids.firstIndex(of: currentShaderName) else {
            setShader(ids[0])
            return
        }
        setShader(ids[(idx - 1 + ids.count) % ids.count])
    }

    func setShader(_ name: String) {
        guard let info = shaderManager.shader(for: name) else {
            print("⚠️  Shader not found: \(name)")
            return
        }
        guard let source = shaderManager.compilableSource(for: name) else {
            print("⚠️  Could not get source for shader: \(name)")
            return
        }

        currentShaderName = name
        print("\n🔄 Shader: \(info.name) [\(name)]")
        statusBar?.updateShader(name)

        guard let layer = self.metalLayer else { return }
        let newRenderer = OverlayRenderer(
            device: layer.device!,
            pixelFormat: layer.pixelFormat,
            shaderSource: source,
            shaderName: name,
            needsParams: info.needsParams,
            showStats: config.showStats
        )
        newRenderer.currentSharpness = currentSharpness
        newRenderer.onFPSUpdate = { [weak self] fps in self?.statusBar?.updateFPS(fps) }
        self.renderer = newRenderer
    }

    func adjustSharpness(delta: Float) {
        currentSharpness = max(0.0, min(1.0, currentSharpness + delta))
        renderer?.currentSharpness = currentSharpness
        print("\n📊 Sharpness: \(String(format: "%.2f", currentSharpness))")
        statusBar?.updateSharpness(currentSharpness)
    }

    func reloadShaders() {
        shaderManager.reload()
        statusBar?.buildMenu()
        // If current shader still exists, re-select it; otherwise pick first
        if shaderManager.shader(for: currentShaderName) == nil && !shaderManager.shaderIDs.isEmpty {
            setShader(shaderManager.shaderIDs[0])
        }
        print("✅ Shaders reloaded (\(shaderManager.shaders.count) found)")
    }

    private func showPermissionErrorOnce() {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              !appDelegate.hasShownPermissionAlert else { return }
        appDelegate.hasShownPermissionAlert = true

        statusBar?.updateStatus(text: "⚠️  No Screen Recording — grant in System Settings")
        statusBar?.statusItem.button?.title = "🎨⚠️"
        print("⚠️  Screen Recording not working — app will keep polling until permission is granted")
        print("   Grant in: System Settings → Privacy & Security → Screen Recording")
        print("   Then relaunch the app.")
    }

    private func findTargetWindow() {
        statusBar?.updateStatus(text: "🔍 Searching for game...")

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ ScreenCaptureKit error: \(error.localizedDescription)")
                print("   Make sure Screen Recording permission is granted in System Settings → Privacy & Security")
                self.statusBar?.updateStatus(text: "❌ No Screen Recording permission")
                DispatchQueue.main.async {
                    self.showPermissionErrorOnce()
                }
                return
            }

            guard let content = content else { return }

            if self.targetWindow == nil {
                print("📋 Available windows:")
                for window in content.windows where window.frame.width > 100 && window.frame.height > 100 {
                    let title = window.title ?? "(untitled)"
                    let bundleId = window.owningApplication?.bundleIdentifier ?? "(unknown)"
                    print("   [\(window.windowID)] \(title) — \(bundleId) (\(Int(window.frame.width))×\(Int(window.frame.height)))")
                }
                print("")
            }

            // Pick the largest matching window — avoids accidentally grabbing small helper
            // popups (e.g. AutoFill, tooltips) that share an app name with the real target.
            let target = content.windows
                .filter { window in
                    let title = window.title ?? ""
                    let bundleId = window.owningApplication?.bundleIdentifier ?? ""
                    let appName = window.owningApplication?.applicationName ?? ""
                    let matches = bundleId.lowercased().contains(self.config.targetBundleId.lowercased())
                        || title.lowercased().contains(self.config.targetWindowTitle.lowercased())
                        || appName.lowercased().contains(self.config.targetWindowTitle.lowercased())
                    return matches && window.frame.width > 100 && window.frame.height > 100
                }
                .max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })

            if let target = target {
                let title = target.title ?? "(untitled)"
                let app = target.owningApplication?.applicationName ?? "(unknown)"
                diagLog("✅ Found target: \"\(title)\" (\(app)) — \(Int(target.frame.width))×\(Int(target.frame.height))")
                diagLog("   Window ID: \(target.windowID)")
                self.targetWindow = target
                self.statusBar?.updateStatus(text: "✅ Attached: \(app)")
                let displays = content.displays
                DispatchQueue.main.async {
                    self.setupOverlay(for: target)
                    self.startCapture(window: target, displays: displays)
                    self.startWindowTracking(window: target)
                }
            } else {
                if self.pollTimer == nil {
                    diagLog("⏳ Game window not found. Waiting for: \"\(self.config.targetWindowTitle)\"")
                    self.statusBar?.updateStatus(text: "⏳ Waiting for game...")
                    DispatchQueue.main.async { self.startPolling() }
                }
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.findTargetWindow()
        }
    }

    private func setupOverlay(for target: SCWindow) {
        pollTimer?.invalidate()
        pollTimer = nil

        let frame = target.frame
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let cocoaFrame = NSRect(
            x: frame.origin.x,
            y: screenFrame.height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )

        print("🖥  Screen: \(Int(screenFrame.width))×\(Int(screenFrame.height))")
        print("🖥  Game frame (SC): origin=(\(Int(frame.origin.x)),\(Int(frame.origin.y))) \(Int(frame.width))×\(Int(frame.height))")
        print("🖥  Overlay frame (Cocoa): origin=(\(Int(cocoaFrame.origin.x)),\(Int(cocoaFrame.origin.y))) \(Int(cocoaFrame.width))×\(Int(cocoaFrame.height))")

        let window = NSWindow(
            contentRect: cocoaFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ No Metal device available")
            return
        }

        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = CGColor.clear
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        let contentView = NSView(frame: NSRect(origin: .zero, size: cocoaFrame.size))
        contentView.wantsLayer = true
        contentView.layer = metalLayer
        metalLayer.frame = contentView.bounds
        metalLayer.drawableSize = CGSize(
            width: cocoaFrame.width * metalLayer.contentsScale,
            height: cocoaFrame.height * metalLayer.contentsScale
        )

        window.contentView = contentView

        // Build renderer from shader file
        guard let shaderInfo = shaderManager.shader(for: currentShaderName),
              let source = shaderManager.compilableSource(for: currentShaderName) else {
            print("❌ Could not load shader: \(currentShaderName)")
            return
        }

        let renderer = OverlayRenderer(
            device: device,
            pixelFormat: metalLayer.pixelFormat,
            shaderSource: source,
            shaderName: currentShaderName,
            needsParams: shaderInfo.needsParams,
            showStats: config.showStats
        )
        renderer.currentSharpness = currentSharpness
        renderer.onFPSUpdate = { [weak self] fps in self?.statusBar?.updateFPS(fps) }

        print("🖥  Overlay window created (hidden until first frame renders)")

        self.overlayWindow = window
        self.metalLayer = metalLayer
        self.renderer = renderer

        print("🖥  Drawable size: \(Int(metalLayer.drawableSize.width))×\(Int(metalLayer.drawableSize.height))")
        print("🖥  Window level: \(window.level.rawValue) (floating)")
    }

    func showOverlayIfNeeded() {
        guard !overlayVisible, let window = overlayWindow, isEnabled else { return }
        overlayVisible = true
        diagLog("showOverlayIfNeeded() — making overlay VISIBLE")
        DispatchQueue.main.async {
            // Only show immediately if the target app is currently frontmost
            if self.targetAppFocused {
                window.orderFrontRegardless()
                diagLog("🖥  Overlay now VISIBLE (first frame rendered successfully)")
            } else {
                diagLog("🖥  First frame ready but target app not focused — overlay deferred")
            }
        }
    }

    private func startCapture(window target: SCWindow, displays: [SCDisplay] = []) {
        guard let _ = self.renderer, let metalLayer = self.metalLayer else { return }

        diagLog("Starting capture — Screen Recording: \(CGPreflightScreenCaptureAccess())")

        captureEngine = CaptureEngine(
            targetWindow: target,
            displays: displays,
            overlayWindow: overlayWindow,
            frameRate: config.captureFrameRate,
            metalDevice: metalLayer.device!,
            onFrame: { [weak self] texture in
                guard let self = self, self.isEnabled, let layer = self.metalLayer, let currentRenderer = self.renderer else { return }
                let rendered = currentRenderer.renderFrame(texture: texture, to: layer)
                if rendered {
                    self.showOverlayIfNeeded()
                }
            }
        )

        captureEngine?.onBlackFrames = { [weak self] in
            diagLog("⚠️  BLACK FRAMES DETECTED — Screen Recording permission not working")
            self?.statusBar?.updateStatus(text: "⚠️  Black frames — permission broken")
            self?.statusBar?.statusItem.button?.title = "🎨⚠️"
        }

        captureEngine?.start()
    }

    private func startWindowTracking(window target: SCWindow) {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self, let overlay = self.overlayWindow else {
                timer.invalidate()
                return
            }

            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
                guard let content = content else { return }
                guard let updated = content.windows.first(where: { $0.windowID == target.windowID }) else {
                    print("\n⚠️  Target window closed")
                    DispatchQueue.main.async {
                        timer.invalidate()
                        self.captureEngine?.stop()
                        self.captureEngine = nil
                        self.overlayWindow?.orderOut(nil)
                        self.overlayVisible = false
                        self.targetWindow = nil
                        // Clear the Metal layer so no stale frame lingers
                        if let layer = self.metalLayer, let drawable = layer.nextDrawable() {
                            let desc = MTLRenderPassDescriptor()
                            desc.colorAttachments[0].texture = drawable.texture
                            desc.colorAttachments[0].loadAction = .clear
                            desc.colorAttachments[0].storeAction = .store
                            desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                            if let queue = layer.device?.makeCommandQueue(),
                               let buf = queue.makeCommandBuffer(),
                               let enc = buf.makeRenderCommandEncoder(descriptor: desc) {
                                enc.endEncoding()
                                buf.present(drawable)
                                buf.commit()
                            }
                        }
                        self.statusBar?.updateStatus(text: "⏳ Game closed, waiting...")
                        self.startPolling()
                    }
                    return
                }

                let frame = updated.frame
                let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                let cocoaFrame = NSRect(
                    x: frame.origin.x,
                    y: screenFrame.height - frame.origin.y - frame.height,
                    width: frame.width,
                    height: frame.height
                )

                DispatchQueue.main.async {
                    if overlay.frame != cocoaFrame {
                        overlay.setFrame(cocoaFrame, display: false)
                        if let layer = self.metalLayer {
                            layer.frame = NSRect(origin: .zero, size: cocoaFrame.size)
                            layer.drawableSize = CGSize(
                                width: cocoaFrame.width * layer.contentsScale,
                                height: cocoaFrame.height * layer.contentsScale
                            )
                        }
                        // Update capture crop region for display capture mode
                        self.captureEngine?.updateSourceRect(frame)
                    }
                }
            }
        }

        // Hide overlay when target app loses focus; restore when it regains focus.
        targetAppBundleId = target.owningApplication?.bundleIdentifier
        targetAppFocused = true

        if let obs = appFocusObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        appFocusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let activeBundleId = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            let isTarget = activeBundleId == self.targetAppBundleId
            guard isTarget != self.targetAppFocused else { return }
            self.targetAppFocused = isTarget
            if isTarget {
                if self.isEnabled, let window = self.overlayWindow {
                    window.orderFrontRegardless()
                    diagLog("👁  Target app focused — overlay shown")
                }
            } else {
                self.overlayWindow?.orderOut(nil)
                diagLog("👁  Target app unfocused — overlay hidden")
            }
        }
    }
}

// MARK: - Capture Engine (ScreenCaptureKit)

class CaptureEngine: NSObject, SCStreamDelegate, SCStreamOutput {
    let targetWindow: SCWindow
    let displays: [SCDisplay]
    weak var overlayWindow: NSWindow?
    let frameRate: Double
    let metalDevice: MTLDevice
    var stream: SCStream?
    var onFrame: ((MTLTexture) -> Void)?
    var onBlackFrames: (() -> Void)?
    var textureCache: CVMetalTextureCache?
    var frameDeliveryCount: Int = 0
    var blackFrameCount: Int = 0
    var usingDisplayCapture: Bool = false

    init(targetWindow: SCWindow, displays: [SCDisplay], overlayWindow: NSWindow?, frameRate: Double, metalDevice: MTLDevice, onFrame: @escaping (MTLTexture) -> Void) {
        self.targetWindow = targetWindow
        self.displays = displays
        self.overlayWindow = overlayWindow
        self.frameRate = frameRate
        self.metalDevice = metalDevice
        self.onFrame = onFrame
        super.init()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &cache)
        self.textureCache = cache
    }

    func start() {
        if !CGPreflightScreenCaptureAccess() {
            diagLog("⚠️  Screen Recording permission NOT granted — captured frames will be black")
        } else {
            diagLog("✅ Screen Recording permission confirmed for capture")
        }

        // Use display-level capture with crop to the game window.
        // Window-level capture (desktopIndependentWindow) returns black frames for
        // Unity/Metal games because it can't read the GPU surface directly.
        // Display-level capture grabs the composited screen where the game IS visible.
        //
        // We need to exclude our own overlay window to prevent a feedback loop.
        // Query SCShareableContent to find the SCWindow for our overlay (match by windowNumber).

        let overlayWindowNumber = overlayWindow?.windowNumber ?? -1
        diagLog("Looking for overlay window to exclude (windowNumber=\(overlayWindowNumber))")

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }

            let scale = NSScreen.main?.backingScaleFactor ?? 2.0

            let filter: SCContentFilter
            if let display = self.displays.first, let content = content {
                // Find our overlay window in the SCShareableContent to exclude it
                var excludeWindows: [SCWindow] = []
                if overlayWindowNumber > 0 {
                    if let overlayScWindow = content.windows.first(where: { $0.windowID == CGWindowID(overlayWindowNumber) }) {
                        excludeWindows.append(overlayScWindow)
                        diagLog("✅ Found overlay SCWindow (ID=\(overlayScWindow.windowID)) — will exclude from capture")
                    } else {
                        diagLog("⚠️  Could not find overlay in SCShareableContent (windowNumber=\(overlayWindowNumber))")
                    }
                }

                diagLog("Using DISPLAY capture (display \(display.displayID)) with sourceRect crop, excluding \(excludeWindows.count) window(s)")
                filter = SCContentFilter(display: display, excludingWindows: excludeWindows)
                self.usingDisplayCapture = true
            } else {
                diagLog("No display found or content error, falling back to window capture")
                filter = SCContentFilter(desktopIndependentWindow: self.targetWindow)
                self.usingDisplayCapture = false
            }

            let config = SCStreamConfiguration()
            let winFrame = self.targetWindow.frame

            if self.usingDisplayCapture {
                // Crop to the game window bounds on the display
                config.sourceRect = winFrame
                config.width = Int(winFrame.width * scale)
                config.height = Int(winFrame.height * scale)
                diagLog("Capture sourceRect: origin=(\(Int(winFrame.origin.x)),\(Int(winFrame.origin.y))) size=\(Int(winFrame.width))×\(Int(winFrame.height))")
            } else {
                config.width = Int(winFrame.width * scale)
                config.height = Int(winFrame.height * scale)
            }

            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.frameRate))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.queueDepth = 3

            diagLog("Capture config: \(config.width)×\(config.height) @ \(Int(self.frameRate))fps displayCapture=\(self.usingDisplayCapture)")

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = stream

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "starshade.capture", qos: .userInteractive))
                stream.startCapture { error in
                    if let error = error {
                        diagLog("❌ Capture start failed: \(error.localizedDescription)")
                    } else {
                        diagLog("🎬 Capture started at \(Int(self.frameRate)) FPS (\(config.width)×\(config.height)) mode=\(self.usingDisplayCapture ? "display" : "window")")
                    }
                }
            } catch {
                diagLog("❌ Failed to add stream output: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    /// Update the capture source rect when the game window moves (display capture mode)
    func updateSourceRect(_ newFrame: CGRect) {
        guard usingDisplayCapture, let stream = stream else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.sourceRect = newFrame
        config.width = Int(newFrame.width * scale)
        config.height = Int(newFrame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 3
        stream.updateConfiguration(config) { error in
            if let error = error {
                diagLog("⚠️  Failed to update sourceRect: \(error.localizedDescription)")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        frameDeliveryCount += 1

        if frameDeliveryCount == 1 {
            diagLog("🎬 First frame delivered from ScreenCaptureKit!")
        }

        var frameStatus: Int = -1
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRawValue = attachments[.status] as? Int {
            frameStatus = statusRawValue
            if frameDeliveryCount <= 10 {
                let names = ["complete", "idle", "blank", "suspended", "started"]
                let name = statusRawValue < names.count ? names[statusRawValue] : "unknown(\(statusRawValue))"
                diagLog("📦 Frame \(frameDeliveryCount) status=\(name)")
            }
            guard statusRawValue == 0 || statusRawValue == 1 else { return }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if frameDeliveryCount <= 10 {
                print("📦 Frame \(frameDeliveryCount): no pixel buffer (status=\(frameStatus))")
            }
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if frameDeliveryCount <= 10 {
            diagLog("📦 Frame \(frameDeliveryCount): \(width)×\(height) IOSurface=\(CVPixelBufferGetIOSurface(pixelBuffer) != nil) status=\(frameStatus)")
        }

        // Diagnostic: sample pixels from first 10 frames to detect black content (permission issue)
        if frameDeliveryCount <= 10 && frameStatus == 0 {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
                var hasColor = false
                // Sample 5 spread-out points
                let pts = [(width/4, height/4), (width/2, height/2), (3*width/4, height/4),
                           (width/4, 3*height/4), (3*width/4, 3*height/4)]
                for (x, y) in pts {
                    let p = base.advanced(by: y * bpr + x * 4).assumingMemoryBound(to: UInt8.self)
                    if p[0] != 0 || p[1] != 0 || p[2] != 0 { hasColor = true; break }
                }
                if !hasColor { blackFrameCount += 1 }

                if frameDeliveryCount <= 3 {
                    let m = base.advanced(by: (height/2) * bpr + (width/2) * 4).assumingMemoryBound(to: UInt8.self)
                    diagLog("🔍 Frame \(frameDeliveryCount) center pixel: BGRA(\(m[0]),\(m[1]),\(m[2]),\(m[3])) allBlack=\(!hasColor)")
                }

                if frameDeliveryCount == 10 && blackFrameCount >= 8 {
                    print("")
                    print("⚠️  WARNING: \(blackFrameCount)/10 captured frames are ALL BLACK")
                    print("   Screen Recording permission is likely not working for this app.")
                    print("   Fix:")
                    print("     1. Run: ./setup-signing.sh       (one-time)")
                    print("     2. Run: ./build.sh               (rebuild with stable identity)")
                    print("     3. Run: tccutil reset ScreenCapture com.starshade.app")
                    print("     4. Relaunch and grant permission")
                    DispatchQueue.main.async { [weak self] in
                        self?.onBlackFrames?()
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let cache = textureCache else { return }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)

        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTex) else {
            if frameDeliveryCount <= 5 {
                print("⚠️  Frame \(frameDeliveryCount): texture creation failed (\(status))")
            }
            return
        }

        if frameDeliveryCount <= 10 {
            diagLog("✅ Frame \(frameDeliveryCount): MTLTexture \(metalTexture.width)×\(metalTexture.height) status=\(frameStatus)")
        }

        onFrame?(metalTexture)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        diagLog("⚠️  Capture stream stopped: \(error.localizedDescription)")
    }
}

// MARK: - Metal Renderer

class OverlayRenderer: NSObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLRenderPipelineState
    let sampler: MTLSamplerState
    var shaderName: String
    let needsParams: Bool
    let showStats: Bool

    var frameCount: Int = 0
    var lastFPSTime: CFTimeInterval = 0
    var currentFPS: Double = 0
    var currentSharpness: Float = 0.5
    var onFPSUpdate: ((Double) -> Void)?
    var paramsBuffer: MTLBuffer?
    var renderCount: Int = 0

    struct ShaderParams {
        var sharpness: Float
        var texelWidth: Float
        var texelHeight: Float
        var pad: Float
    }

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, shaderSource: String, shaderName: String, needsParams: Bool, showStats: Bool) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.shaderName = shaderName
        self.needsParams = needsParams
        self.showStats = showStats

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            fatalError("Failed to compile Metal shader '\(shaderName)': \(error)")
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "vertex_main")!
        pipelineDesc.fragmentFunction = library.makeFunction(name: "fragment_main")!
        pipelineDesc.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDesc.colorAttachments[0].isBlendingEnabled = false

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            fatalError("Failed to create pipeline state for '\(shaderName)': \(error)")
        }

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: samplerDesc)!

        if needsParams {
            var params = ShaderParams(sharpness: 0.5, texelWidth: 0, texelHeight: 0, pad: 0)
            self.paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<ShaderParams>.size, options: .storageModeShared)
        }

        super.init()
    }

    @discardableResult
    func renderFrame(texture: MTLTexture, to layer: CAMetalLayer) -> Bool {
        guard let drawable = layer.nextDrawable() else {
            if renderCount <= 5 { print("⚠️  No drawable available (render \(renderCount))") }
            return false
        }

        renderCount += 1

        // Update params buffer if this shader uses it
        if needsParams, let buffer = paramsBuffer {
            var params = ShaderParams(
                sharpness: currentSharpness,
                texelWidth: 1.0 / Float(texture.width),
                texelHeight: 1.0 / Float(texture.height),
                pad: 0
            )
            buffer.contents().copyMemory(from: &params, byteCount: MemoryLayout<ShaderParams>.size)
        }

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            if renderCount <= 5 { print("⚠️  Failed to create command buffer/encoder") }
            return false
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)

        if needsParams, let buffer = paramsBuffer {
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let currentRenderCount = renderCount
        commandBuffer.addCompletedHandler { cb in
            if let error = cb.error {
                print("❌ GPU error on frame \(currentRenderCount): \(error.localizedDescription)")
            } else if currentRenderCount <= 5 {
                print("✅ GPU completed frame \(currentRenderCount) (status: \(cb.status.rawValue))")
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if renderCount <= 10 {
            diagLog("🎨 Rendered frame \(renderCount) to drawable \(drawable.texture.width)×\(drawable.texture.height)")
        }

        // FPS counter
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSTime >= 1.0 {
            currentFPS = Double(frameCount) / (now - lastFPSTime)
            frameCount = 0
            lastFPSTime = now
            if showStats {
                print("\r⚡ \(String(format: "%.1f", currentFPS)) FPS [\(shaderName)] sharpness=\(String(format: "%.2f", currentSharpness))", terminator: "")
                fflush(stdout)
            }
            onFPSUpdate?(currentFPS)
        }

        return true
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
