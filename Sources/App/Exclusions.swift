import AppKit

/// The apps that keep running after their last window closes, saved by bundle identifier.
@MainActor
final class Exclusions {
    static let didChange = Notification.Name("ExclusionsDidChange")
    /// Finder is the desktop, so it always stays, whatever the list says.
    static let alwaysKept: Set<String> = ["com.apple.finder"]

    private static let key = "excludedBundleIDs"
    private(set) var bundleIDs: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []

    func contains(_ bundleID: String) -> Bool {
        Self.alwaysKept.contains(bundleID) || bundleIDs.contains(bundleID)
    }

    func add(_ ids: [String]) {
        let new = ids.filter { !contains($0) }
        guard !new.isEmpty else { return }
        bundleIDs.append(contentsOf: new)
        save()
    }

    func remove(_ ids: [String]) {
        bundleIDs.removeAll { ids.contains($0) }
        save()
    }

    func toggle(_ bundleID: String) {
        contains(bundleID) ? remove([bundleID]) : add([bundleID])
    }

    private func save() {
        UserDefaults.standard.set(bundleIDs, forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// An app's name and icon, found from its bundle identifier.
struct AppInfo {
    let bundleID: String
    let name: String
    let icon: NSImage

    init(bundleID: String) {
        self.bundleID = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            self.name = name
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            // The app was deleted or moved somewhere Launch Services doesn't know about.
            name = bundleID
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }
}
