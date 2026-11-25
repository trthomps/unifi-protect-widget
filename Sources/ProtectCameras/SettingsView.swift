import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class SettingsWindowController {
    private let store: ProtectStore
    private var window: NSWindow?

    init(store: ProtectStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Protect Cameras Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: String, Hashable {
    case general, console, notifications
}

struct SettingsView: View {
    @ObservedObject var store: ProtectStore
    @State private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ConsoleSettings(store: store)
                .tabItem { Label("Console", systemImage: "server.rack") }
                .tag(SettingsTab.console)
            NotificationSettings(store: store)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(SettingsTab.notifications)
        }
        .frame(width: 540, height: 620)
        .onAppear {
            if store.error == .notConfigured || store.error?.isCertificateProblem == true { tab = .console }
        }
    }
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var store: ProtectStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.iconColor) private var iconColor: IconColor = .monochrome
    @AppStorage(PrefKey.badgeStyle) private var badgeStyle: BadgeStyle = .badge
    @AppStorage(PrefKey.gridRefresh) private var gridRefresh: Double = 5
    @AppStorage(PrefKey.showMotionInList) private var showMotion = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Menu bar icon") {
                HStack(spacing: 10) {
                    ForEach(IconColor.allCases) { candidate in
                        tile(candidate.title, selected: candidate == iconColor,
                             image: preview(color: candidate, badge: badgeStyle))
                            .onTapGesture { iconColor = candidate }
                    }
                }
                .padding(.vertical, 4)
                Picker("New events", selection: $badgeStyle) {
                    ForEach(BadgeStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                note("The badge counts events you'd be notified about that arrived since you last opened the popover. The icon dims while the app isn't receiving events.")
            }

            Section("Popover") {
                Picker("Refresh camera snapshots every", selection: $gridRefresh) {
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
                note("Only while the popover is open. A camera you click on refreshes about once a second in high quality.")
                Toggle("Show plain motion in the event list", isOn: $showMotion)
            }

            Section("Event log") {
                HStack {
                    Text("\(store.events.count) events from the last 7 days")
                    Spacer()
                    Button("Clear…") { confirmClear = true }
                        .disabled(store.events.isEmpty)
                }
                note("Protect's API sends events as they happen but can't list past ones, so the list only covers time when this app was running and connected.")
            }
            .confirmationDialog("Clear the event log and its thumbnails?", isPresented: $confirmClear) {
                Button("Clear", role: .destructive) { store.clearLog() }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError { note(loginError).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
    }

    private func preview(color: IconColor, badge: BadgeStyle) -> NSImage {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        let model = MenuBarModel(state: .ok, count: max(store.unseenCount, 3), color: color, badge: badge)
        return MenuBarRenderer.image(for: model, appearance: appearance)
    }

    private func tile(_ title: String, selected: Bool, image: NSImage) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.95)))
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Console

private struct ConsoleSettings: View {
    @ObservedObject var store: ProtectStore
    @AppStorage(PrefKey.host) private var savedHost = ""
    @State private var hostDraft = ""
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("Console", text: $hostDraft, prompt: Text("192.168.1.1 or unifi.example.com"))
                SecureField("API key", text: $keyDraft, prompt: Text(hasKey && draftURL == savedURL ? "•••••••• (saved)" : "Paste a Protect API key"))
                HStack {
                    if hasKey, draftURL == savedURL {
                        Button("Remove Key", role: .destructive, action: removeKey)
                    }
                    Spacer()
                    Button(keyDraft.isEmpty && hasKey && draftURL == savedURL ? "Reconnect" : "Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draftURL == nil || (keyDraft.isEmpty && !(hasKey && draftURL == savedURL)))
                }
                if let message { note(message) }
                note("If your console has a real certificate for a hostname, use that name. With an IP address or the built-in self-signed certificate, the app asks you to confirm the certificate's fingerprint once.")
                note("Create a key in Protect: Settings → Control Plane → Integrations → Create API Key (UniFi OS 4.1 / Protect 5.3 or later). The key is stored in your Keychain. The app only reads from Protect: it never changes settings or arms anything.")
            } header: {
                Text("Console")
            }

            if let error = store.error, let fingerprint = error.fingerprint {
                Section {
                    Label(error.title, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    note(error == .untrustedCertificate(fingerprint)
                         ? "\(store.hostURL?.host ?? "The console") presented a certificate macOS doesn't trust, which is normal for a UniFi console's built-in self-signed one. Compare this SHA-256 fingerprint with the one your browser shows for the console (click the lock or warning icon in the address bar → certificate details), then trust it. The app will only accept this exact certificate from now on."
                         : "The console's certificate changed since you trusted it. That's expected after a console reset, a firmware update that regenerated it, or installing your own. Otherwise, something may be intercepting the connection.")
                    Text(fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Trust This Certificate") { trust(fingerprint) }
                    }
                } header: {
                    Text("Certificate")
                }
            } else if let host = store.hostURL, let pinned = Prefs.pinnedFingerprint(for: host) {
                Section {
                    LabeledContent("Trusted certificate") {
                        Text(pinned.prefix(23) + "…").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    .help(pinned)
                    HStack {
                        Spacer()
                        Button("Forget") {
                            Prefs.setPinnedFingerprint(nil, for: host)
                            store.accountChanged()
                        }
                    }
                } header: {
                    Text("Certificate")
                }
            }

            Section("Status") {
                if let error = store.error {
                    LabeledContent("Status", value: error.title)
                    if !error.isCertificateProblem { note(error.message) }
                } else if store.lastFetched == nil {
                    LabeledContent("Status", value: store.hostURL == nil ? "Not set up" : "Connecting…")
                } else {
                    LabeledContent("Status", value: store.isLive ? "Connected, receiving events" : "Connected, event stream reconnecting")
                    if !store.isLive, let socketError = store.socketError { note("\(socketError.title): \(socketError.message)") }
                }
                if let name = store.console?.name { LabeledContent("Console", value: name) }
                if let version = store.console?.protectVersion { LabeledContent("Protect", value: version) }
                if !store.cameras.isEmpty {
                    let offline = store.cameras.filter { !$0.isConnected }.count
                    LabeledContent("Cameras", value: "\(store.cameras.count)" + (offline > 0 ? " (\(offline) offline)" : ""))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hostDraft = savedHost
            reloadKeyState()
        }
    }

    private var draftURL: URL? { ProtectAPI.normalizedHost(hostDraft) }
    private var savedURL: URL? { ProtectAPI.normalizedHost(savedHost) }

    private func reloadKeyState() {
        hasKey = savedURL.flatMap { SecretStore.read(SecretStore.apiKeyAccount($0)) } != nil
    }

    private func connect() {
        guard let url = draftURL else { return }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard SecretStore.write(SecretStore.apiKeyAccount(url), key) else {
                message = "Couldn't save the key to the Keychain."
                return
            }
        } else if SecretStore.read(SecretStore.apiKeyAccount(url)) == nil {
            message = "Paste an API key for this console."
            return
        }
        keyDraft = ""
        message = nil
        hostDraft = url.absoluteString
        savedHost = url.absoluteString
        reloadKeyState()
        store.accountChanged()
    }

    private func trust(_ fingerprint: String) {
        guard let host = store.hostURL else { return }
        Prefs.setPinnedFingerprint(fingerprint, for: host)
        store.accountChanged()
    }

    private func removeKey() {
        guard let url = savedURL else { return }
        SecretStore.delete(SecretStore.apiKeyAccount(url))
        reloadKeyState()
        store.accountChanged()
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @ObservedObject var store: ProtectStore
    @AppStorage(PrefKey.notificationsEnabled) private var enabled = true
    @AppStorage(PrefKey.notifyKinds) private var kindsRaw = Prefs.defaultKinds
    @AppStorage(PrefKey.mutedCameras) private var mutedRaw = ""
    @AppStorage(PrefKey.cooldown) private var cooldown: Double = 60
    @AppStorage(PrefKey.ringSound) private var ringSound = true
    @AppStorage(PrefKey.notificationClick) private var click: ClickAction = .popover
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                Toggle("Show macOS notifications for Protect events", isOn: $enabled)
                    .disabled(!SystemNotifier.available)
                    .onChange(of: enabled) { _, on in
                        guard on else { return }
                        Task {
                            _ = await SystemNotifier.requestAuthorization()
                            status = await SystemNotifier.authorizationStatus()
                        }
                    }
                if !SystemNotifier.available {
                    note("macOS notifications need the app bundle (make app), not swift run.")
                } else if status == .denied {
                    HStack {
                        note("Notifications are turned off for Protect Cameras in System Settings.")
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
                if let until = Prefs.snoozedUntil {
                    HStack {
                        note("Paused until \(Fmt.time(until)).")
                        Spacer()
                        Button("Resume") { Prefs.snooze(until: nil) }.controlSize(.small)
                    }
                }
            }

            Section {
                ForEach(EventKind.allCases.filter { $0 != .other }) { kind in
                    Toggle(isOn: kindBinding(kind)) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
                note("What Protect can detect depends on the camera and on the detections turned on in Protect. Plain motion fires a lot, so it's off by default.")
            } header: {
                Text("Notify me about")
            }
            .disabled(!enabled)

            if !store.cameras.isEmpty {
                Section {
                    ForEach(store.cameras) { camera in
                        Toggle(isOn: cameraBinding(camera.id)) {
                            HStack(spacing: 6) {
                                Text(camera.name)
                                if camera.isDoorbell {
                                    Text("doorbell").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Cameras")
                }
                .disabled(!enabled)
            }

            Section {
                Picker("Don't repeat for the same camera within", selection: $cooldown) {
                    Text("No limit").tag(0.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                note("Per camera and per kind, so a person walking around the yard is one notification, not ten. Doorbell rings repeat after 10 seconds at most.")
                Toggle("Play a sound for doorbell rings", isOn: $ringSound)
                Picker("Clicking a notification", selection: $click) {
                    ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Spacer()
                    Button("Send Test Notification", action: sendTest)
                        .disabled(!SystemNotifier.available || store.cameras.isEmpty)
                }
            } header: {
                Text("Behavior")
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .task { status = await SystemNotifier.authorizationStatus() }
    }

    private var kinds: Set<String> { Set(kindsRaw.split(separator: ",").map(String.init)) }

    private func kindBinding(_ kind: EventKind) -> Binding<Bool> {
        Binding(
            get: { kinds.contains(kind.rawValue) },
            set: { on in
                var set = kinds
                if on { set.insert(kind.rawValue) } else { set.remove(kind.rawValue) }
                kindsRaw = EventKind.allCases.map(\.rawValue).filter(set.contains).joined(separator: ",")
            }
        )
    }

    private func cameraBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !Set(mutedRaw.split(separator: ",").map(String.init)).contains(id) },
            set: { on in
                var set = Set(mutedRaw.split(separator: ",").map(String.init))
                if on { set.remove(id) } else { set.insert(id) }
                mutedRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    /// Posts a fake person detection from the first doorbell (or camera) with a live snapshot.
    private func sendTest() {
        guard let camera = store.cameras.first(where: \.isDoorbell) ?? store.cameras.first else { return }
        Task {
            if await SystemNotifier.authorizationStatus() == .notDetermined {
                _ = await SystemNotifier.requestAuthorization()
            }
            let event = ProtectEvent(id: "test-\(UUID().uuidString)", type: "smartDetectZone", start: Date(),
                                     cameraID: camera.id, smartDetectTypes: ["person"], cameraName: camera.name)
            var attachment: URL?
            if let data = await store.fetchSnapshot(camera.id, highQuality: false) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("protect-test.jpg")
                if (try? data.write(to: url)) != nil { attachment = url }
            }
            SystemNotifier.post(event, thumbnail: attachment, sound: true)
        }
    }
}
