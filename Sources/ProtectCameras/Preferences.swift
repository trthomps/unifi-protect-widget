import AppKit
import SwiftUI

enum IconColor: String, CaseIterable, Identifiable {
    case monochrome, color
    var id: String { rawValue }
    var title: String { self == .color ? "Blue" : "Monochrome" }
}

enum BadgeStyle: String, CaseIterable, Identifiable {
    case badge, dot, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .badge: "Count"
        case .dot: "Dot"
        case .none: "None"
        }
    }
}

enum ClickAction: String, CaseIterable, Identifiable {
    case popover, web
    var id: String { rawValue }
    var title: String { self == .popover ? "Show the camera here" : "Open it in Protect" }
}

enum PrefKey {
    static let host = "host"
    static let pinnedFingerprints = "pinnedFingerprints"

    static let iconColor = "iconColor"
    static let badgeStyle = "badgeStyle"
    static let gridRefresh = "gridRefreshSeconds"
    static let notificationClick = "notificationClick"
    static let showMotionInList = "showMotionInList"

    static let notificationsEnabled = "notificationsEnabled"
    static let notifyKinds = "notifyKinds"
    static let mutedCameras = "mutedCameras"
    static let cooldown = "notifyCooldownSeconds"
    static let ringSound = "ringSound"
    static let snoozedUntil = "snoozedUntil"
    static let lastSeen = "lastSeenEvents"
    static let popoverTab = "popoverTab"
}

/// Typed access to UserDefaults. SwiftUI binds to the same keys with @AppStorage.
enum Prefs {
    static let bundleID = "io.github.trthomps.protect-cameras"

    /// Inside the app this is `.standard`. A bare binary (`swift run`, the CLI flags) has no
    /// bundle ID, so point it at the app's domain to share its settings.
    static let store: UserDefaults = Bundle.main.bundleIdentifier == nil
        ? (UserDefaults(suiteName: bundleID) ?? .standard) : .standard

    static let defaultKinds = EventKind.allCases.filter(\.notifyByDefault).map(\.rawValue).joined(separator: ",")

    static func registerDefaults() {
        store.register(defaults: [
            PrefKey.host: "",
            PrefKey.iconColor: IconColor.monochrome.rawValue,
            PrefKey.badgeStyle: BadgeStyle.badge.rawValue,
            PrefKey.gridRefresh: 5.0,
            PrefKey.notificationClick: ClickAction.popover.rawValue,
            PrefKey.showMotionInList: false,
            PrefKey.notificationsEnabled: true,
            PrefKey.notifyKinds: defaultKinds,
            PrefKey.mutedCameras: "",
            PrefKey.cooldown: 60.0,
            PrefKey.ringSound: true,
            PrefKey.snoozedUntil: 0.0,
            PrefKey.lastSeen: 0.0,
            PrefKey.popoverTab: "cameras",
        ])
    }

    static var host: String { store.string(forKey: PrefKey.host) ?? "" }
    static var hostURL: URL? { ProtectAPI.normalizedHost(host) }

    /// Trusted certificate fingerprints, keyed by console URL.
    static func pinnedFingerprint(for host: URL) -> String? {
        (store.dictionary(forKey: PrefKey.pinnedFingerprints) as? [String: String])?[host.absoluteString]
    }

    static func setPinnedFingerprint(_ fingerprint: String?, for host: URL) {
        var all = (store.dictionary(forKey: PrefKey.pinnedFingerprints) as? [String: String]) ?? [:]
        all[host.absoluteString] = fingerprint
        store.set(all, forKey: PrefKey.pinnedFingerprints)
    }

    static var iconColor: IconColor { IconColor(rawValue: store.string(forKey: PrefKey.iconColor) ?? "") ?? .monochrome }
    static var badgeStyle: BadgeStyle { BadgeStyle(rawValue: store.string(forKey: PrefKey.badgeStyle) ?? "") ?? .badge }
    static var gridRefresh: TimeInterval { max(2, store.double(forKey: PrefKey.gridRefresh)) }
    static var notificationClick: ClickAction {
        ClickAction(rawValue: store.string(forKey: PrefKey.notificationClick) ?? "") ?? .popover
    }
    static var showMotionInList: Bool { store.bool(forKey: PrefKey.showMotionInList) }

    static var notificationsEnabled: Bool { store.bool(forKey: PrefKey.notificationsEnabled) }
    static var notifyKinds: Set<EventKind> {
        Set((store.string(forKey: PrefKey.notifyKinds) ?? defaultKinds).split(separator: ",")
            .compactMap { EventKind(rawValue: String($0)) })
    }
    static var mutedCameras: Set<String> {
        Set((store.string(forKey: PrefKey.mutedCameras) ?? "").split(separator: ",").map(String.init))
    }
    static var cooldown: TimeInterval { max(0, store.double(forKey: PrefKey.cooldown)) }
    static var ringSound: Bool { store.bool(forKey: PrefKey.ringSound) }

    static var snoozedUntil: Date? {
        let value = store.double(forKey: PrefKey.snoozedUntil)
        guard value > 0 else { return nil }
        let date = Date(timeIntervalSince1970: value)
        return date > Date() ? date : nil
    }

    static func snooze(until date: Date?) {
        store.set(date?.timeIntervalSince1970 ?? 0, forKey: PrefKey.snoozedUntil)
    }

    static var lastSeen: Date {
        get { Date(timeIntervalSince1970: store.double(forKey: PrefKey.lastSeen)) }
        set { store.set(newValue.timeIntervalSince1970, forKey: PrefKey.lastSeen) }
    }
}

/// Secrets in the login Keychain, written and read through `/usr/bin/security`. Items made by
/// that tool trust it, so reads never prompt, even after the app is rebuilt and re-signed.
/// Writes go over stdin (`security -i`) so secrets never show up in a process listing.
enum SecretStore {
    static let service = Prefs.bundleID

    static func apiKeyAccount(_ host: URL) -> String { "apikey:\(host.absoluteString)" }

    static func read(_ account: String) -> String? {
        let (status, output) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard status == 0 else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    @discardableResult
    static func write(_ account: String, _ secret: String) -> Bool {
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(sanitize(account))\" -X \(hex)\n"
        let (status, _) = run(["-i"], stdin: command)
        return status == 0 && read(account) == secret
    }

    static func delete(_ account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func sanitize(_ text: String) -> String {
        text.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline }
    }

    private static func run(_ arguments: [String], stdin: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do { try process.run() } catch { return (-1, "") }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

extension NSColor {
    /// UniFi's blue (#006FFF).
    static let unifiBlue = NSColor(srgbRed: 0, green: 0.435, blue: 1, alpha: 1)
}

extension Color {
    static let unifiBlue = Color(nsColor: .unifiBlue)
}
