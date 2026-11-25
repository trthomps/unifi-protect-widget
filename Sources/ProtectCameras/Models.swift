import Foundation

/// A camera from `GET /v1/cameras` (Protect Integration API). Decoded leniently: only the
/// fields this app uses, with defaults when Protect leaves one out.
struct Camera: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var state: String
    var mac: String?
    var hasPackageCamera: Bool
    /// Only doorbells have an LCD message, so its presence is how we tell them apart.
    var isDoorbell: Bool
    var smartDetectTypes: [String]
    /// Some models (G4 Instant, G5 Dome…) refuse `highQuality=true` snapshots.
    var supportsFullHDSnapshot: Bool

    var isConnected: Bool { state.uppercased() == "CONNECTED" }

    enum CodingKeys: String, CodingKey {
        case id, name, state, mac, hasPackageCamera, lcdMessage, featureFlags, isDoorbell, smartDetectTypes
        case supportsFullHDSnapshot
    }

    private struct FeatureFlags: Decodable {
        var smartDetectTypes: [String]?
        var supportFullHdSnapshot: Bool?
    }

    init(id: String, name: String, state: String = "CONNECTED", mac: String? = nil,
         hasPackageCamera: Bool = false, isDoorbell: Bool = false, smartDetectTypes: [String] = [],
         supportsFullHDSnapshot: Bool = false) {
        self.id = id
        self.name = name
        self.state = state
        self.mac = mac
        self.hasPackageCamera = hasPackageCamera
        self.isDoorbell = isDoorbell
        self.smartDetectTypes = smartDetectTypes
        self.supportsFullHDSnapshot = supportsFullHDSnapshot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Protect keeps whatever was typed, trailing spaces included.
        name = (try c.decodeIfPresent(String.self, forKey: .name) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Camera"
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "UNKNOWN"
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        hasPackageCamera = try c.decodeIfPresent(Bool.self, forKey: .hasPackageCamera) ?? false
        if let stored = try c.decodeIfPresent(Bool.self, forKey: .isDoorbell) {
            isDoorbell = stored
        } else {
            isDoorbell = c.contains(.lcdMessage)
        }
        let flags = (try? c.decodeIfPresent(FeatureFlags.self, forKey: .featureFlags)) ?? nil
        smartDetectTypes = try c.decodeIfPresent([String].self, forKey: .smartDetectTypes) ?? flags?.smartDetectTypes ?? []
        supportsFullHDSnapshot = try c.decodeIfPresent(Bool.self, forKey: .supportsFullHDSnapshot)
            ?? flags?.supportFullHdSnapshot ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(mac, forKey: .mac)
        try c.encode(hasPackageCamera, forKey: .hasPackageCamera)
        try c.encode(isDoorbell, forKey: .isDoorbell)
        try c.encode(smartDetectTypes, forKey: .smartDetectTypes)
        try c.encode(supportsFullHDSnapshot, forKey: .supportsFullHDSnapshot)
    }
}

/// What kind of thing happened. One Protect event can carry several (a smart detection
/// for both a person and a vehicle), so filtering looks at all of them.
enum EventKind: String, Codable, CaseIterable, Identifiable {
    case ring, person, vehicle, package, animal, licensePlate, face, audioAlarm, motion, sensor, other

    var id: String { rawValue }

    /// The order kinds are picked in when an event has several: most urgent first.
    static let priority: [EventKind] = [.ring, .audioAlarm, .person, .package, .vehicle, .licensePlate,
                                        .face, .animal, .sensor, .motion, .other]

    var title: String {
        switch self {
        case .ring: "Doorbell rings"
        case .person: "People"
        case .vehicle: "Vehicles"
        case .package: "Packages"
        case .animal: "Animals"
        case .licensePlate: "License plates"
        case .face: "Faces"
        case .audioAlarm: "Alarm sounds (smoke, CO, glass break, siren…)"
        case .motion: "Plain motion"
        case .sensor: "Sensors (door, leak, motion…)"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .ring: "bell.fill"
        case .person: "figure.walk"
        case .vehicle: "car.fill"
        case .package: "shippingbox.fill"
        case .animal: "pawprint.fill"
        case .licensePlate: "rectangle.and.text.magnifyingglass"
        case .face: "face.smiling"
        case .audioAlarm: "waveform"
        case .motion: "dot.radiowaves.left.and.right"
        case .sensor: "sensor.fill"
        case .other: "circle.dashed"
        }
    }

    /// Notified by default. Plain motion fires constantly, so it's opt-in.
    var notifyByDefault: Bool {
        switch self {
        case .ring, .person, .vehicle, .package, .audioAlarm, .sensor: true
        case .animal, .licensePlate, .face, .motion, .other: false
        }
    }

    static func fromSmartType(_ type: String) -> EventKind {
        switch type {
        case "person": .person
        case "vehicle", "car": .vehicle
        case "animal", "pet": .animal
        case "package": .package
        case "licensePlate": .licensePlate
        case "face": .face
        default: type.hasPrefix("alrm") ? .audioAlarm : .other
        }
    }
}

/// One event from the `subscribe/events` websocket, kept in the local log.
struct ProtectEvent: Codable, Identifiable, Equatable {
    var id: String
    var type: String
    var start: Date
    var end: Date?
    var cameraID: String?
    var smartDetectTypes: [String]
    /// The camera's name when the event arrived, so the log still reads right after a rename
    /// or if the camera goes away.
    var cameraName: String?
    var hasThumbnail = false
    var notified = false

    var kinds: [EventKind] {
        var result: [EventKind] = []
        switch type {
        case "ring": result.append(.ring)
        case "motion", "motionLight": result.append(.motion)
        case "smartAudioDetect": result.append(.audioAlarm)
        default:
            if type.hasPrefix("sensor") || type.hasPrefix("alarmHub") { result.append(.sensor) }
        }
        for smart in smartDetectTypes {
            let kind = EventKind.fromSmartType(smart)
            if !result.contains(kind) { result.append(kind) }
        }
        if result.isEmpty { result = [type.hasPrefix("smartDetect") ? .motion : .other] }
        return result
    }

    var primaryKind: EventKind {
        let mine = kinds
        return EventKind.priority.first(where: mine.contains) ?? .other
    }

    var isActive: Bool { end == nil && Date().timeIntervalSince(start) < 120 }

    /// "Person detected", "Doorbell rang", "Smoke alarm heard".
    var summary: String {
        switch primaryKind {
        case .ring: return "Doorbell rang"
        case .audioAlarm:
            let sound = smartDetectTypes.first { $0.hasPrefix("alrm") }.map(Self.audioName) ?? "Alarm sound"
            return "\(sound) heard"
        case .sensor: return Self.sensorName(type)
        case .motion: return "Motion"
        case .other: return Self.splitCamel(type).capitalizedFirst
        default:
            let names = EventKind.priority.filter(kinds.contains).filter { $0 != .motion && $0 != .other && $0 != .ring }
                .map { Self.objectName($0) }
            return names.joined(separator: " & ").capitalizedFirst + " detected"
        }
    }

    private static func objectName(_ kind: EventKind) -> String {
        switch kind {
        case .person: "person"
        case .vehicle: "vehicle"
        case .package: "package"
        case .animal: "animal"
        case .licensePlate: "license plate"
        case .face: "face"
        default: kind.rawValue
        }
    }

    private static func audioName(_ type: String) -> String {
        switch type {
        case "alrmSmoke": "Smoke alarm"
        case "alrmCmonx": "CO alarm"
        case "alrmSiren": "Siren"
        case "alrmBabyCry": "Baby crying"
        case "alrmSpeak": "Speech"
        case "alrmBark": "Barking"
        case "alrmBurglar": "Burglar alarm"
        case "alrmCarHorn": "Car horn"
        case "alrmGlassBreak": "Glass breaking"
        default: splitCamel(String(type.dropFirst(4))).capitalizedFirst
        }
    }

    private static func sensorName(_ type: String) -> String {
        switch type {
        case "sensorOpened": "Opened"
        case "sensorClosed": "Closed"
        case "sensorMotion": "Sensor motion"
        case "sensorWaterLeak": "Water leak"
        case "sensorTamper": "Sensor tampered with"
        case "sensorBatteryLow": "Sensor battery low"
        case "sensorAlarm": "Sensor alarm"
        case "sensorExtremeValue": "Sensor reading out of range"
        default: splitCamel(type).capitalizedFirst
        }
    }

    static func splitCamel(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isUppercase, !out.isEmpty { out += " " }
            out += character.lowercased()
        }
        return out
    }
}

/// Console details shown in the header and Settings.
struct ConsoleInfo: Equatable {
    var name: String?
    var protectVersion: String?
}

enum ProtectError: Error, Equatable {
    case notConfigured
    case unauthorized(String?)
    case forbidden(String?)
    case http(Int, String?)
    case network(String)
    case decoding(String)
    /// Self-signed certificate we haven't been told to trust yet. Carries its SHA-256.
    case untrustedCertificate(String)
    /// The console presented a different certificate than the one we pinned.
    case certificateChanged(String)

    var title: String {
        switch self {
        case .notConfigured: "Not set up"
        case .unauthorized: "API key rejected"
        case .forbidden: "Access denied"
        case .http(let code, _): "Console error \(code)"
        case .network: "Can't reach the console"
        case .decoding: "Unexpected response"
        case .untrustedCertificate: "Untrusted certificate"
        case .certificateChanged: "Certificate changed"
        }
    }

    var message: String {
        switch self {
        case .notConfigured:
            "Open Settings → Console and enter your console's address and a Protect API key."
        case .unauthorized(let detail):
            detail ?? "The console didn't accept the API key. Create a new one and paste it in Settings → Console."
        case .forbidden(let detail):
            detail ?? "The API key can't read Protect. Check that it was created for the Protect application."
        case .http(_, let detail): detail ?? "The console returned an error."
        case .network(let detail): detail
        case .decoding(let detail): detail
        case .untrustedCertificate:
            "The console uses a self-signed certificate. Check its fingerprint in Settings → Console and trust it."
        case .certificateChanged(let fingerprint):
            "The console's certificate isn't the one you trusted before (now \(fingerprint.prefix(23))…). If you replaced it or reset the console, trust the new one in Settings → Console."
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: "gearshape"
        case .unauthorized, .forbidden: "key.slash"
        case .untrustedCertificate, .certificateChanged: "lock.trianglebadge.exclamationmark"
        case .network: "wifi.exclamationmark"
        default: "exclamationmark.triangle"
        }
    }

    var isCertificateProblem: Bool {
        switch self {
        case .untrustedCertificate, .certificateChanged: true
        default: false
        }
    }

    var fingerprint: String? {
        switch self {
        case .untrustedCertificate(let fp), .certificateChanged(let fp): fp
        default: nil
        }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
