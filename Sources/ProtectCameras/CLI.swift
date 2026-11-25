import AppKit
import SwiftUI

/// Terminal helpers. They use the app's saved console and key but never write the app's
/// event log, so they're safe to run while the app is open.
@MainActor
enum CLI {
    private static var color: Bool { isatty(STDOUT_FILENO) != 0 }
    private static func dim(_ text: String) -> String { color ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
    private static func bold(_ text: String) -> String { color ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
        return 1
    }

    /// The app's saved console and key, or `PROTECT_CAMERAS_HOST` / `PROTECT_CAMERAS_API_KEY`.
    private static func connection() -> ProtectConnection? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PROTECT_CAMERAS_HOST"].flatMap(ProtectAPI.normalizedHost) ?? Prefs.hostURL,
              let key = env["PROTECT_CAMERAS_API_KEY"].nonEmpty ?? SecretStore.read(SecretStore.apiKeyAccount(host))
        else { return nil }
        return ProtectConnection(baseURL: host, apiKey: key, pinnedFingerprint: Prefs.pinnedFingerprint(for: host))
    }

    /// Runs async work to completion on the main run loop.
    private static func block<T>(_ work: @escaping @MainActor () async -> T) -> T {
        var result: T?
        Task { result = await work() }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return result!
    }

    static func printSummary() -> Int32 {
        guard let connection = connection() else { return fail(ProtectError.notConfigured.message) }
        let api = ProtectAPI(connection: connection)
        let outcome: Result<(ConsoleInfo, [Camera]), Error> = block {
            do { return .success((try await api.meta(), try await api.cameras())) } catch { return .failure(error) }
        }
        switch outcome {
        case .failure(let error):
            let failure = error as? ProtectError ?? .network(error.localizedDescription)
            return fail("\(failure.title): \(failure.message)")
        case .success(let (info, cameras)):
            print(bold(info.name ?? "Protect") + dim("  ·  Protect \(info.protectVersion ?? "?")  ·  \(connection.baseURL.host ?? "")"))
            print("")
            for camera in cameras.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let state = camera.isConnected ? "●" : (color ? "\u{1B}[31m○\u{1B}[0m" : "○")
                let extras = [camera.isDoorbell ? "doorbell" : nil,
                              camera.smartDetectTypes.isEmpty ? nil : camera.smartDetectTypes.joined(separator: ", ")]
                    .compactMap { $0 }.joined(separator: " · ")
                print("\(state) \(camera.name)  \(dim(extras))  \(dim(camera.id))")
            }
            let events = ProtectStore.loadLog().prefix(15)
            if !events.isEmpty {
                print("\n" + bold("Recent events") + dim("  (from the app's log)"))
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d HH:mm:ss"
                for event in events {
                    print("\(dim(formatter.string(from: event.start)))  \(event.cameraName ?? "?")  \(event.summary)")
                }
            }
            return 0
        }
    }

    static func watch() -> Int32 {
        guard let connection = connection() else { return fail(ProtectError.notConfigured.message) }
        var names: [String: String] = [:]
        if case .success(let cameras) = block({ () async -> Result<[Camera], Error> in
            do { return .success(try await ProtectAPI(connection: connection).cameras()) } catch { return .failure(error) }
        }) {
            for camera in cameras { names[camera.id] = camera.name }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var sockets: [ProtectSocket] = []
        for path in ["subscribe/events", "subscribe/devices"] {
            let socket = ProtectSocket(connection: connection, path: path, onMessage: { data in
                let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
                var line = text
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let item = object["item"] as? [String: Any] {
                    let device = (item["device"] as? String) ?? (item["id"] as? String) ?? ""
                    let label = [object["type"] as? String, item["modelKey"] as? String, item["type"] as? String,
                                 names[device], (item["smartDetectTypes"] as? [String])?.joined(separator: ",")]
                        .compactMap { $0 }.joined(separator: " ")
                    line = bold(label) + "  " + dim(text)
                }
                print("\(dim(formatter.string(from: Date()))) \(line)")
                fflush(stdout)
            }, onState: { state, error in
                let detail = error.map { " — \($0.title): \($0.message)" } ?? ""
                FileHandle.standardError.write(Data("[\(path)] \(state)\(detail)\n".utf8))
            })
            socket.start()
            sockets.append(socket)
        }
        withExtendedLifetime(sockets) { RunLoop.main.run() }
        return 0
    }

    static func saveSnapshot(camera query: String, to path: String) -> Int32 {
        guard let connection = connection() else { return fail(ProtectError.notConfigured.message) }
        let api = ProtectAPI(connection: connection)
        let outcome: Result<Data, Error> = block {
            do {
                let cameras = try await api.cameras()
                guard let camera = cameras.first(where: { $0.id == query })
                        ?? cameras.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
                    throw ProtectError.decoding("No camera matches “\(query)”. Try --print for the list.")
                }
                return .success(try await api.snapshot(cameraID: camera.id, highQuality: camera.supportsFullHDSnapshot))
            } catch { return .failure(error) }
        }
        switch outcome {
        case .failure(let error):
            let failure = error as? ProtectError ?? .network(error.localizedDescription)
            return fail("\(failure.title): \(failure.message)")
        case .success(let data):
            do { try data.write(to: URL(fileURLWithPath: path)) } catch { return fail(error.localizedDescription) }
            print("Saved \(data.count / 1024) KB to \(path)")
            return 0
        }
    }

    static var isRendering = false

    /// Renders the popover against the live console (read-only) for screenshots and UI checks.
    static func renderPopover(to path: String, tab: PopoverTab, camera: String?) -> Int32 {
        isRendering = true
        let store = ProtectStore()
        store.readOnly = true
        store.start()
        // @AppStorage reads .standard, which a bare binary keeps separate from the app's domain.
        Prefs.store.set(tab.rawValue, forKey: PrefKey.popoverTab)
        UserDefaults.standard.set(tab.rawValue, forKey: PrefKey.popoverTab)
        store.popoverVisible = true
        let deadline = Date().addingTimeInterval(20)
        func ready() -> Bool {
            let live = store.cameras.filter(\.isConnected).count
            return !store.cameras.isEmpty && store.snapshots.count >= live && store.isLive
        }
        while !ready(), store.error == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let camera, let match = store.cameras.first(where: { $0.name.localizedCaseInsensitiveContains(camera) }) {
            store.focusedCamera = match.id
            // Give the focused feed a couple of frames.
            RunLoop.main.run(until: Date().addingTimeInterval(3))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let actions = AppActions(refresh: {}, openWeb: { _ in }, openSettings: {}, quit: {})
        let view = NSHostingView(rootView: PopoverView(store: store, actions: actions)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["DARK"] != nil ? .darkAqua : .aqua)
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return fail("render failed") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return fail("encode failed") }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return fail(error.localizedDescription) }
        print("Rendered \(Int(view.bounds.width))×\(Int(view.bounds.height)) to \(path)")
        return 0
    }

    static func renderPreviews(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            var models: [MenuBarModel] = []
            for color in IconColor.allCases {
                models.append(MenuBarModel(state: .ok, count: 0, color: color))
                models.append(MenuBarModel(state: .ok, count: 3, color: color, badge: .badge))
                models.append(MenuBarModel(state: .ok, count: 3, color: color, badge: .dot))
                models.append(MenuBarModel(state: .offline, count: 0, color: color))
                models.append(MenuBarModel(state: .error, count: 0, color: color))
            }
            let scale: CGFloat = 4
            let gap: CGFloat = 14
            let width = models.reduce(gap) { $0 + MenuBarRenderer.width(for: $1) + gap }
            let height: CGFloat = 22 * 2
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(name == "dark" ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x = gap
            for model in models {
                let w = MenuBarRenderer.width(for: model)
                ctx.saveGState()
                ctx.translateBy(x: x, y: 11)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                MenuBarRenderer.draw(model, in: ctx, bounds: CGRect(x: 0, y: 0, width: w, height: 22), appearance: appearance)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
                x += w + gap
            }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("menubar-\(name).png"))
            }
        }
        let icon = AppIcon.bitmap(side: 512) { ctx, side in AppIcon.draw(ctx, side: side) }
        if let data = icon.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("icon.png"))
        }
    }
}
