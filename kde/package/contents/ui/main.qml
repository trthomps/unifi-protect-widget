import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.notification

import "../code/protect.js" as P

PlasmoidItem {
    id: root

    // MARK: - State (ProtectStore.swift)

    property var cameras: []
    /// Newest first.
    property var events: []
    property var error: null            // P.apiError(...)
    property var socketError: null
    property bool isLive: false
    property var consoleInfo: null      // { name, version }
    property real lastFetched: 0
    property bool refreshing: false
    property real now: Date.now()
    property real lastTick: Date.now()
    /// The console in use (from Settings, or PROTECT_CAMERAS_HOST), and where its key came from.
    property string host: ""
    property string keySource: ""
    /// Camera shown large in the popup, if any.
    property string focusedCamera: ""
    property var lastNotified: ({})
    property bool logLoaded: false

    /// The helper process (protect-bridge.py): { port, token, pid, dataDir }.
    property var bridge: null
    property var bridgeStarting: null   // Promise while starting
    /// The bridge's configuration generation; anything from an older one is dropped.
    property int bridgeGen: -1
    property int pollSeq: 0
    property int pollVersion: -1
    property int generation: 0

    readonly property var cfg: Plasmoid.configuration
    readonly property string configuredHost: P.normalizeHost(cfg.host) || ""
    /// Where a trusted certificate is looked up: the configured console, or PROTECT_CAMERAS_HOST.
    readonly property string pinHost: configuredHost || host
    readonly property string pin: P.pinFor(cfg.pinnedFingerprints, pinHost) || ""
    readonly property string accountKey: configuredHost + "|" + pin
    readonly property var prefs: P.notifyPrefs({
        notificationsEnabled: cfg.notificationsEnabled, snoozedUntil: cfg.snoozedUntil,
        notifyKinds: cfg.notifyKinds, mutedCameras: cfg.mutedCameras, cooldown: cfg.cooldown
    }, now)
    readonly property bool snoozed: cfg.snoozedUntil > now
    readonly property var mutedCameras: P.csvList(cfg.mutedCameras)
    readonly property int unseenCount: P.unseenCount(events, cfg.lastSeen, prefs)
    readonly property var visibleEvents: P.visibleEvents(events, cfg.showMotionInList)
    readonly property int gridRefresh: Math.max(2, cfg.gridRefresh)

    /// "ok" | "connecting" | "offline" | "error", for the panel icon (MenuBarModel.make).
    readonly property string iconState: {
        if (error && error.kind === "network" && lastFetched > 0) return "offline"
        if (error) return "error"
        if (lastFetched === 0) return "connecting"
        return isLive ? "ok" : "offline"
    }

    readonly property bool planar: Plasmoid.formFactor === PlasmaCore.Types.Planar
        || Plasmoid.formFactor === PlasmaCore.Types.MediaCenter
    /// Snapshots are only fetched while the cameras are on screen.
    readonly property bool feedsActive: (expanded || planar) && bridge !== null && lastFetched > 0
    readonly property color unifiBlue: "#006fff"

    function camera(id) { return P.findCamera(cameras, id) }
    function cameraName(id) { const c = camera(id); return c ? c.name : null }
    function timeText(d) { return Qt.formatTime(d, Qt.locale().timeFormat(Locale.ShortFormat)) }

    function snapshotURL(cameraID, hq, n) {
        return bridge ? P.bridgeURL(bridge, "/snapshot", { camera: cameraID, hq: hq ? 1 : 0, n: n }) : ""
    }
    function thumbnailURL(ev) {
        return bridge && ev.hasThumbnail ? P.fileURL(P.thumbnailPath(bridge.dataDir, ev.id)) : ""
    }

    property string appliedAccountKey: ""
    onAccountKeyChanged: if (accountKey !== appliedAccountKey) accountChangeTimer.restart()

    Timer {
        // Typing a console address changes the config on every keystroke; wait for it to settle.
        id: accountChangeTimer
        interval: 800
        onTriggered: if (root.accountKey !== root.appliedAccountKey) root.accountChanged()
    }

    // MARK: - Representations

    Plasmoid.icon: "camera-video"
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.status: PlasmaCore.Types.ActiveStatus

    preferredRepresentation: planar ? fullRepresentation : compactRepresentation
    compactRepresentation: CompactRepresentation {}
    fullRepresentation: PopupView {}

    toolTipMainText: i18n("Protect")
    toolTipSubText: {
        const parts = []
        if (error) parts.push(P.errorInfo(error).title)
        else if (lastFetched === 0) parts.push(i18n("Connecting…"))
        else {
            parts.push(P.camerasText(cameras))
            if (!isLive) parts.push(i18n("not receiving events"))
            if (unseenCount > 0) parts.push(i18np("%1 new event", "%1 new events", unseenCount))
        }
        if (snoozed) parts.push(i18n("notifications paused until %1", P.when(cfg.snoozedUntil, now, timeText)))
        return parts.join(" · ")
    }
    toolTipTextFormat: Text.PlainText

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh Now")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        },
        PlasmaCore.Action {
            text: i18n("Open Protect in Browser")
            icon.name: "globe"
            enabled: root.host !== ""
            onTriggered: root.openURL(P.webURL(root.host))
        },
        PlasmaCore.Action {
            text: i18n("Resume Notifications (paused until %1)", P.when(root.cfg.snoozedUntil, root.now, root.timeText))
            icon.name: "notifications"
            visible: root.snoozed
            onTriggered: root.snooze("")
        },
        PlasmaCore.Action {
            text: i18n("Pause Notifications for 1 Hour")
            icon.name: "notifications-disabled"
            visible: !root.snoozed
            onTriggered: root.snooze("oneHour")
        },
        PlasmaCore.Action {
            text: i18n("Pause Notifications Until Tomorrow Morning")
            icon.name: "notifications-disabled"
            visible: !root.snoozed
            onTriggered: root.snooze("tomorrow")
        },
        PlasmaCore.Action {
            text: i18n("Send Test Notification")
            icon.name: "preferences-desktop-notification-bell"
            enabled: root.cameras.length > 0
            onTriggered: root.sendTest()
        }
    ]

    onExpandedChanged: () => {
        if (expanded) {
            if (lastFetched === 0 || Date.now() - lastFetched > 60000) refresh(false)
        } else {
            // Everything that was in the list while it was open counts as seen.
            markSeen()
        }
    }

    // MARK: - Bridge

    Shell { id: shell }

    function ensureBridge() {
        if (bridge) return Promise.resolve(bridge)
        if (bridgeStarting) return bridgeStarting
        const started = shell.startBridge(Plasmoid.id).then(info => {
            if (!bridge || bridge.pid !== info.pid) {
                // A new process starts its message numbering over.
                pollSeq = 0
                pollVersion = -1
                bridgeGen = -1
                // It doesn't know the console yet (a no-op if a refresh is what started it).
                Qt.callLater(() => refresh(false))
            }
            bridge = info
            bridgeStarting = null
            if (!logLoaded) loadLog()
            if (!poller.active) poll()
            return info
        }, err => {
            bridgeStarting = null
            throw err
        })
        bridgeStarting = started
        return started
    }

    /// Resolves to the parsed JSON reply. `body` (an object or string) is sent as JSON.
    function call(method, path, query, body, timeout) {
        return ensureBridge().then(info => new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest()
            const entry = { xhr: xhr, started: Date.now(), limit: timeout || 40000, done: false, reject: reject }
            inflight = inflight.concat([entry])
            xhr.onreadystatechange = () => {
                if (xhr.readyState !== XMLHttpRequest.DONE || entry.done) return
                entry.done = true
                inflight = inflight.filter(e => e !== entry)
                if (xhr.status === 0) {
                    // The bridge went away (idle exit, crash, plasmashell restart): start it again next time.
                    if (bridge === info) bridge = null
                    reject(P.apiError("bridge", i18n("Lost the connection to the widget's helper.")))
                    return
                }
                let reply
                try { reply = JSON.parse(xhr.responseText) } catch (e) {
                    reject(P.apiError("decoding", i18n("The widget's helper sent something unexpected.")))
                    return
                }
                if (xhr.status === 403 && reply.error) {
                    if (bridge === info) bridge = null
                    reject(P.fromBridge(reply.error))
                } else if (reply.error) {
                    reject(P.fromBridge(reply.error))
                } else {
                    resolve(reply)
                }
            }
            xhr.open(method, P.bridgeURL(info, path, query))
            if (body !== undefined && body !== null) {
                xhr.setRequestHeader("Content-Type", "application/json")
                xhr.send(typeof body === "string" ? body : JSON.stringify(body))
            } else {
                xhr.send()
            }
        }))
    }

    property var inflight: []

    Timer {
        // QML's XMLHttpRequest has no timeout; abort anything that ran past its limit.
        interval: 2000
        repeat: true
        running: root.inflight.length > 0
        onTriggered: {
            const t = Date.now()
            root.inflight.filter(e => t - e.started > e.limit).forEach(e => {
                e.done = true
                e.xhr.abort()
                e.reject(P.apiError("network", i18n("The request timed out.")))
            })
            root.inflight = root.inflight.filter(e => !e.done)
        }
    }

    /// Tells the bridge which console to use (it re-reads the key from the keyring every time, so
    /// a stored, replaced or removed key takes effect). Resolves to true if the console is usable.
    function configure() {
        const started = generation
        return call("POST", "/config", {}, { host: configuredHost, pin: pin || null }, 40000).then(r => {
            if (started !== generation) throw P.apiError("cancelled")
            if (r.gen !== bridgeGen) {
                const hostChanged = (r.host || "") !== host
                bridgeGen = r.gen
                isLive = false
                socketError = null
                lastFetched = 0
                if (hostChanged) {
                    cameras = []
                    consoleInfo = null
                }
            }
            host = r.host || ""
            keySource = r.source || ""
            if (pendingMessages.length) {
                const pending = pendingMessages
                pendingMessages = []
                handleMessages(pending)
            }
            if (r.error) {
                error = P.fromBridge(r.error)
                return false
            }
            return true
        })
    }

    // MARK: - Fetching

    function refresh(userInitiated) {
        if (refreshing) return
        refreshing = true
        const started = generation
        const finish = () => {
            now = Date.now()
            if (started === generation) refreshing = false
            writeStatus()
        }
        configure().then(ok => {
            if (!ok) return
            const meta = consoleInfo && !userInitiated ? Promise.resolve(null)
                : Promise.all([
                    call("GET", "/api", { path: "meta/info" }),
                    // The NVR's name is nice to have; don't fail over it.
                    call("GET", "/api", { path: "nvrs" }).then(r => P.consoleName(r.body), () => null)
                ])
            return meta.then(m => {
                if (started !== generation) return
                if (m) consoleInfo = { version: m[0].body && m[0].body.applicationVersion || "", name: m[1] || "" }
                return call("GET", "/api", { path: "cameras" })
            }).then(r => {
                if (!r || started !== generation) return
                cameras = P.parseCameras(r.body)
                if (events.some(e => e.cameraID && !e.cameraName && camera(e.cameraID)))
                    events = events.map(e => e.cameraID && !e.cameraName && camera(e.cameraID)
                        ? Object.assign({}, e, { cameraName: cameraName(e.cameraID) }) : e)
                lastFetched = Date.now()
                error = null
                if (cfg.cameraList !== P.cameraListJSON(cameras)) cfg.cameraList = P.cameraListJSON(cameras)
            })
        }).catch(err => {
            if (started !== generation || err.kind === "cancelled") return
            console.warn("protect-cameras: refresh failed:", err.kind, err.detail || err.message)
            error = err.kind ? err : P.apiError("network", String(err))
        }).then(finish)
    }

    // MARK: - Push messages (long poll on the bridge)

    QtObject {
        id: poller
        property bool active: false
        property int failures: 0
    }

    function poll() {
        poller.active = true
        const started = generation
        call("GET", "/poll", { after: pollSeq, version: pollVersion, timeout: 25 }, null, 40000).then(r => {
            poller.failures = 0
            if (r.seq < pollSeq) pollSeq = 0     // the bridge restarted
            else pollSeq = r.seq
            pollVersion = r.version
            if (started === generation && r.gen === bridgeGen) {
                handleMessages(r.messages)
                applySocketStates(r.states || {})
            } else {
                // The reply to /config hasn't arrived yet: keep these until it says which generation is current.
                pendingMessages = pendingMessages.concat(r.messages).slice(-500)
                if (bridgeGen !== -1 && started === generation) refresh(false)
            }
            Qt.callLater(poll)
        }, err => {
            poller.failures += 1
            isLive = false
            pollRetry.interval = Math.min(30000, 1000 * Math.pow(2, Math.min(poller.failures, 5)))
            pollRetry.restart()
            if (err.kind === "bridge" && poller.failures === 3) {
                error = err
            }
        })
    }

    Timer {
        id: pollRetry
        onTriggered: {
            const fresh = !root.bridge
            root.poll()
            // A restarted bridge doesn't know the console yet.
            if (fresh) root.refresh(false)
        }
    }

    property var pendingMessages: []

    function handleMessages(messages) {
        messages.forEach(m => {
            if (m.gen !== bridgeGen) return
            if (m.channel === "events") handleEventMessage(m)
            else if (m.channel === "devices") handleDeviceMessage(m)
        })
    }

    function applySocketStates(states) {
        const ev = states.events || {}
        const live = ev.state === "open"
        if (live !== isLive) isLive = live
        if (live) {
            socketError = null
        } else if (ev.error) {
            const err = P.fromBridge(ev.error)
            socketError = err
            if (err.kind === "unauthorized" || P.isCertificateProblem(err)) {
                if (!error || error.kind !== err.kind) {
                    error = err
                    writeStatus()
                }
            }
        }
    }

    function handleEventMessage(msg) {
        const t = Date.now()
        const r = P.applyEventMessage(events, msg, t, cameraName)
        if (!r.changed) return
        const pruned = P.prune(r.events, t)
        events = pruned.events
        if (pruned.removed) pruneThumbnails()
        scheduleSave()
        if (r.announce) announce(r.announce)
    }

    function handleDeviceMessage(msg) {
        const r = P.applyDeviceMessage(cameras, msg)
        if (r.refresh) refresh(false)
        else if (r.changed) cameras = r.cameras
    }

    // MARK: - Notifications (ProtectStore.announce, SystemNotifier.swift)

    /// Grabs a thumbnail (if we don't have one yet) and posts a notification if the rules say so.
    function announce(id) {
        const index = events.findIndex(e => e.id === id)
        if (index < 0) return
        const ev = events[index]
        const listed = cfg.showMotionInList || P.primaryKind(ev) !== "motion"
        if (!listed && !P.shouldNotify(ev, prefs, lastNotified, Date.now())) return
        const started = generation
        const thumb = !ev.hasThumbnail && ev.cameraID && Date.now() - ev.start < 60000
            ? call("POST", "/thumbnail", { event: ev.id, camera: ev.cameraID }).then(() => {
                if (started !== generation) return
                events = P.setEventFields(events, id, { hasThumbnail: true })
                scheduleSave()
            }, err => console.warn("protect-cameras: thumbnail failed:", err.kind, err.detail || ""))
            : Promise.resolve()
        thumb.then(() => {
            if (started !== generation) return
            const current = events.find(e => e.id === id)
            const t = Date.now()
            if (!current || !P.shouldNotify(current, prefs, lastNotified, t)) return
            events = P.setEventFields(events, id, { notified: true })
            const marks = Object.assign({}, lastNotified)
            marks[P.cooldownKey(current)] = t
            lastNotified = marks
            scheduleSave()
            postNotification(current, current.hasThumbnail ? thumbnailURL(current) : "")
        })
    }

    Component {
        id: notificationComponent
        Notification {
            id: note
            property string eventID: ""
            property string cameraID: ""
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "camera-video"
            autoDelete: true
            defaultAction: NotificationAction {
                label: root.cfg.notificationClick === "web" ? i18n("Open in Protect") : i18n("Show Camera")
                onActivated: root.notificationClicked(note.eventID, note.cameraID)
            }
        }
    }

    function postNotification(ev, imageURL) {
        const n = notificationComponent.createObject(root, {
            title: ev.cameraName || cameraName(ev.cameraID) || i18n("Protect"),
            text: P.summary(ev),
            eventID: ev.id,
            cameraID: ev.cameraID || "",
            urls: imageURL ? [imageURL] : [],
            // Smoke, CO and the like shouldn't wait in the history.
            urgency: P.primaryKind(ev) === "audioAlarm" ? Notification.HighUrgency : Notification.NormalUrgency
        })
        if (n) n.sendEvent()
    }

    function notificationClicked(eventID, cameraID) {
        if (cfg.notificationClick === "web" && eventID.indexOf("test-") !== 0) {
            openURL(P.eventURL(host, eventID))
            return
        }
        const ev = events.find(e => e.id === eventID)
        focusedCamera = cameraID || (ev && ev.cameraID) || ""
        expanded = true
    }

    /// A fake person detection from the first doorbell (or camera), with a live snapshot.
    function sendTest() {
        const cam = cameras.find(c => c.isDoorbell) || cameras[0]
        if (!cam) return
        const ev = { id: "test-" + Date.now(), type: "smartDetectZone", start: Date.now(), end: null,
                     cameraID: cam.id, smartDetectTypes: ["person"], cameraName: cam.name }
        call("POST", "/thumbnail", { event: ev.id, camera: cam.id })
            .then(r => postNotification(ev, P.fileURL(r.path)), () => postNotification(ev, ""))
    }

    // MARK: - Actions

    function openURL(url) {
        if (url) Qt.openUrlExternally(url)
        expanded = false
    }

    function snooze(option) {
        cfg.snoozedUntil = option ? P.snoozeUntil(option, Date.now()) : 0
        now = Date.now()
    }

    function markSeen() {
        cfg.lastSeen = Date.now()
    }

    function setMuted(cameraID, muted) {
        cfg.mutedCameras = P.toggleCSV(cfg.mutedCameras, cameraID, muted)
    }

    function trustCertificate(fingerprint) {
        if (!pinHost || !fingerprint) return
        cfg.pinnedFingerprints = P.setPin(cfg.pinnedFingerprints, pinHost, fingerprint)
    }

    function clearLog() {
        events = []
        call("POST", "/prune", {}, { keep: [], all: true }).catch(() => {})
        saveNow()
    }

    /// Console or certificate changed: drop everything tied to the old one and start over.
    function accountChanged() {
        appliedAccountKey = accountKey
        generation += 1
        focusedCamera = ""
        error = null
        socketError = null
        isLive = false
        lastFetched = 0
        refreshing = false
        refresh(true)
    }

    // MARK: - Event log on disk (through the bridge)

    function loadLog() {
        call("GET", "/log").then(list => {
            const loaded = P.parseLog(JSON.stringify(list))
            // Anything that arrived while the log was loading wins.
            const ids = {}
            events.forEach(e => { ids[e.id] = true })
            const merged = events.concat(loaded.filter(e => !ids[e.id])).sort((a, b) => b.start - a.start)
            events = P.prune(merged, Date.now()).events
            logLoaded = true
        }, err => console.warn("protect-cameras: couldn't read the event log:", err.kind, err.detail || ""))
    }

    function scheduleSave() { saveTimer.restart() }

    Timer {
        id: saveTimer
        interval: 2000
        onTriggered: root.saveNow()
    }

    function saveNow() {
        if (!logLoaded) return
        call("PUT", "/log", {}, JSON.stringify(events))
            .catch(err => console.warn("protect-cameras: couldn't save the event log:", err.kind, err.detail || ""))
    }

    function pruneThumbnails() {
        call("POST", "/prune", {}, { keep: events.filter(e => e.hasThumbnail).map(e => e.id) }).catch(() => {})
    }

    // MARK: - Status for the settings pages

    function writeStatus() {
        const e = error ? { kind: error.kind, detail: error.detail, fingerprint: error.fingerprint } : null
        const text = JSON.stringify({
            host: host, source: keySource, error: e, live: isLive, fetched: lastFetched > 0,
            name: consoleInfo ? consoleInfo.name : "", version: consoleInfo ? consoleInfo.version : "",
            cameras: cameras.length, offline: P.offlineCount(cameras), events: events.length
        })
        if (text !== cfg.consoleStatus) cfg.consoleStatus = text
    }

    property int handledClearLog: -1
    readonly property int requestClearLog: cfg.requestClearLog
    onRequestClearLogChanged: {
        if (handledClearLog !== -1 && requestClearLog !== handledClearLog) clearLog()
        handledClearLog = requestClearLog
    }
    onEventsChanged: statusTimer.restart()

    Timer {
        id: statusTimer
        interval: 60000
        onTriggered: root.writeStatus()
    }

    // MARK: - Timers

    Timer {
        // Cameras come and go rarely, and the devices channel covers state changes.
        interval: 300000
        repeat: true
        running: true
        onTriggered: root.refresh(false)
    }

    Timer {
        // A key stored with secret-tool (or a keyring unlocked) should take effect soon.
        interval: 30000
        repeat: true
        running: root.error !== null && ["notConfigured", "keyring", "unauthorized", "bridge"].indexOf(root.error.kind) >= 0
        onTriggered: root.refresh(false)
    }

    Timer {
        // Keeps "5m ago" current, and notices resume from suspend (a big gap between ticks).
        interval: 20000
        repeat: true
        running: true
        onTriggered: {
            const t = Date.now()
            const slept = t - root.lastTick > 60000
            root.lastTick = t
            root.now = t
            if (slept) wakeTimer.restart()
        }
    }

    Timer {
        // After wake an "open" socket may be half-open, so replace it anyway.
        id: wakeTimer
        interval: 4000
        onTriggered: {
            if (root.bridge) root.call("POST", "/reconnect").catch(() => {})
            root.refresh(false)
        }
    }

    Component.onCompleted: {
        appliedAccountKey = accountKey
        handledClearLog = cfg.requestClearLog
        refresh(true)
    }
}
