import AppKit
import Combine
import SwiftUI

/// Draws the menu bar icon. Sits on top of the status button and lets clicks through.
final class StatusIconView: NSView {
    var model = MenuBarModel() {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MenuBarRenderer.draw(model, in: ctx, bounds: bounds, appearance: effectiveAppearance)
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: ProtectStore
    private let actions: AppActions
    private let statusItem: NSStatusItem
    private let iconView = StatusIconView()
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    init(store: ProtectStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarRenderer.width(for: MenuBarModel()))
        super.init()

        statusItem.autosaveName = "ProtectCamerasStatusItem"
        if let button = statusItem.button {
            iconView.frame = button.bounds
            iconView.autoresizingMask = [.width, .height]
            button.addSubview(iconView)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        var popoverActions = actions
        popoverActions.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            actions.openSettings()
        }
        popoverActions.closePopover = { [weak self] in self?.popover.performClose(nil) }
        popoverActions.openWeb = { [weak self] url in
            self?.popover.performClose(nil)
            actions.openWeb(url)
        }
        let host = NSHostingController(rootView: PopoverView(store: store, actions: popoverActions))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        update()
    }

    func update() {
        let model = MenuBarModel.make(store: store)
        iconView.model = model
        let width = MenuBarRenderer.width(for: model)
        if abs(statusItem.length - width) > 0.5 { statusItem.length = width }

        var parts: [String] = []
        if let error = store.error {
            parts.append(error.title)
        } else if store.lastFetched == nil {
            parts.append("connecting…")
        } else {
            let offline = store.cameras.filter { !$0.isConnected }.count
            parts.append("\(store.cameras.count) camera\(store.cameras.count == 1 ? "" : "s")"
                         + (offline > 0 ? ", \(offline) offline" : ""))
            if !store.isLive { parts.append("not receiving events") }
            if store.unseenCount > 0 { parts.append("\(store.unseenCount) new event\(store.unseenCount == 1 ? "" : "s")") }
        }
        if let until = Prefs.snoozedUntil { parts.append("notifications paused until \(Fmt.time(until))") }
        let summary = "Protect: " + parts.joined(separator: " · ")
        statusItem.button?.toolTip = summary
        statusItem.button?.setAccessibilityLabel(summary)
    }

    /// Opens the popover on one camera, e.g. from a notification.
    func show(camera cameraID: String?) {
        store.focusedCamera = cameraID
        if !popover.isShown { openPopover() }
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            store.focusedCamera = nil
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        store.popoverVisible = true
        if let fetched = store.lastFetched, Date().timeIntervalSince(fetched) < 60 {} else {
            Task { await store.refresh() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverVisible = false
        // Everything that was in the list while it was open counts as seen.
        store.markSeen()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Refresh Now", #selector(menuRefresh), key: "r"))
        menu.addItem(item("Open Protect in Browser", #selector(menuOpenWeb)))
        menu.addItem(.separator())
        if let until = Prefs.snoozedUntil {
            menu.addItem(item("Resume Notifications (paused until \(Fmt.time(until)))", #selector(menuResume)))
        } else {
            let pause = NSMenuItem(title: "Pause Notifications", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for option in SnoozeOption.allCases {
                let entry = item(option.title, #selector(menuSnooze(_:)))
                entry.representedObject = option.rawValue
                submenu.addItem(entry)
            }
            pause.submenu = submenu
            menu.addItem(pause)
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(menuSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Protect Cameras", #selector(menuQuit), key: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuRefresh() { actions.refresh() }
    @objc private func menuOpenWeb() { actions.openWeb(nil) }
    @objc private func menuSettings() { actions.openSettings() }
    @objc private func menuQuit() { actions.quit() }
    @objc private func menuResume() { Prefs.snooze(until: nil) }
    @objc private func menuSnooze(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = SnoozeOption(rawValue: raw) else { return }
        Prefs.snooze(until: option.until())
    }
}

enum SnoozeOption: String, CaseIterable, Identifiable {
    case thirtyMinutes, oneHour, fourHours, tomorrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirtyMinutes: "For 30 Minutes"
        case .oneHour: "For 1 Hour"
        case .fourHours: "For 4 Hours"
        case .tomorrow: "Until Tomorrow Morning"
        }
    }

    func until(from now: Date = Date()) -> Date {
        switch self {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(3600)
        case .fourHours: return now.addingTimeInterval(4 * 3600)
        case .tomorrow:
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }
}
