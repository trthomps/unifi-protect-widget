import CryptoKit
import Foundation
import Security

/// Accepts the console's certificate if the system trusts it, or if its SHA-256 matches the
/// one the user chose to trust (UniFi consoles ship with a self-signed certificate).
/// Anything else is refused, and the fingerprint it saw is kept so Settings can show it.
final class TrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let pinned: String?
    private let lock = NSLock()
    private var _observed: String?

    init(pinned: String?) { self.pinned = pinned }

    /// The fingerprint of the last certificate we refused.
    var observed: String? {
        lock.lock(); defer { lock.unlock() }
        return _observed
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completion(.performDefaultHandling, nil)
            return
        }
        // A certificate macOS trusts (Let's Encrypt on a hostname, say) is always fine, so
        // renewals never trip the pin. The pin only vouches for a self-signed one.
        if SecTrustEvaluateWithError(trust, nil) {
            clearObserved()
            completion(.performDefaultHandling, nil)
            return
        }
        let fingerprint = Self.fingerprint(of: trust)
        if let pinned, let fingerprint, pinned == fingerprint {
            clearObserved()
            completion(.useCredential, URLCredential(trust: trust))
            return
        }
        lock.lock(); _observed = fingerprint; lock.unlock()
        completion(.cancelAuthenticationChallenge, nil)
    }

    private func clearObserved() {
        lock.lock(); _observed = nil; lock.unlock()
    }

    /// Colon-separated uppercase SHA-256 of the leaf certificate, as browsers show it.
    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Keeps requests under the console's rate limit, which is per API key and shared with the
/// websockets: 10 a second on Protect 7 (`RateLimit-Policy: "10-in-1sec"; q=10; w=1`). Runs at
/// 80% of whatever the console advertises and pauses everything after a 429.
actor RequestPacer {
    private var interval: TimeInterval = 1.0 / 6
    private var nextSlot = Date.distantPast
    private var seeded = false

    func acquire() async {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(interval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    func seed(policy: String?) {
        guard !seeded, let policy else { return }
        var quota: Double?, window: Double?
        for part in policy.split(separator: ",").first?.split(separator: ";") ?? [] {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0] == "q" { quota = Double(pair[1]) }
            if pair[0] == "w" { window = Double(pair[1]) }
        }
        guard let quota, let window, quota > 0, window > 0 else { return }
        interval = window / (quota * 0.8)
        seeded = true
        Debug.log("rate limit \(quota)/\(window)s → one request every \(String(format: "%.3f", interval))s")
    }

    func backOff(_ seconds: TimeInterval) {
        nextSlot = max(nextSlot, Date().addingTimeInterval(seconds))
    }
}

/// Where the console is and how to talk to it. Owns the URLSession, since the trust
/// decision lives in its delegate.
final class ProtectConnection: @unchecked Sendable {
    let baseURL: URL
    let apiKey: String
    let trust: TrustDelegate
    let session: URLSession
    let pacer = RequestPacer()

    init(baseURL: URL, apiKey: String, pinnedFingerprint: String?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        trust = TrustDelegate(pinned: pinnedFingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    var integrationURL: URL { baseURL.appendingPathComponent("proxy/protect/integration/v1") }

    var webSocketBase: URL {
        var components = URLComponents(url: integrationURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url!
    }

    func request(_ url: URL, method: String = "GET", accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("ProtectCameras/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Turns a transport failure into something the UI can explain, including certificate
    /// problems the delegate refused.
    func mapError(_ error: Error) -> ProtectError {
        if let urlError = error as? URLError {
            // Only a TLS-shaped failure is blamed on the certificate the delegate refused.
            let tlsCodes: Set<URLError.Code> = [.cancelled, .secureConnectionFailed, .serverCertificateUntrusted,
                                                .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                                                .serverCertificateNotYetValid, .clientCertificateRejected]
            if tlsCodes.contains(urlError.code), let observed = trust.observed {
                return trust.pinned == nil ? .untrustedCertificate(observed) : .certificateChanged(observed)
            }
            switch urlError.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                return .network("TLS failed: \(urlError.localizedDescription)")
            default:
                return .network(urlError.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }
}

/// The parts of the Protect Integration API (`/proxy/protect/integration/v1`) this app uses.
struct ProtectAPI {
    let connection: ProtectConnection

    func meta() async throws -> ConsoleInfo {
        struct Meta: Decodable { var applicationVersion: String? }
        let meta: Meta = try await get("meta/info")
        var info = ConsoleInfo(protectVersion: meta.applicationVersion)
        // The NVR's name is nice to have; don't fail over it.
        if let data = try? await raw("nvrs") {
            struct NVR: Decodable { var name: String? }
            if let one = try? JSONDecoder().decode(NVR.self, from: data) {
                info.name = one.name
            } else if let many = try? JSONDecoder().decode([NVR].self, from: data) {
                info.name = many.first?.name
            }
        }
        return info
    }

    func cameras() async throws -> [Camera] {
        try await get("cameras")
    }

    /// A JPEG of what the camera sees right now. `highQuality` asks for 1080p or better.
    func snapshot(cameraID: String, highQuality: Bool) async throws -> Data {
        var components = URLComponents(url: connection.integrationURL.appendingPathComponent("cameras/\(cameraID)/snapshot"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "highQuality", value: highQuality ? "true" : "false")]
        return try await perform(connection.request(components.url!, accept: "image/jpeg"))
    }

    // MARK: - Plumbing

    private func raw(_ path: String) async throws -> Data {
        try await perform(connection.request(connection.integrationURL.appendingPathComponent(path)))
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await raw(path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProtectError.decoding("Couldn't read \(path): \(error)")
        }
    }

    private func perform(_ request: URLRequest, attempt: Int = 0) async throws -> Data {
        await connection.pacer.acquire()
        try Task.checkCancellation()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await connection.session.data(for: request)
        } catch {
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw connection.mapError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ProtectError.network("No HTTP response") }
        Debug.log("\(request.httpMethod ?? "") \(request.url?.path ?? "") → \(http.statusCode) (\(data.count) bytes)")
        await connection.pacer.seed(policy: http.value(forHTTPHeaderField: "RateLimit-Policy"))
        if http.statusCode == 429 {
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1.5
            await connection.pacer.backOff(min(max(wait, 1), 30))
            if attempt < 2 { return try await perform(request, attempt: attempt + 1) }
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ProtectError.unauthorized(Self.serverMessage(data))
        case 403: throw ProtectError.forbidden(Self.serverMessage(data))
        case 429: throw ProtectError.http(429, "The console is rate-limiting requests. Things will catch up in a moment.")
        default: throw ProtectError.http(http.statusCode, Self.serverMessage(data))
        }
    }

    private static func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Protect answers `{"error":{"code":401,"message":"Unauthorized"}}`.
        if let nested = object["error"] as? [String: Any], let text = nested["message"] as? String {
            return text == "Unauthorized" || text == "Forbidden" ? nil : text.nonEmpty
        }
        return ((object["error"] as? String) ?? (object["message"] as? String)).nonEmpty
    }

    /// Accepts `192.168.1.1`, `https://unifi.local/`, or `host:8443`.
    static func normalizedHost(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }
}

// MARK: - Websocket

/// One of the Integration API's push channels (`subscribe/events` or `subscribe/devices`).
/// Reconnects with backoff until stopped.
@MainActor
final class ProtectSocket {
    enum State: Equatable { case idle, connecting, open, waiting(retryIn: TimeInterval) }

    let path: String
    private let connection: ProtectConnection
    private let onMessage: (Data) -> Void
    private let onState: (State, ProtectError?) -> Void
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var failures = 0
    private(set) var state: State = .idle

    init(connection: ProtectConnection, path: String,
         onMessage: @escaping (Data) -> Void, onState: @escaping (State, ProtectError?) -> Void) {
        self.connection = connection
        self.path = path
        self.onMessage = onMessage
        self.onState = onState
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        set(.idle, nil)
    }

    /// Skip the backoff wait, e.g. after wake or when the network comes back. `force` replaces
    /// even a socket that looks open, since it may be half-open after sleep or a network switch.
    func reconnectNow(force: Bool = false) {
        guard loop != nil else { return start() }
        if case .open = state, !force { return }
        loop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        failures = 0
        loop = Task { [weak self] in await self?.run() }
    }

    private func set(_ state: State, _ error: ProtectError?) {
        self.state = state
        onState(state, error)
    }

    private func run() async {
        while !Task.isCancelled {
            set(.connecting, nil)
            await connection.pacer.acquire()
            guard !Task.isCancelled else { break }
            let url = connection.webSocketBase.appendingPathComponent(path)
            let task = connection.session.webSocketTask(with: connection.request(url))
            task.maximumMessageSize = 4 * 1024 * 1024
            self.task = task
            task.resume()

            // The events channel can stay quiet for a long time, so don't wait for a message to
            // know we're connected: a ping completes once the handshake has.
            let pingError = await Self.handshake(task, timeout: 15)
            var failure: ProtectError?
            var opened = false
            if let pingError {
                failure = Self.describe(task: task, error: pingError, connection: connection)
            } else if !Task.isCancelled {
                opened = true
                failures = 0
                set(.open, nil)
                // Keepalive and dead-connection check: a ping that fails or isn't answered in
                // 10 seconds cancels the task, so receive() throws and we reconnect.
                let pinger = Task { [weak task] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        guard let task, !Task.isCancelled else { return }
                        if let error = await Self.handshake(task, timeout: 10), !(error is CancellationError) {
                            Debug.log("socket \(url.lastPathComponent) ping failed: \(error.localizedDescription)")
                            task.cancel(with: .abnormalClosure, reason: nil)
                            return
                        }
                    }
                }
                do {
                    while !Task.isCancelled {
                        switch try await task.receive() {
                        case .string(let text): onMessage(Data(text.utf8))
                        case .data(let data): onMessage(data)
                        @unknown default: break
                        }
                    }
                } catch {
                    failure = Self.describe(task: task, error: error, connection: connection)
                }
                pinger.cancel()
            }
            task.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled else { break }
            Debug.log("socket \(path) closed: \(failure.map { "\($0)" } ?? "no error")")

            // A socket that never opened counts as a failed connect; one that dropped after
            // working retries quickly.
            failures = opened ? 1 : failures + 1
            let delay = min(60, pow(2, Double(min(failures, 6))))
            set(.waiting(retryIn: delay), failure)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Pings once the socket opens. URLSession can drop the ping's completion when the task
    /// is torn down, so resolve exactly once: on the reply, on timeout, or on cancellation.
    private static func handshake(_ task: URLSessionWebSocketTask, timeout: TimeInterval) async -> Error? {
        let gate = OneShot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.attach(continuation)
                task.sendPing { gate.resume($0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.resume(URLError(.timedOut)) }
            }
        } onCancel: {
            gate.resume(CancellationError())
        }
    }

    private static func describe(task: URLSessionWebSocketTask, error: Error, connection: ProtectConnection) -> ProtectError {
        if let http = task.response as? HTTPURLResponse {
            switch http.statusCode {
            case 401: return .unauthorized(nil)
            case 403: return .forbidden(nil)
            case 200..<300, 101: break
            default: return .http(http.statusCode, nil)
            }
        }
        return connection.mapError(error)
    }
}

/// Resolves a continuation exactly once, whichever of several callers gets there first,
/// including one that arrives before the continuation is attached.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?
    private var early: (Error?, Bool) = (nil, false)
    private var done = false

    func attach(_ continuation: CheckedContinuation<Error?, Never>) {
        lock.lock()
        if early.1 {
            done = true
            lock.unlock()
            continuation.resume(returning: early.0)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ error: Error?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        guard let continuation else {
            if !early.1 { early = (error, true) }
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: error)
    }
}
