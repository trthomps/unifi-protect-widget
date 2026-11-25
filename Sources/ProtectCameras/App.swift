import AppKit
import SwiftUI

@main
enum ProtectCamerasApp {
    @MainActor
    static func main() {
        Prefs.registerDefaults()
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            Protect Cameras — menu bar app for UniFi Protect cameras and events

              ProtectCameras                        run the menu bar app
              ProtectCameras --print                print cameras and recent events, then exit
              ProtectCameras --watch                stream live events to the terminal (Ctrl-C to stop)
              ProtectCameras --snapshot NAME FILE   save a camera's snapshot as JPEG
              ProtectCameras --render-icon DIR      render an .iconset for the app icon
              ProtectCameras --render-previews DIR  render menu bar icon PNGs
              ProtectCameras --render-popover FILE [--tab events] [--camera NAME]
                                                    render the popover with live data to a PNG
                                                    (development aid; shows your camera images)

            Uses the console and API key saved in the app's Settings.
            """)
            return
        }
        if args.contains("--print") { exit(CLI.printSummary()) }
        if args.contains("--watch") { exit(CLI.watch()) }
        if let index = args.firstIndex(of: "--snapshot"), index + 2 < args.count {
            exit(CLI.saveSnapshot(camera: args[index + 1], to: args[index + 2]))
        }
        if let path = value(after: "--render-popover", in: args) {
            _ = NSApplication.shared
            let tab = PopoverTab(rawValue: value(after: "--tab", in: args) ?? "") ?? .cameras
            exit(CLI.renderPopover(to: path, tab: tab, camera: value(after: "--camera", in: args)))
        }
        if let dir = value(after: "--render-icon", in: args) {
            AppIcon.renderIconset(to: dir)
            return
        }
        if let dir = value(after: "--render-previews", in: args) {
            _ = NSApplication.shared
            CLI.renderPreviews(to: dir)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

struct AppActions {
    var refresh: () -> Void
    var openWeb: (URL?) -> Void
    var openSettings: () -> Void
    var closePopover: () -> Void = {}
    var quit: () -> Void
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProtectStore()
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = AppActions(
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.store.refresh(userInitiated: true) }
                if self.store.popoverVisible { self.store.refreshSnapshots(highQuality: false) }
            },
            openWeb: { [weak self] url in
                if let url = url ?? self?.store.webURL { NSWorkspace.shared.open(url) }
            },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        )

        let status = StatusItemController(store: store, actions: actions)
        statusController = status
        SystemNotifier.setUp { [weak self] eventID, cameraID in
            guard let self else { return }
            let event = self.store.events.first { $0.id == eventID }
            if Prefs.notificationClick == .web, let event, let url = self.store.webURL(for: event) {
                NSWorkspace.shared.open(url)
            } else {
                status.show(camera: cameraID ?? event?.cameraID)
            }
        }
        if Prefs.notificationsEnabled {
            Task {
                // Ask once up front: the point of the app is not missing the doorbell.
                if await SystemNotifier.authorizationStatus() == .notDetermined {
                    _ = await SystemNotifier.requestAuthorization()
                }
            }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.preferencesChanged()
                self?.statusController?.update()
            }
        }

        store.start()
        if !store.isConfigured { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings. That's the way in
    /// when a menu bar manager has hidden the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store)
        }
        settingsController?.show()
    }
}

/// `PROTECT_CAMERAS_DEBUG=1` prints diagnostics to stderr.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["PROTECT_CAMERAS_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[ProtectCameras] \(message())\n".utf8))
    }
}
