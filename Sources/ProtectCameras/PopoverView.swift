import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case cameras, events
    var id: String { rawValue }
}

struct PopoverView: View {
    @ObservedObject var store: ProtectStore
    let actions: AppActions
    @AppStorage(PrefKey.popoverTab) private var tab: PopoverTab = .cameras
    @AppStorage(PrefKey.snoozedUntil) private var snoozedRaw: Double = 0

    static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: Self.width)
        .onAppear { store.gridTabShown = tab == .cameras }
        .onChange(of: tab) { _, new in store.gridTabShown = new == .cameras }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if store.focusedCamera != nil {
                Button {
                    store.focusedCamera = nil
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Back")
                .keyboardShortcut(.cancelAction)
            } else {
                CameraGlyphView(color: .unifiBlue).frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            LiveBadge(store: store)
            Spacer()
            if store.focusedCamera == nil {
                Picker("", selection: $tab) {
                    Text("Cameras").tag(PopoverTab.cameras)
                    Text(store.unseenCount > 0 ? "Events (\(store.unseenCount))" : "Events").tag(PopoverTab.events)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            IconButton(systemName: "arrow.clockwise", help: "Refresh now", busy: store.isRefreshing) {
                actions.refresh()
            }
            IconButton(systemName: "gearshape", help: "Settings") { actions.openSettings() }
        }
    }

    private var title: String {
        if let camera = store.camera(store.focusedCamera) { return camera.name }
        return store.console?.name ?? "Protect"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.cameras.isEmpty && (store.error != nil || store.lastFetched == nil) {
            StatusMessage(store: store, retry: actions.refresh, openSettings: actions.openSettings)
                .padding(16)
        } else if let id = store.focusedCamera {
            if let camera = store.camera(id) {
                CameraDetail(store: store, camera: camera, actions: actions)
            } else {
                Text("That camera isn't on this console anymore.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            }
        } else {
            VStack(spacing: 0) {
                if let error = store.error {
                    ErrorLine(error: error).padding(.horizontal, 14).padding(.vertical, 8)
                    Divider()
                }
                switch tab {
                case .cameras: CameraGrid(store: store)
                case .events: EventList(store: store, events: store.visibleEvents, emptyText: emptyEventsText)
                }
            }
        }
    }

    private var emptyEventsText: String {
        "No events yet. Detections, doorbell rings and alarms show up here as Protect reports them while the app is running."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let until = snoozeDate {
                Image(systemName: "moon.fill")
                Text("Paused until \(Fmt.time(until))")
                Button("Resume") { snoozedRaw = 0 }.buttonStyle(.borderless)
            } else if let fetched = store.lastFetched {
                let offline = store.cameras.filter { !$0.isConnected }.count
                Text("\(store.cameras.count) cameras" + (offline > 0 ? " · \(offline) offline" : "")
                     + " · updated \(Fmt.ago(fetched, now: store.now))")
            }
            Spacer()
            if snoozeDate == nil {
                Menu {
                    ForEach(SnoozeOption.allCases) { option in
                        Button(option.title) { snoozedRaw = option.until().timeIntervalSince1970 }
                    }
                } label: {
                    Image(systemName: "bell.slash")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pause notifications")
            }
            Button("Open Protect") { actions.openWeb(nil) }.buttonStyle(.borderless)
            Button("Quit") { actions.quit() }.buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var snoozeDate: Date? {
        snoozedRaw > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: snoozedRaw) : nil
    }
}

// MARK: - Grid

struct CameraGrid: View {
    @ObservedObject var store: ProtectStore
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let rows = CGFloat((store.cameras.count + 1) / 2)
        let tileHeight = (PopoverView.width - 24 - 8) / 2 * 9 / 16
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.cameras) { camera in
                    CameraTile(camera: camera, snapshot: store.snapshots[camera.id],
                               failure: store.snapshotErrors[camera.id],
                               active: store.activeKind(for: camera.id),
                               muted: Prefs.mutedCameras.contains(camera.id))
                        .onTapGesture { store.focusedCamera = camera.id }
                }
            }
            .padding(12)
        }
        .frame(height: min(rows * (tileHeight + 8) + 16, 560))
    }
}

struct CameraTile: View {
    let camera: Camera
    let snapshot: Snapshot?
    let failure: String?
    let active: EventKind?
    let muted: Bool
    @State private var hovering = false

    var body: some View {
        // A fixed 16:9 frame; the snapshot fills it whatever its own shape (doorbells are 4:3).
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { tile }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(active != nil ? Color.red.opacity(0.9) : Color.primary.opacity(hovering ? 0.35 : 0.1),
                              lineWidth: active != nil ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(camera.isConnected ? "Show \(camera.name)" : "\(camera.name) is offline")
    }

    private var tile: some View {
        ZStack(alignment: .bottomLeading) {
            SnapshotImage(snapshot: snapshot, failure: camera.isConnected ? failure : nil, offline: !camera.isConnected)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(spacing: 4) {
                if camera.isDoorbell { Image(systemName: "bell.fill").font(.system(size: 8)) }
                Text(camera.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if muted { Image(systemName: "bell.slash.fill").font(.system(size: 8)).opacity(0.8) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(.horizontal, 7)
            .padding(.bottom, 5)
            if let active {
                Label(active == .ring ? "Ring" : active.title, systemImage: active.symbol)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(active == .ring ? Color.orange : Color.red))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
    }
}

/// Fills whatever space it's given; the image never decides the size, so overlays on top of
/// it stay put whatever shape the camera's frames are.
struct SnapshotImage: View {
    let snapshot: Snapshot?
    var failure: String?
    var offline = false

    var body: some View {
        Color.black.opacity(0.85)
            .overlay {
                if let snapshot {
                    Image(nsImage: snapshot.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(offline ? 0.35 : 1)
                }
            }
            .overlay {
                if offline {
                    Label("Offline", systemImage: "video.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                } else if snapshot == nil {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        ProgressView().controlSize(.small).colorScheme(.dark)
                    }
                }
            }
            .clipped()
    }
}

// MARK: - Detail

struct CameraDetail: View {
    @ObservedObject var store: ProtectStore
    let camera: Camera
    let actions: AppActions
    @AppStorage(PrefKey.mutedCameras) private var mutedRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay {
                        SnapshotImage(snapshot: store.snapshots[camera.id], failure: store.snapshotErrors[camera.id],
                                      offline: !camera.isConnected)
                    }
                if camera.isConnected, let shot = store.snapshots[camera.id] {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let age = context.date.timeIntervalSince(shot.takenAt)
                        HStack(spacing: 4) {
                            Circle().fill(age < 4 ? Color.red : Color.gray).frame(width: 6, height: 6)
                            Text(age < 4 ? "LIVE" : "\(Int(age))s old")
                        }
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(8)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)

            HStack(spacing: 8) {
                Button {
                    actions.openWeb(store.webURL)
                } label: {
                    Label("Open in Protect", systemImage: "arrow.up.right.square")
                }
                Toggle(isOn: mutedBinding) {
                    Label("Mute notifications", systemImage: "bell.slash")
                }
                .toggleStyle(.button)
                Spacer()
                Text(camera.isConnected ? "about 1 frame per second\(camera.supportsFullHDSnapshot ? ", HD" : "")" : "offline")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            let recent = store.events(for: camera.id)
            if !recent.isEmpty {
                Divider()
                EventList(store: store, events: Array(recent.prefix(30)), emptyText: "", showCamera: false, maxHeight: 220)
            }
        }
    }

    /// Doorbells are 4:3 (or taller); show the whole frame rather than crop it.
    private var aspect: CGFloat {
        guard let size = store.snapshots[camera.id]?.image.size, size.height > 0 else { return 16 / 9 }
        return max(size.width / size.height, 1)
    }

    private var mutedBinding: Binding<Bool> {
        Binding(
            get: { Set(mutedRaw.split(separator: ",").map(String.init)).contains(camera.id) },
            set: { muted in
                var set = Set(mutedRaw.split(separator: ",").map(String.init))
                if muted { set.insert(camera.id) } else { set.remove(camera.id) }
                mutedRaw = set.sorted().joined(separator: ",")
            }
        )
    }
}

// MARK: - Events

struct EventList: View {
    @ObservedObject var store: ProtectStore
    let events: [ProtectEvent]
    let emptyText: String
    var showCamera = true
    var maxHeight: CGFloat = 480

    var body: some View {
        if events.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 30)
        } else {
            let seen = Prefs.lastSeen
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(events) { event in
                        EventRow(event: event, now: store.now, isNew: event.start > seen, showCamera: showCamera,
                                 cameraName: store.camera(event.cameraID)?.name ?? event.cameraName ?? "Unknown camera")
                            .onTapGesture {
                                if let id = event.cameraID { store.focusedCamera = id }
                            }
                        Divider().padding(.leading, 96)
                    }
                }
            }
            .frame(height: min(CGFloat(events.count) * 53, maxHeight))
        }
    }
}

struct EventRow: View {
    let event: ProtectEvent
    let now: Date
    let isNew: Bool
    let showCamera: Bool
    let cameraName: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(event: event)
                .frame(width: 72, height: 40.5)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: event.primaryKind.symbol)
                        .font(.system(size: 10.5))
                        .foregroundStyle(tint)
                    Text(event.summary)
                        .font(.system(size: 12.5, weight: isNew ? .semibold : .regular))
                        .lineLimit(1)
                }
                Text(showCamera ? "\(cameraName) · \(Fmt.clock(event.start, now: now))" : Fmt.clock(event.start, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if event.isActive {
                Text("NOW").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
            } else {
                Text(Fmt.ago(event.start, now: now, short: true))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Circle().fill(isNew ? Color.accentColor : .clear).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var tint: Color {
        switch event.primaryKind {
        case .ring: .orange
        case .audioAlarm: .red
        case .person: .blue
        case .vehicle, .licensePlate: .purple
        case .package: .brown
        case .animal: .green
        default: .secondary
        }
    }
}

/// Event thumbnails are small JPEGs on disk; keep the decoded ones around.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for event: ProtectEvent) -> NSImage? {
        guard event.hasThumbnail else { return nil }
        if let hit = cache.object(forKey: event.id as NSString) { return hit }
        guard let image = NSImage(contentsOf: ProtectStore.thumbnailURL(event.id)) else { return nil }
        cache.setObject(image, forKey: event.id as NSString)
        return image
    }
}

struct Thumbnail: View {
    let event: ProtectEvent

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let image = ThumbnailCache.image(for: event) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: event.primaryKind.symbol).foregroundStyle(.tertiary)
            }
        }
        .clipped()
    }
}

// MARK: - Bits

struct LiveBadge: View {
    @ObservedObject var store: ProtectStore

    var body: some View {
        if store.lastFetched != nil {
            HStack(spacing: 4) {
                Circle().fill(store.isLive ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(store.isLive ? "Live" : "No events")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .help(store.isLive
                  ? "Connected to Protect's event stream"
                  : "Not receiving events" + (store.socketError.map { ": \($0.title). \($0.message)" } ?? ". Reconnecting…"))
        }
    }
}

struct ErrorLine: View {
    let error: ProtectError

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(error.title). \(error.message)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct StatusMessage: View {
    @ObservedObject var store: ProtectStore
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let error = store.error {
                Image(systemName: error.symbol).font(.system(size: 26)).foregroundStyle(.secondary)
                Text(error.title).font(.system(size: 13, weight: .semibold))
                Text(error.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Settings…", action: openSettings)
                    if error != .notConfigured { Button("Try Again", action: retry) }
                }
                .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Connecting to \(store.hostURL?.host ?? "the console")…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                } else {
                    Image(systemName: systemName).font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(busy)
    }
}

enum Fmt {
    static func ago(_ date: Date, now: Date, short: Bool = false) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return short ? "now" : "just now" }
        let minutes = Int(seconds / 60)
        let value: String
        if minutes < 60 { value = "\(minutes)m" }
        else if minutes < 60 * 24 { value = "\(minutes / 60)h" }
        else { value = "\(minutes / 1440)d" }
        return short ? value : "\(value) ago"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    /// "3:41 PM" today, "Yesterday 3:41 PM", "Mon 3:41 PM" this week, else "Nov 18, 3:41 PM".
    static func clock(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if now.timeIntervalSince(date) < 6 * 86400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
