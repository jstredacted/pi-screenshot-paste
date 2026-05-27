import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

private enum Defaults {
    static let targetBundleIDsKey = "targetBundleIDs"
    static let pastePrefixKey = "pastePrefix"
    static let outputDirectoryKey = "outputDirectory"
    static let cleanupAfterSecondsKey = "cleanupAfterSeconds"
}

private final class ScreenshotPasteApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cleanupTimer: Timer?
    private var permissionStatusItem: NSMenuItem?
    private var hasStatusLogo = false
    private var lockFileDescriptor: Int32 = -1

    private var targetBundleIDs: Set<String> {
        let configured = UserDefaults.standard.stringArray(forKey: Defaults.targetBundleIDsKey)
        return Set(configured?.filter { !$0.isEmpty } ?? ["com.mitchellh.ghostty"])
    }

    private var pastePrefix: String {
        UserDefaults.standard.string(forKey: Defaults.pastePrefixKey) ?? ""
    }

    private var cleanupAfterSeconds: TimeInterval? {
        let configured = UserDefaults.standard.double(forKey: Defaults.cleanupAfterSecondsKey)
        return configured > 0 ? configured : nil
    }

    private var outputDirectory: URL {
        if let configured = UserDefaults.standard.string(forKey: Defaults.outputDirectoryKey), !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(".ghostty_paste", isDirectory: true)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        registerDefaultSettings()
        ensureOutputDirectory()
        setupStatusItem()
        requestAccessibilityIfNeeded()
        installEventTap()
        scheduleCleanupIfEnabled()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        uninstallEventTap()
        releaseSingleInstanceLock()
    }

    private func acquireSingleInstanceLock() -> Bool {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("com.justin.PiScreenshotPaste.lock")
        lockFileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor >= 0 else { return false }
        return flock(lockFileDescriptor, LOCK_EX | LOCK_NB) == 0
    }

    private func releaseSingleInstanceLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func registerDefaultSettings() {
        UserDefaults.standard.register(defaults: [
            Defaults.targetBundleIDsKey: ["com.mitchellh.ghostty"],
            Defaults.pastePrefixKey: "",
            Defaults.cleanupAfterSecondsKey: 0,
        ])
    }

    @MainActor
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let logo = loadMenuBarIcon() {
            logo.size = NSSize(width: 14, height: 18)
            logo.isTemplate = false
            statusItem.button?.imageScaling = .scaleProportionallyUpOrDown
            statusItem.button?.image = logo
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.title = ""
            statusItem.button?.setAccessibilityLabel("PiPaste")
            hasStatusLogo = true
        } else {
            statusItem.button?.title = "PiPaste"
        }
        statusItem.button?.toolTip = "Pi Screenshot Paste is running"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Pi Screenshot Paste", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let permissionStatus = NSMenuItem(title: "Permission Status: checking...", action: #selector(refreshPermissionStatus), keyEquivalent: "")
        permissionStatusItem = permissionStatus
        menu.addItem(permissionStatus)
        menu.addItem(NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Request Input Monitoring Permission", action: #selector(requestInputMonitoringPermission), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Copy Output Folder Path", action: #selector(copyOutputFolderPath), keyEquivalent: "c"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Restart Event Tap", action: #selector(restartEventTap), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func loadMenuBarIcon() -> NSImage? {
        let resourceURLs = [
            Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
            Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
            Bundle.module.url(forResource: "PiPaste", withExtension: "png"),
        ]

        for url in resourceURLs.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }

    @MainActor
    private func requestAccessibilityIfNeeded() {
        // Do not trigger macOS permission prompts on every launch. The app may be
        // restarted by launchd after a rebuild; prompting here creates the
        // confusing loop where System Settings already appears configured but
        // the freshly rebuilt binary has a new privacy identity. Surface status
        // in the menu instead and let the user open the exact panes manually.
        let trusted = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        logState("Permission preflight; AX trusted=\(trusted); listen=\(listen); bundle=\(Bundle.main.bundleIdentifier ?? "nil"); path=\(Bundle.main.bundlePath)")
        updatePermissionStatus(tapReady: eventTap != nil)
    }

    @MainActor
    private func installEventTap() {
        uninstallEventTap()

        let mask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<ScreenshotPasteApp>.fromOpaque(refcon).takeUnretainedValue()
                return app.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap else {
            if hasStatusLogo {
                statusItem.button?.title = "⚠"
                statusItem.button?.imagePosition = .imageLeading
            } else {
                statusItem.button?.title = "PiPaste ⚠"
            }
            let trusted = AXIsProcessTrusted()
            let listen = CGPreflightListenEventAccess()
            logState("FAILED event tap create; AX trusted=\(trusted); listen=\(listen); targetBundleIDs=\(Array(targetBundleIDs).joined(separator: ","))")
            NSLog("PiScreenshotPaste: failed to create event tap. Grant Accessibility/Input Monitoring permission.")
            updatePermissionStatus(tapReady: false)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        if hasStatusLogo {
            statusItem.button?.title = ""
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "PiPaste OK"
        }
        logState("OK event tap installed; AX trusted=\(AXIsProcessTrusted()); listen=\(CGPreflightListenEventAccess()); targetBundleIDs=\(Array(targetBundleIDs).joined(separator: ","))")
        updatePermissionStatus(tapReady: true)
    }

    private func uninstallEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard isCommandV(event) else { return Unmanaged.passUnretained(event) }
        guard isTargetTerminalFrontmost() else { return Unmanaged.passUnretained(event) }
        guard let pngURL = saveClipboardImageAsPNG() else { return Unmanaged.passUnretained(event) }

        typeTextIntoFrontmostApp(pastePrefix + pngURL.path)
        return nil
    }

    private func isCommandV(_ event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasCommand = flags.contains(.maskCommand)
        let hasDisallowedModifiers = flags.intersection([.maskControl, .maskAlternate]).isEmpty == false
        return keyCode == CGKeyCode(kVK_ANSI_V) && hasCommand && !hasDisallowedModifiers
    }

    private func isTargetTerminalFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return targetBundleIDs.contains(bundleID)
    }

    private func saveClipboardImageAsPNG() -> URL? {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        ensureOutputDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "clipboard_\(formatter.string(from: Date()))_\(Int.random(in: 1000...9999)).png"
        let url = outputDirectory.appendingPathComponent(filename)

        do {
            try pngData.write(to: url, options: [.atomic])
            return url
        } catch {
            NSLog("PiScreenshotPaste: failed to write PNG: \(error)")
            return nil
        }
    }

    private func typeTextIntoFrontmostApp(_ text: String) {
        // Do not use NSPasteboard as a transport. Clipboard managers like Maccy
        // record pasteboard writes, which would create bogus screenshot-path
        // history entries and leave the user with a path instead of the image.
        //
        // Critical safety rule: wait until Cmd/Option/Ctrl are released before
        // emitting text. This handler is triggered by Cmd+V. If we type while
        // Cmd is still physically down, Ghostty receives Cmd+<path chars> and
        // interprets them as terminal shortcuts.
        Self.waitForModifierReleaseThenType(text, attempt: 0)
    }

    private static func waitForModifierReleaseThenType(_ text: String, attempt: Int) {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let unsafeModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

        if !flags.intersection(unsafeModifiers).isEmpty {
            if attempt >= 100 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                Self.waitForModifierReleaseThenType(text, attempt: attempt + 1)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            Self.typeUnicodeText(text)
        }
    }

    private static func typeUnicodeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        for scalar in text.unicodeScalars {
            var value = UniChar(scalar.value)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }

            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(1_000)
        }
    }

    private func ensureOutputDirectory() {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("PiScreenshotPaste: failed to create output directory: \(error)")
        }
    }

    private func scheduleCleanupIfEnabled() {
        guard cleanupAfterSeconds != nil else {
            logState("Screenshot cleanup disabled; saved files persist")
            return
        }

        cleanupOldScreenshots()
        cleanupTimer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(cleanupOldScreenshotsTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func cleanupOldScreenshotsTimerFired(_ timer: Timer) {
        cleanupOldScreenshots()
    }

    private func cleanupOldScreenshots() {
        guard let cleanupAfterSeconds else { return }

        let directory = outputDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-cleanupAfterSeconds)
        for url in contents where url.pathExtension.lowercased() == "png" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    @MainActor
    private func updatePermissionStatus(tapReady: Bool) {
        let trusted = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        permissionStatusItem?.title = "Permission Status: AX=\(trusted ? "yes" : "no"), listen=\(listen ? "yes" : "no"), tap=\(tapReady ? "yes" : "no")"
    }

    private func logState(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PiScreenshotPaste.state.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    @MainActor
    @objc private func refreshPermissionStatus() {
        updatePermissionStatus(tapReady: eventTap != nil)
        logState("Manual status refresh; AX trusted=\(AXIsProcessTrusted()); listen=\(CGPreflightListenEventAccess()); tapReady=\(eventTap != nil)")
    }

    @MainActor
    @objc private func requestAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
        updatePermissionStatus(tapReady: eventTap != nil)
    }

    @MainActor
    @objc private func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        openPrivacyPane("Privacy_ListenEvent")
        updatePermissionStatus(tapReady: eventTap != nil)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    @objc private func openOutputFolder() {
        ensureOutputDirectory()
        NSWorkspace.shared.open(outputDirectory)
    }

    @MainActor
    @objc private func copyOutputFolderPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputDirectory.path, forType: .string)
    }

    @MainActor
    @objc private func restartEventTap() {
        installEventTap()
    }

    @MainActor
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
private let delegate = ScreenshotPasteApp()
app.delegate = delegate
app.run()
