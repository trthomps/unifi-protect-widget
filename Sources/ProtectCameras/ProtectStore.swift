import AppKit
import Combine
import Network

struct Snapshot {
    var image: NSImage
    var takenAt: Date
    var highQuality: Bool
}

/// Talks to the console, keeps the camera list and event log, fetches snapshots, and
/// decides which events become notifications.
@MainActor
final class ProtectStore: ObservableObject {
    @Published private(set) var cameras: [Camera] = []
    /// Newest first.
    @Published private(set) var events: [ProtectEvent] = []
    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published private(set) var snapshotErrors: [String: String] = [:]
    @Published private(set) var error: ProtectError?
    @Published private(set) var socketError: ProtectError?
    @Published private(set) var isLive = false
    @Published private(set) var console: ConsoleInfo?
    @Published private(set) var lastFetched: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var unseenCount = 0
    @Published private(set) var now = Date()
    @Published private(set) var hostURL: URL?
    /// Camera shown large in the popover, if any.
    @Published var focusedCamera: String? {
        didSet { if oldValue != focusedCamera { updateFeeds() } }
    }
    /// Set by the status item controller and popover; together they decide which snapshot
    /// feeds run. Nothing is fetched while the popover is closed.
    var popoverVisible = false { didSet { updateFeeds() } }
    var gridTabShown = true { didSet { updateFeeds() } }

    private var connection: ProtectConnection?
    private var eventsSocket: ProtectSocket?
    private var devicesSocket: ProtectSocket?
    private var generation = 0
    private var refreshingGeneration: Int?
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var gridTimer: Timer?
    private var focusLoop: Task<Void, Never>?
    private var focusLoopCamera: String?
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var wasOnline = true
    private var inFlightSnapshots: [String: Task<Data?, Never>] = [:]
    private var lastNotified: [String: Date] = [:]
    private var saveWork: DispatchWorkItem?

    /// For the CLI's renderer: never write the log or post notifications.
    var readOnly = false

    static let maxEvents = 500
    static let maxAge: TimeInterval = 7 * 24 * 3600

    init() {
        events = Self.loadLog()
        recountUnseen()
    }

    var isConfigured: Bool { Prefs.hostURL.flatMap { SecretStore.read(SecretStore.apiKeyAccount($0)) } != nil }

    func camera(_ id: String?) -> Camera? {
        guard let id else { return nil }
        return cameras.first { $0.id == id }
    }

    /// Events the list shows (plain motion only when asked for).
    var visibleEvents: [ProtectEvent] {
        let motion = Prefs.showMotionInList
        return events.filter { motion || $0.primaryKind != .motion }
    }

    func events(for cameraID: String) -> [ProtectEvent] {
        visibleEvents.filter { $0.cameraID == cameraID }
    }

    /// The most urgent detection still going on at this camera, for the grid's highlight.
    func activeKind(for cameraID: String) -> EventKind? {
        let motion = Prefs.showMotionInList
        let active = events.prefix(40).filter {
            $0.cameraID == cameraID && $0.isActive && (motion || $0.primaryKind != .motion)
        }
        return EventKind.priority.first { kind in active.contains { $0.kinds.contains(kind) } }
    }

    // MARK: - Lifecycle

    func start() {
        let poll = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refresh() } }
        }
        poll.tolerance = 30
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        let clock = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        clock.tolerance = 5
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    MainActor.assumeIsolated { self?.reconnectSoon() }
                }
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    defer { self.wasOnline = online }
                    if online, !self.wasOnline || !self.isLive { self.reconnectSoon() }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "protect-cameras.path"))

        connect()
    }

    /// Host, key or certificate changed: drop everything tied to the old console and start over.
    func accountChanged() {
        connect()
    }

    private func connect() {
        generation += 1
        eventsSocket?.stop()
        devicesSocket?.stop()
        eventsSocket = nil
        devicesSocket = nil
        stopFocus()
        gridTimer?.invalidate()
        gridTimer = nil
        connection = nil
        snapshots = [:]
        snapshotErrors = [:]
        socketError = nil
        isLive = false
        lastFetched = nil

        guard let host = Prefs.hostURL, let key = SecretStore.read(SecretStore.apiKeyAccount(host)) else {
            hostURL = Prefs.hostURL
            cameras = []
            console = nil
            error = .notConfigured
            return
        }
        if hostURL != host {
            cameras = []
            console = nil
        }
        hostURL = host
        error = nil
        connection = ProtectConnection(baseURL: host, apiKey: key, pinnedFingerprint: Prefs.pinnedFingerprint(for: host))
        updateFeeds()
        Task { await refresh(userInitiated: true) }
    }

    /// After wake or a network change an "open" socket may be half-open, so replace it anyway.
    private func reconnectSoon() {
        guard connection != nil else { return }
        Task { await refresh() }
        eventsSocket?.reconnectNow(force: true)
        devicesSocket?.reconnectNow(force: true)
    }

    // MARK: - Fetching

    func refresh(userInitiated: Bool = false) async {
        // A refresh still running for a previous console doesn't block one for the new one.
        guard let connection, refreshingGeneration != generation else { return }
        let started = generation
        refreshingGeneration = started
        isRefreshing = true
        defer {
            if refreshingGeneration == started {
                refreshingGeneration = nil
                isRefreshing = false
            }
            now = Date()
        }
        let api = ProtectAPI(connection: connection)
        do {
            if console == nil || userInitiated {
                let info = try await api.meta()
                guard started == generation else { return }
                console = info
            }
            let fetched = try await api.cameras()
            guard started == generation else { return }
            cameras = fetched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lastFetched = Date()
            error = nil
            startSockets()
            if gridTimer != nil { refreshSnapshots(highQuality: false, onlyStale: true) }
        } catch is CancellationError {
            return
        } catch let failure as ProtectError {
            guard started == generation else { return }
            Debug.log("refresh failed: \(failure)")
            error = failure
        } catch {
            guard started == generation else { return }
            self.error = .network(error.localizedDescription)
        }
    }

    private func startSockets() {
        guard let connection, eventsSocket == nil else { return }
        let started = generation
        let events = ProtectSocket(connection: connection, path: "subscribe/events", onMessage: { [weak self] data in
            guard let self, started == self.generation else { return }
            self.handleEventMessage(data)
        }, onState: { [weak self] state, error in
            guard let self, started == self.generation else { return }
            self.isLive = state == .open
            if state == .open {
                self.socketError = nil
            } else if let error {
                self.socketError = error
                if case .unauthorized = error { self.error = error }
                if error.isCertificateProblem { self.error = error }
            }
        })
        let devices = ProtectSocket(connection: connection, path: "subscribe/devices", onMessage: { [weak self] data in
            guard let self, started == self.generation else { return }
            self.handleDeviceMessage(data)
        }, onState: { _, _ in })
        eventsSocket = events
        devicesSocket = devices
        events.start()
        devices.start()
    }

    // MARK: - Snapshots

    private func updateFeeds() {
        let wantGrid = popoverVisible && focusedCamera == nil && gridTabShown && connection != nil
        if wantGrid != (gridTimer != nil) {
            gridTimer?.invalidate()
            gridTimer = nil
            if wantGrid {
                refreshSnapshots(highQuality: false, onlyStale: true)
                let timer = Timer(timeInterval: Prefs.gridRefresh, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshSnapshots(highQuality: false) }
                }
                timer.tolerance = 0.5
                RunLoop.main.add(timer, forMode: .common)
                gridTimer = timer
            }
        }
        let wantFocus = popoverVisible && connection != nil ? focusedCamera : nil
        if wantFocus != focusLoopCamera {
            stopFocus()
            if let cameraID = wantFocus { startFocus(cameraID) }
        }
    }

    func refreshSnapshots(highQuality: Bool, onlyStale: Bool = false) {
        for camera in cameras where camera.isConnected {
            if onlyStale, let shot = snapshots[camera.id], Date().timeIntervalSince(shot.takenAt) < Prefs.gridRefresh {
                continue
            }
            Task { await fetchSnapshot(camera.id, highQuality: highQuality) }
        }
    }

    /// Fetches a snapshot, or joins the fetch already running for that camera, so an event's
    /// thumbnail isn't lost to the grid or focus feed holding the slot.
    @discardableResult
    func fetchSnapshot(_ cameraID: String, highQuality: Bool) async -> Data? {
        if let running = inFlightSnapshots[cameraID] { return await running.value }
        guard connection != nil else { return nil }
        let task = Task { await self.loadSnapshot(cameraID, highQuality: highQuality) }
        inFlightSnapshots[cameraID] = task
        let data = await task.value
        if inFlightSnapshots[cameraID] == task { inFlightSnapshots[cameraID] = nil }
        return data
    }

    private func loadSnapshot(_ cameraID: String, highQuality: Bool) async -> Data? {
        guard let connection else { return nil }
        let started = generation
        let highQuality = highQuality && camera(cameraID)?.supportsFullHDSnapshot == true
        do {
            let data = try await ProtectAPI(connection: connection).snapshot(cameraID: cameraID, highQuality: highQuality)
            guard started == generation, let image = NSImage(data: data) else { return nil }
            // Don't swap a sharp focused image for a blurrier grid one.
            if let existing = snapshots[cameraID], existing.highQuality, !highQuality,
               focusedCamera == cameraID, Date().timeIntervalSince(existing.takenAt) < 5 {
                return data
            }
            snapshots[cameraID] = Snapshot(image: image, takenAt: Date(), highQuality: highQuality)
            snapshotErrors[cameraID] = nil
            return data
        } catch {
            guard started == generation else { return nil }
            snapshotErrors[cameraID] = (error as? ProtectError)?.title ?? error.localizedDescription
            return nil
        }
    }

    /// Roughly live view: fetch a high-quality snapshot about once a second for one camera.
    private func startFocus(_ cameraID: String) {
        focusLoopCamera = cameraID
        focusLoop = Task { [weak self] in
            while !Task.isCancelled {
                let began = Date()
                await self?.fetchSnapshot(cameraID, highQuality: true)
                let ok = self?.snapshotErrors[cameraID] == nil
                let elapsed = Date().timeIntervalSince(began)
                // On failure (offline, rate-limited) slow down rather than hammer the console.
                try? await Task.sleep(for: .seconds(ok ? max(0.25, 1 - elapsed) : 3))
            }
        }
    }

    private func stopFocus() {
        focusLoop?.cancel()
        focusLoop = nil
        focusLoopCamera = nil
    }

    // MARK: - Events

    private func handleEventMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["type"] as? String,
              let item = object["item"] as? [String: Any],
              item["modelKey"] as? String == "event",
              let id = item["id"] as? String else {
            Debug.log("ignored events message: \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            return
        }
        Debug.log("event \(action): \(String(data: data.prefix(400), encoding: .utf8) ?? "")")

        if let index = events.firstIndex(where: { $0.id == id }) {
            guard action != "remove" else { return }
            var event = events[index]
            let before = Set(event.kinds)
            if item.keys.contains("end") { event.end = Self.date(item["end"]) }
            if let types = item["smartDetectTypes"] as? [String] {
                for type in types where !event.smartDetectTypes.contains(type) { event.smartDetectTypes.append(type) }
            }
            if let type = item["type"] as? String { event.type = type }
            events[index] = event
            if Set(event.kinds) != before {
                // A motion event that turned into a person, say: maybe worth a banner now.
                Task { await announce(id) }
            }
            scheduleSave()
            recountUnseen()
            return
        }

        // Updates carry the whole event, so one that started just before we connected still
        // gets picked up from its first update.
        guard action == "add" || action == "update",
              let type = item["type"] as? String, let start = Self.date(item["start"]) else { return }
        if action == "update", Date().timeIntervalSince(start) > 300 { return }
        let cameraID = item["device"] as? String
        let event = ProtectEvent(
            id: id, type: type, start: start, end: Self.date(item["end"]), cameraID: cameraID,
            smartDetectTypes: item["smartDetectTypes"] as? [String] ?? [],
            cameraName: camera(cameraID)?.name
        )
        // Newest first; an event picked up from a late update may be older than the top one.
        events.insert(event, at: events.firstIndex { $0.start < start } ?? events.endIndex)
        prune()
        recountUnseen()
        scheduleSave()
        Task { await announce(id) }
    }

    /// Grabs a thumbnail (if we don't have one yet) and posts a notification if the rules say so.
    private func announce(_ id: String) async {
        guard let event = events.first(where: { $0.id == id }) else { return }
        let listed = Prefs.showMotionInList || event.primaryKind != .motion
        let notify = shouldNotify(event)
        guard listed || notify else { return }

        if !event.hasThumbnail, let cameraID = event.cameraID, Date().timeIntervalSince(event.start) < 60 {
            if let data = await fetchSnapshot(cameraID, highQuality: false) {
                if Self.saveThumbnail(data, for: id), let index = events.firstIndex(where: { $0.id == id }) {
                    events[index].hasThumbnail = true
                    scheduleSave()
                }
            }
        }
        guard !readOnly, let index = events.firstIndex(where: { $0.id == id }), shouldNotify(events[index]) else { return }
        events[index].notified = true
        let current = events[index]
        lastNotified[cooldownKey(current)] = Date()
        scheduleSave()
        SystemNotifier.post(current, thumbnail: current.hasThumbnail ? Self.thumbnailURL(id) : nil,
                            sound: current.primaryKind == .ring ? Prefs.ringSound : false)
    }

    func shouldNotify(_ event: ProtectEvent) -> Bool {
        guard !event.notified, Prefs.notificationsEnabled, Prefs.snoozedUntil == nil else { return false }
        guard Date().timeIntervalSince(event.start) < 120 else { return false }
        if let cameraID = event.cameraID, Prefs.mutedCameras.contains(cameraID) { return false }
        guard !Prefs.notifyKinds.isDisjoint(with: event.kinds) else { return false }
        let cooldown = event.primaryKind == .ring ? min(Prefs.cooldown, 10) : Prefs.cooldown
        if let last = lastNotified[cooldownKey(event)], Date().timeIntervalSince(last) < cooldown { return false }
        return true
    }

    private func cooldownKey(_ event: ProtectEvent) -> String {
        "\(event.cameraID ?? "?")|\(event.primaryKind.rawValue)"
    }

    private func isNotable(_ event: ProtectEvent) -> Bool {
        if let cameraID = event.cameraID, Prefs.mutedCameras.contains(cameraID) { return false }
        return !Prefs.notifyKinds.isDisjoint(with: event.kinds)
    }

    func markSeen() {
        Prefs.lastSeen = Date()
        recountUnseen()
    }

    func recountUnseen() {
        let since = Prefs.lastSeen
        let count = events.prefix { $0.start > since }.filter(isNotable).count
        if count != unseenCount { unseenCount = count }
    }

    func clearLog() {
        events = []
        try? FileManager.default.removeItem(at: Self.thumbnailDir)
        saveNow()
        recountUnseen()
    }

    func preferencesChanged() {
        if let timer = gridTimer, abs(timer.timeInterval - Prefs.gridRefresh) > 0.1 {
            timer.invalidate()
            gridTimer = nil
            updateFeeds()
        }
        recountUnseen()
        objectWillChange.send()
    }

    // MARK: - Devices

    private func handleDeviceMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["type"] as? String,
              let item = object["item"] as? [String: Any],
              item["modelKey"] as? String == "camera" else { return }
        if action == "add" || action == "remove" {
            Task { await refresh() }
            return
        }
        let ids = (item["id"] as? [String]) ?? [(item["id"] as? String)].compactMap { $0 }
        for id in ids {
            guard let index = cameras.firstIndex(where: { $0.id == id }) else { continue }
            if let state = item["state"] as? String, cameras[index].state != state {
                Debug.log("camera \(cameras[index].name) → \(state)")
                cameras[index].state = state
            }
            if let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
               cameras[index].name != name {
                cameras[index].name = name
            }
        }
    }

    // MARK: - Web

    var webURL: URL? { hostURL?.appendingPathComponent("protect/dashboard") }

    func webURL(for event: ProtectEvent) -> URL? {
        hostURL?.appendingPathComponent("protect/events/event/\(event.id)")
    }

    // MARK: - Log storage

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ProtectCameras", isDirectory: true)
    }()

    static var logURL: URL { supportDir.appendingPathComponent("events.json") }
    static var thumbnailDir: URL { supportDir.appendingPathComponent("thumbnails", isDirectory: true) }
    /// Event ids are UUIDs; anything else is reduced to safe characters so it can't escape the folder.
    static func thumbnailURL(_ id: String) -> URL {
        let safe = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
        return thumbnailDir.appendingPathComponent("\(safe.isEmpty ? "invalid" : safe).jpg")
    }

    private static func saveThumbnail(_ data: Data, for id: String) -> Bool {
        guard !CLI.isRendering else { return false }
        try? FileManager.default.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
        return (try? data.write(to: thumbnailURL(id), options: .atomic)) != nil
    }

    static func loadLog() -> [ProtectEvent] {
        guard let data = try? Data(contentsOf: logURL),
              let events = try? JSONDecoder().decode([ProtectEvent].self, from: data) else { return [] }
        return events.sorted { $0.start > $1.start }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var kept = events.filter { $0.start > cutoff }
        if kept.count > Self.maxEvents { kept = Array(kept.prefix(Self.maxEvents)) }
        guard kept.count != events.count else { return }
        let keptIDs = Set(kept.map(\.id))
        for event in events where !keptIDs.contains(event.id) && event.hasThumbnail {
            try? FileManager.default.removeItem(at: Self.thumbnailURL(event.id))
        }
        events = kept
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveNow() {
        guard !readOnly else { return }
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: Self.logURL, options: .atomic) }
    }

    /// Protect sends times as epoch milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1000) }
        if let text = value as? String, let ms = Double(text) { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }
}
