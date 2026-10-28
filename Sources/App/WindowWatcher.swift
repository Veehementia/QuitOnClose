import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.matteonardone.QuitOnClose", category: "watcher")

/// Follows the windows of every regular app through the Accessibility API and quits an app
/// once the last of its windows has closed.
@MainActor
final class WindowWatcher {
    /// Asked right before an app is quit; return false to leave it running.
    var shouldQuit: (NSRunningApplication) -> Bool = { _ in true }
    /// Called after an app was asked to quit.
    var didQuit: (NSRunningApplication) -> Void = { _ in }

    /// How long an app has to stay without windows before it's quit, so an app that swaps one
    /// window for another (closing a project and showing its welcome window, say) isn't quit in between.
    static let settleDelay: TimeInterval = 1

    private var apps: [pid_t: WatchedApp] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    var isRunning: Bool { !workspaceObservers.isEmpty }

    func start() {
        guard !isRunning else { return }
        // A hung app shouldn't freeze the menu bar icon for the default 6 seconds per request.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)

        let center = NSWorkspace.shared.notificationCenter
        // Apps can turn into regular apps after launching, so look again whenever one comes to the front.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.watch(app) }
            })
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.apps.removeValue(forKey: app.processIdentifier)?.stop() }
        })

        NSWorkspace.shared.runningApplications.forEach { watch($0) }
        log.notice("Started watching windows")
    }

    func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        apps.values.forEach { $0.stop() }
        apps.removeAll()
        log.notice("Stopped watching windows")
    }

    private func watch(_ app: NSRunningApplication, attempt: Int = 1) {
        let pid = app.processIdentifier
        guard isRunning, apps[pid] == nil, app.activationPolicy == .regular, pid != getpid(), !app.isTerminated else { return }
        if let watched = WatchedApp(app: app, watcher: self) {
            apps[pid] = watched
        } else if attempt == 10 {
            log.error("Gave up watching \(app.name, privacy: .public)")
        } else {
            // An app that has only just launched may not answer accessibility requests yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.watch(app, attempt: attempt + 1) }
            }
        }
    }

    fileprivate func lastWindowClosed(in app: NSRunningApplication) {
        guard shouldQuit(app) else {
            log.info("Last window of \(app.name, privacy: .public) closed, but it's excluded or QuitOnClose is off")
            return
        }
        guard app.terminate() else {
            log.error("\(app.name, privacy: .public) refused to quit")
            return
        }
        log.notice("Quit \(app.name, privacy: .public)")
        didQuit(app)
    }
}

/// One app's accessibility observer and the windows it has open.
@MainActor
private final class WatchedApp {
    let app: NSRunningApplication
    private let element: AXUIElement
    private let observer: AXObserver
    private unowned let watcher: WindowWatcher
    /// The app's real windows that we know of. The Accessibility API leaves windows on other
    /// Spaces out of an app's window list, so we keep our own from the created and destroyed
    /// notifications instead of relying on that list alone.
    private var windows: [AXUIElement] = []
    private var pendingCheck: DispatchWorkItem?

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    init?(app: NSRunningApplication, watcher: WindowWatcher) {
        var observer: AXObserver?
        let created = AXObserverCreate(app.processIdentifier, axCallback, &observer)
        guard created == .success, let observer else {
            log.debug("Can't observe \(app.name, privacy: .public) yet: \(created.rawValue)")
            return nil
        }
        self.app = app
        self.element = AXUIElementCreateApplication(app.processIdentifier)
        self.observer = observer
        self.watcher = watcher

        // "Destroyed" is registered on the whole app as well as on each window: on macOS 27 a
        // window's own registration never fires, while the app's fires for every window that closes.
        for name in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
            let result = AXObserverAddNotification(observer, element, name as CFString, refcon)
            guard result == .success || result == .notificationAlreadyRegistered else {
                log.debug("Can't observe \(app.name, privacy: .public) yet: \(result.rawValue)")
                return nil
            }
        }
        guard let current = currentWindows() else {
            log.debug("Can't list the windows of \(app.name, privacy: .public) yet")
            return nil
        }
        // Common modes, so notifications still arrive while our menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        current.forEach { track($0) }
        log.info("Watching \(app.name, privacy: .public) with \(self.windows.count) windows")
    }

    func stop() {
        pendingCheck?.cancel()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func handle(_ notification: String, for element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            track(element)
        case kAXUIElementDestroyedNotification:
            // The app's registration fires for anything it removes, not just windows, so only a
            // tracked window counts. Matching is enough here; the check before quitting looks harder.
            guard let index = windows.firstIndex(where: { CFEqual($0, element) }) else { return }
            windows.remove(at: index)
            log.info("A window of \(self.app.name, privacy: .public) closed, \(self.windows.count) left")
            if windows.isEmpty { scheduleCheck() }
        default:
            break
        }
    }

    /// Starts following a window if it's one you can close, not a panel, popover, tooltip or a
    /// splash screen, which has no close button. A window that has only just been created may
    /// not say what it is yet, so it gets a second look.
    private func track(_ window: AXUIElement, retry: Bool = true) {
        guard !windows.contains(where: { CFEqual($0, window) }) else { return }
        if isRealWindow(window) && hasAttribute(window, kAXCloseButtonAttribute) {
            windows.append(window)
            pendingCheck?.cancel()
            let result = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
            log.info("Tracking a window of \(self.app.name, privacy: .public): \(result.rawValue)")
        } else if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.track(window, retry: false) }
            }
        }
    }

    private func isRealWindow(_ window: AXUIElement) -> Bool {
        let subrole: String? = attribute(window, kAXSubroleAttribute)
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.app.isTerminated, self.hasNoWindowsLeft() else { return }
                self.watcher.lastWindowClosed(in: self.app)
            }
        }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowWatcher.settleDelay, execute: check)
    }

    /// Looks again right before quitting, in case a window opened that we weren't told about.
    /// A window without a close button, like an alert, also keeps the app running here, so an
    /// app isn't quit while it's asking something. When the app doesn't answer, it's left alone.
    private func hasNoWindowsLeft() -> Bool {
        guard let current = currentWindows() else {
            log.error("\(self.app.name, privacy: .public) didn't say which windows it has")
            return false
        }
        windows.removeAll { !isAlive($0) }
        current.forEach { track($0, retry: false) }
        let empty = windows.isEmpty && !current.contains(where: isRealWindow)
        log.info("\(self.app.name, privacy: .public) has \(self.windows.count) tracked and \(current.count) listed windows")
        return empty
    }

    private func currentWindows() -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        if result == .noValue { return [] }
        guard result == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }

    private func isAlive(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    private func hasAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success && value != nil
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

private func axCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watched = Unmanaged<WatchedApp>.fromOpaque(refcon).takeUnretainedValue()
    // The observer's run loop source is on the main run loop.
    MainActor.assumeIsolated { watched.handle(notification as String, for: element) }
}

private extension NSRunningApplication {
    var name: String { localizedName ?? bundleIdentifier ?? "pid \(processIdentifier)" }
}
