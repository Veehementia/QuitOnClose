import AppKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = WindowWatcher()
    private let exclusions = Exclusions()
    private lazy var exclusionsWindow = ExclusionsWindowController(exclusions: exclusions)
    private var trustTimer: Timer?
    /// The apps quit most recently, newest first, so one that was quit by surprise is easy to exclude.
    private var recentlyQuit: [String] = []

    private static let enabledKey = "enabled"
    private static let recentLimit = 5

    private var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            updateIcon()
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "xmark.app", accessibilityDescription: "QuitOnClose")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.shouldQuit = { [unowned self] app in
            guard isEnabled, let id = app.bundleIdentifier else { return false }
            return !exclusions.contains(id)
        }
        watcher.didQuit = { [unowned self] app in
            guard let id = app.bundleIdentifier else { return }
            recentlyQuit.removeAll { $0 == id }
            recentlyQuit.insert(id, at: 0)
            recentlyQuit = Array(recentlyQuit.prefix(Self.recentLimit))
        }

        // Asks for Accessibility access the first time, then waits until it's given.
        if AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            watcher.start()
        } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                MainActor.assumeIsolated {
                    self?.watcher.start()
                    self?.updateIcon()
                }
            }
        }
        updateIcon()
    }

    /// Only there for its key equivalents, since the app has no menu bar of its own.
    private func buildMainMenu() {
        let windowMenu = NSMenu()
        windowMenu.addItem(withTitle: NSLocalizedString("Close", comment: "Menu item"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func updateIcon() {
        statusItem?.button?.appearsDisabled = !isEnabled || !watcher.isRunning
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !watcher.isRunning {
            let warning = NSMenuItem(title: NSLocalizedString("QuitOnClose needs Accessibility access", comment: "Menu status"), action: nil, keyEquivalent: "")
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(item(NSLocalizedString("Allow in System Settings…", comment: "Menu item"), #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }

        let enabled = item(NSLocalizedString("Quit Apps When Their Last Window Closes", comment: "Menu item"), #selector(toggleEnabled))
        enabled.state = isEnabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        // Clicking the menu bar doesn't activate us, so the frontmost app is still the one the user was in.
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier,
           id != Bundle.main.bundleIdentifier, !Exclusions.alwaysKept.contains(id) {
            let exclude = item(
                String(format: NSLocalizedString("Exclude “%@”", comment: "Menu item; the app's name"), front.localizedName ?? id),
                #selector(toggleExclusion(_:))
            )
            exclude.representedObject = id
            exclude.state = exclusions.contains(id) ? .on : .off
            menu.addItem(exclude)
        }
        menu.addItem(item(NSLocalizedString("Excluded Apps…", comment: "Menu item"), #selector(showExclusions)))

        if !recentlyQuit.isEmpty {
            let recent = NSMenu()
            for id in recentlyQuit {
                let app = AppInfo(bundleID: id)
                let entry = item(app.name, #selector(toggleExclusion(_:)))
                entry.representedObject = id
                entry.state = exclusions.contains(id) ? .on : .off
                entry.toolTip = NSLocalizedString("Check an app to exclude it.", comment: "Tooltip")
                recent.addItem(entry)
            }
            let recentItem = NSMenuItem(title: NSLocalizedString("Recently Quit", comment: "Menu item"), action: nil, keyEquivalent: "")
            recentItem.submenu = recent
            menu.addItem(recentItem)
        }
        menu.addItem(.separator())

        let login = item(NSLocalizedString("Open at Login", comment: "Menu item"), #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Quit QuitOnClose", comment: "Menu item"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
    }

    @objc private func toggleExclusion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        exclusions.toggle(id)
    }

    @objc private func showExclusions() {
        exclusionsWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }
}
