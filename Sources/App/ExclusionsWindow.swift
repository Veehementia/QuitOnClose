import AppKit
import UniformTypeIdentifiers

/// The window that lists the excluded apps, with buttons to add and remove them.
@MainActor
final class ExclusionsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let exclusions: Exclusions
    private var window: NSWindow!
    private let table = DeletableTableView()
    private let emptyLabel = NSTextField(labelWithString: NSLocalizedString("No excluded apps", comment: "Empty list"))
    private let buttons = NSSegmentedControl(
        images: [NSImage(named: NSImage.addTemplateName)!, NSImage(named: NSImage.removeTemplateName)!],
        trackingMode: .momentary, target: nil, action: nil
    )
    private var apps: [AppInfo] = []

    private static let width: CGFloat = 420
    private static let margin: CGFloat = 20

    init(exclusions: Exclusions) {
        self.exclusions = exclusions
        super.init()
        buildWindow()
        reload()
        NotificationCenter.default.addObserver(forName: Exclusions.didChange, object: exclusions, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let innerWidth = Self.width - 2 * Self.margin

        let explanation = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "These apps keep running after you close their last window. Finder always does.",
            comment: "Explains the excluded apps list"
        ))
        explanation.isSelectable = false
        explanation.preferredMaxLayoutWidth = innerWidth

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.allowsMultipleSelection = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.onDelete = { [weak self] in self?.removeSelected() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor).isActive = true
        emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor).isActive = true

        buttons.target = self
        buttons.action = #selector(buttonClicked(_:))
        buttons.setToolTip(NSLocalizedString("Add an App", comment: "Button tooltip"), forSegment: 0)
        buttons.setToolTip(NSLocalizedString("Remove the Selected Apps", comment: "Button tooltip"), forSegment: 1)

        let content = NSStackView(views: [explanation, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("Excluded Apps", comment: "Window title")
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
    }

    private func reload() {
        apps = exclusions.bundleIDs.map(AppInfo.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        table.reloadData()
        emptyLabel.isHidden = !apps.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        buttons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    @objc private func buttonClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { showAddMenu() } else { removeSelected() }
    }

    private func removeSelected() {
        exclusions.remove(table.selectedRowIndexes.map { apps[$0].bundleID })
    }

    /// Offers the running apps that aren't excluded yet, and a way to pick any other app.
    private func showAddMenu() {
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
                return id != Bundle.main.bundleIdentifier && !exclusions.contains(id)
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        for app in running {
            let item = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier!, action: #selector(addRunningApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            item.image = app.icon.map(resized)
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        let choose = NSMenuItem(title: NSLocalizedString("Choose an App…", comment: "Menu item"), action: #selector(chooseApp), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)

        let y = buttons.isFlipped ? buttons.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: buttons)
    }

    @objc private func addRunningApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        exclusions.add([id])
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = NSLocalizedString("Exclude", comment: "Open panel button")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                self?.exclusions.add(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
            }
        }
    }

    private func resized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("AppCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
        let app = apps[row]
        cell.imageView?.image = app.icon
        cell.textField?.stringValue = app.name
        cell.toolTip = app.bundleID
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        for view in [image, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = image
        cell.textField = text
        return cell
    }
}

/// A table that removes its selected rows when you press Delete.
private final class DeletableTableView: NSTableView {
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        if key == NSDeleteCharacter || key == NSDeleteFunctionKey, !selectedRowIndexes.isEmpty {
            onDelete()
        } else {
            super.keyDown(with: event)
        }
    }
}
