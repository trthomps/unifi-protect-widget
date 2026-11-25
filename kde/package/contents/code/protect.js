.pragma library

// Port of Models.swift, the event, device and notification logic in ProtectStore.swift, the
// snooze options in StatusItemController.swift, Prefs helpers and Fmt.
// Plain JS so it can be unit-tested with node (see kde/test/protect.test.js).

// MARK: - Event kinds (EventKind in Models.swift)

var KINDS = ["ring", "person", "vehicle", "package", "animal", "licensePlate", "face", "audioAlarm",
             "motion", "sensor", "other"];

/// The order kinds are picked in when an event has several: most urgent first.
var PRIORITY = ["ring", "audioAlarm", "person", "package", "vehicle", "licensePlate", "face", "animal",
                "sensor", "motion", "other"];

/// title, icon (freedesktop/Breeze name), whether it's notified by default, and the list tint.
var kindInfo = {
    ring:         { title: "Doorbell rings", short: "Ring", icon: "notifications", notify: true, tint: "orange" },
    person:       { title: "People", short: "Person", icon: "user", notify: true, tint: "blue" },
    vehicle:      { title: "Vehicles", short: "Vehicle", icon: "car", notify: true, tint: "purple" },
    "package":    { title: "Packages", short: "Package", icon: "package", notify: true, tint: "brown" },
    animal:       { title: "Animals", short: "Animal", icon: "animal", notify: false, tint: "green" },
    licensePlate: { title: "License plates", short: "License plate", icon: "view-barcode-qr", notify: false, tint: "purple" },
    face:         { title: "Faces", short: "Face", icon: "face-smile", notify: false, tint: "" },
    audioAlarm:   { title: "Alarm sounds (smoke, CO, glass break, siren…)", short: "Alarm", icon: "waveform", notify: true, tint: "red" },
    motion:       { title: "Plain motion", short: "Motion", icon: "media-record", notify: false, tint: "" },
    sensor:       { title: "Sensors (door, leak, motion…)", short: "Sensor", icon: "kt-magnet", notify: true, tint: "" },
    other:        { title: "Other", short: "Event", icon: "emblem-question", notify: false, tint: "" }
};

var DEFAULT_KINDS = KINDS.filter(function (k) { return kindInfo[k].notify; }).join(",");

function kindFromSmartType(type) {
    switch (type) {
    case "person": return "person";
    case "vehicle": case "car": return "vehicle";
    case "animal": case "pet": return "animal";
    case "package": return "package";
    case "licensePlate": return "licensePlate";
    case "face": return "face";
    default: return String(type).indexOf("alrm") === 0 ? "audioAlarm" : "other";
    }
}

// MARK: - Events (ProtectEvent)

function eventKinds(ev) {
    var out = [];
    var type = String(ev.type || "");
    if (type === "ring") out.push("ring");
    else if (type === "motion" || type === "motionLight") out.push("motion");
    else if (type === "smartAudioDetect") out.push("audioAlarm");
    else if (type.indexOf("sensor") === 0 || type.indexOf("alarmHub") === 0) out.push("sensor");
    (ev.smartDetectTypes || []).forEach(function (s) {
        var k = kindFromSmartType(s);
        if (out.indexOf(k) < 0) out.push(k);
    });
    if (!out.length) out = [type.indexOf("smartDetect") === 0 ? "motion" : "other"];
    return out;
}

function primaryKind(ev) {
    var mine = eventKinds(ev);
    for (var i = 0; i < PRIORITY.length; i++) if (mine.indexOf(PRIORITY[i]) >= 0) return PRIORITY[i];
    return "other";
}

function isActive(ev, now) { return (ev.end === null || ev.end === undefined) && now - ev.start < 120000; }

function splitCamel(text) {
    var out = "";
    String(text).split("").forEach(function (c) {
        if (c !== c.toLowerCase() && c === c.toUpperCase() && out) out += " ";
        out += c.toLowerCase();
    });
    return out;
}

function capitalizedFirst(s) { s = String(s); return s.charAt(0).toUpperCase() + s.slice(1); }

var audioNames = {
    alrmSmoke: "Smoke alarm", alrmCmonx: "CO alarm", alrmSiren: "Siren", alrmBabyCry: "Baby crying",
    alrmSpeak: "Speech", alrmBark: "Barking", alrmBurglar: "Burglar alarm", alrmCarHorn: "Car horn",
    alrmGlassBreak: "Glass breaking"
};

var sensorNames = {
    sensorOpened: "Opened", sensorClosed: "Closed", sensorMotion: "Sensor motion", sensorWaterLeak: "Water leak",
    sensorTamper: "Sensor tampered with", sensorBatteryLow: "Sensor battery low", sensorAlarm: "Sensor alarm",
    sensorExtremeValue: "Sensor reading out of range"
};

var objectNames = { person: "person", vehicle: "vehicle", "package": "package", animal: "animal",
                    licensePlate: "license plate", face: "face" };

/// "Person detected", "Doorbell rang", "Smoke alarm heard".
function summary(ev) {
    var kind = primaryKind(ev);
    switch (kind) {
    case "ring": return "Doorbell rang";
    case "audioAlarm":
        var alrm = (ev.smartDetectTypes || []).filter(function (t) { return t.indexOf("alrm") === 0; })[0];
        var sound = alrm ? (audioNames[alrm] || capitalizedFirst(splitCamel(alrm.slice(4)))) : "Alarm sound";
        return sound + " heard";
    case "sensor": return sensorNames[ev.type] || capitalizedFirst(splitCamel(ev.type));
    case "motion": return "Motion";
    case "other": return capitalizedFirst(splitCamel(ev.type));
    default:
        var kinds = eventKinds(ev);
        var names = PRIORITY.filter(function (k) {
            return kinds.indexOf(k) >= 0 && k !== "motion" && k !== "other" && k !== "ring";
        }).map(function (k) { return objectNames[k] || k; });
        return capitalizedFirst(names.join(" & ")) + " detected";
    }
}

/// Protect sends times as epoch milliseconds.
function parseDate(v) {
    if (typeof v === "number" && isFinite(v)) return v;
    if (typeof v === "string" && v.trim() !== "" && isFinite(Number(v))) return Number(v);
    return null;
}

function kindsKey(ev) { return eventKinds(ev).slice().sort().join(","); }

function findEvent(events, id) {
    for (var i = 0; i < events.length; i++) if (events[i].id === id) return i;
    return -1;
}

/// Applies one `subscribe/events` message (ProtectStore.handleEventMessage). Returns
/// { events, changed, announce } where announce is an event id worth a banner check.
function applyEventMessage(events, msg, now, cameraName) {
    var none = { events: events, changed: false, announce: null };
    var item = msg && msg.item;
    if (!item || item.modelKey !== "event" || typeof item.id !== "string") return none;
    var action = msg.type;
    var index = findEvent(events, item.id);

    if (index >= 0) {
        if (action === "remove") return none;
        var ev = Object.assign({}, events[index]);
        var before = kindsKey(ev);
        if (Object.prototype.hasOwnProperty.call(item, "end")) ev.end = parseDate(item.end);
        if (Array.isArray(item.smartDetectTypes)) {
            var types = (ev.smartDetectTypes || []).slice();
            item.smartDetectTypes.forEach(function (t) { if (types.indexOf(t) < 0) types.push(t); });
            ev.smartDetectTypes = types;
        }
        if (typeof item.type === "string") ev.type = item.type;
        var next = events.slice();
        next[index] = ev;
        // A motion event that turned into a person, say: maybe worth a banner now.
        return { events: next, changed: true, announce: kindsKey(ev) !== before ? ev.id : null };
    }

    // Updates carry the whole event, so one that started just before we connected still gets
    // picked up from its first update.
    if (action !== "add" && action !== "update") return none;
    var start = parseDate(item.start);
    if (typeof item.type !== "string" || start === null) return none;
    if (action === "update" && now - start > 300000) return none;
    var cameraID = typeof item.device === "string" ? item.device : null;
    var created = {
        id: item.id, type: item.type, start: start, end: parseDate(item.end), cameraID: cameraID,
        smartDetectTypes: Array.isArray(item.smartDetectTypes) ? item.smartDetectTypes.filter(function (t) {
            return typeof t === "string";
        }) : [],
        cameraName: cameraID && cameraName ? (cameraName(cameraID) || null) : null,
        hasThumbnail: false, notified: false
    };
    // Newest first; an event picked up from a late update may be older than the top one.
    var at = events.length;
    for (var i = 0; i < events.length; i++) if (events[i].start < start) { at = i; break; }
    var out = events.slice();
    out.splice(at, 0, created);
    return { events: out, changed: true, announce: created.id };
}

var MAX_EVENTS = 500;
var MAX_AGE = 7 * 24 * 3600 * 1000;

/// Drops events older than 7 days and beyond the newest 500. Returns { events, removed }.
function prune(events, now) {
    var cutoff = now - MAX_AGE;
    var kept = events.filter(function (e) { return e.start > cutoff; });
    if (kept.length > MAX_EVENTS) kept = kept.slice(0, MAX_EVENTS);
    if (kept.length === events.length) return { events: events, removed: 0 };
    return { events: kept, removed: events.length - kept.length };
}

/// The saved log, newest first, with anything malformed dropped.
function parseLog(text) {
    var list;
    try { list = JSON.parse(text); } catch (e) { return []; }
    if (!Array.isArray(list)) return [];
    return list.filter(function (e) {
        return e && typeof e.id === "string" && typeof e.type === "string" && typeof e.start === "number";
    }).map(function (e) {
        return {
            id: e.id, type: e.type, start: e.start, end: typeof e.end === "number" ? e.end : null,
            cameraID: typeof e.cameraID === "string" ? e.cameraID : null,
            smartDetectTypes: Array.isArray(e.smartDetectTypes) ? e.smartDetectTypes : [],
            cameraName: typeof e.cameraName === "string" ? e.cameraName : null,
            hasThumbnail: !!e.hasThumbnail, notified: !!e.notified
        };
    }).sort(function (a, b) { return b.start - a.start; });
}

function setEventFields(events, id, fields) {
    var i = findEvent(events, id);
    if (i < 0) return events;
    var out = events.slice();
    out[i] = Object.assign({}, out[i], fields);
    return out;
}

// MARK: - Notification rules (ProtectStore.shouldNotify)

function csvList(text) {
    return String(text || "").split(",").map(function (s) { return s.trim(); }).filter(function (s) { return s; });
}

/// Adds or removes `value` from a comma-separated set, kept sorted (or in `order` if given).
function toggleCSV(text, value, on, order) {
    var set = csvList(text).filter(function (v) { return v !== value; });
    if (on) set.push(value);
    if (order) return order.filter(function (v) { return set.indexOf(v) >= 0; }).join(",");
    return set.sort().join(",");
}

/// The notification preferences the rules below read, from the plasmoid config.
function notifyPrefs(cfg, now) {
    return {
        enabled: !!cfg.notificationsEnabled,
        snoozed: Number(cfg.snoozedUntil) > now,
        kinds: csvList(cfg.notifyKinds),
        muted: csvList(cfg.mutedCameras),
        cooldown: Math.max(0, Number(cfg.cooldown) || 0) * 1000
    };
}

function cooldownKey(ev) { return (ev.cameraID || "?") + "|" + primaryKind(ev); }

function wantsKind(ev, prefs) {
    var kinds = eventKinds(ev);
    return prefs.kinds.some(function (k) { return kinds.indexOf(k) >= 0; });
}

function shouldNotify(ev, prefs, lastNotified, now) {
    if (ev.notified || !prefs.enabled || prefs.snoozed) return false;
    if (now - ev.start >= 120000) return false;
    if (ev.cameraID && prefs.muted.indexOf(ev.cameraID) >= 0) return false;
    if (!wantsKind(ev, prefs)) return false;
    var cooldown = primaryKind(ev) === "ring" ? Math.min(prefs.cooldown, 10000) : prefs.cooldown;
    var last = lastNotified[cooldownKey(ev)];
    if (last !== undefined && now - last < cooldown) return false;
    return true;
}

/// Events you'd be notified about (ignoring snooze and cooldown), for the badge.
function isNotable(ev, prefs) {
    if (ev.cameraID && prefs.muted.indexOf(ev.cameraID) >= 0) return false;
    return wantsKind(ev, prefs);
}

function unseenCount(events, lastSeen, prefs) {
    var n = 0;
    for (var i = 0; i < events.length && events[i].start > lastSeen; i++) if (isNotable(events[i], prefs)) n++;
    return n;
}

/// Events the list shows (plain motion only when asked for).
function visibleEvents(events, showMotion) {
    return showMotion ? events : events.filter(function (e) { return primaryKind(e) !== "motion"; });
}

/// The most urgent detection still going on at a camera, for the grid's highlight.
function activeKind(events, cameraID, now, showMotion) {
    var active = events.slice(0, 40).filter(function (e) {
        return e.cameraID === cameraID && isActive(e, now) && (showMotion || primaryKind(e) !== "motion");
    });
    for (var i = 0; i < PRIORITY.length; i++) {
        var k = PRIORITY[i];
        if (active.some(function (e) { return eventKinds(e).indexOf(k) >= 0; })) return k;
    }
    return null;
}

// MARK: - Cameras (Camera in Models.swift)

function parseCamera(c) {
    if (!c || typeof c.id !== "string") return null;
    var flags = c.featureFlags && typeof c.featureFlags === "object" ? c.featureFlags : {};
    // Protect keeps whatever was typed, trailing spaces included.
    var name = typeof c.name === "string" ? c.name.trim() : "";
    return {
        id: c.id,
        name: name || "Camera",
        state: typeof c.state === "string" ? c.state : "UNKNOWN",
        mac: typeof c.mac === "string" ? c.mac : null,
        hasPackageCamera: !!c.hasPackageCamera,
        // Only doorbells have an LCD message, so its presence is how we tell them apart.
        isDoorbell: typeof c.isDoorbell === "boolean" ? c.isDoorbell : Object.prototype.hasOwnProperty.call(c, "lcdMessage"),
        smartDetectTypes: Array.isArray(c.smartDetectTypes) ? c.smartDetectTypes
            : Array.isArray(flags.smartDetectTypes) ? flags.smartDetectTypes : [],
        // Some models (G4 Instant, G5 Dome…) refuse highQuality=true snapshots.
        supportsFullHDSnapshot: typeof c.supportsFullHDSnapshot === "boolean" ? c.supportsFullHDSnapshot
            : !!flags.supportFullHdSnapshot
    };
}

var collator = null;
function compareNames(a, b) {
    if (collator === null) {
        try { collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" }); }
        catch (e) { collator = false; }
    }
    if (collator) return collator.compare(a, b);
    return a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0;
}

function parseCameras(body) {
    if (!Array.isArray(body)) throw apiError("decoding", "Couldn't read cameras: expected a list.");
    return body.map(parseCamera).filter(function (c) { return c; })
        .sort(function (a, b) { return compareNames(a.name, b.name); });
}

function isConnected(c) { return String(c.state).toUpperCase() === "CONNECTED"; }

function offlineCount(cameras) { return cameras.filter(function (c) { return !isConnected(c); }).length; }

function findCamera(cameras, id) {
    if (!id) return null;
    for (var i = 0; i < cameras.length; i++) if (cameras[i].id === id) return cameras[i];
    return null;
}

/// Applies one `subscribe/devices` message. Returns { cameras, changed, refresh }.
function applyDeviceMessage(cameras, msg) {
    var item = msg && msg.item;
    if (!item || item.modelKey !== "camera") return { cameras: cameras, changed: false, refresh: false };
    if (msg.type === "add" || msg.type === "remove") return { cameras: cameras, changed: false, refresh: true };
    var ids = Array.isArray(item.id) ? item.id : typeof item.id === "string" ? [item.id] : [];
    var out = cameras, changed = false;
    ids.forEach(function (id) {
        for (var i = 0; i < out.length; i++) {
            if (out[i].id !== id) continue;
            var c = Object.assign({}, out[i]), touched = false;
            if (typeof item.state === "string" && c.state !== item.state) { c.state = item.state; touched = true; }
            var name = typeof item.name === "string" ? item.name.trim() : "";
            if (name && c.name !== name) { c.name = name; touched = true; }
            if (touched) {
                if (!changed) out = out.slice();
                out[i] = c;
                changed = true;
            }
        }
    });
    return { cameras: out, changed: changed, refresh: false };
}

/// The NVR's name from `GET /v1/nvrs` (one object or a list).
function consoleName(body) {
    var one = Array.isArray(body) ? body[0] : body;
    return one && typeof one.name === "string" && one.name.trim() ? one.name.trim() : null;
}

// MARK: - Errors (ProtectError)

function apiError(kind, detail, status, fingerprint) {
    var e = new Error(detail || kind);
    e.kind = kind;
    e.detail = detail || null;
    e.status = status || 0;
    e.fingerprint = fingerprint || null;
    return e;
}

/// From the bridge's JSON {kind, detail, status, fingerprint}.
function fromBridge(e) {
    if (!e || typeof e !== "object") return apiError("network", "The bridge sent something unexpected.");
    return apiError(String(e.kind || "network"), e.detail || null, e.status || 0, e.fingerprint || null);
}

var errorText = {
    notConfigured: ["Not set up", "Open Configure… → Console, enter your console's address and store a Protect API key."],
    unauthorized: ["API key rejected", "The console didn't accept the API key. Create a new one and store it in Configure… → Console."],
    forbidden: ["Access denied", "The API key can't read Protect. Check that it was created for the Protect application."],
    http: ["Console error", "The console returned an error."],
    network: ["Can't reach the console", "Check the address and your network."],
    cancelled: ["Can't reach the console", "The request was cancelled."],
    decoding: ["Unexpected response", "The console sent something this widget doesn't understand."],
    untrustedCertificate: ["Untrusted certificate", "The console uses a self-signed certificate. Check its fingerprint in Configure… → Console and trust it."],
    certificateChanged: ["Certificate changed", ""],
    keyring: ["Keyring problem", "Couldn't read the API key from the keyring."],
    bridge: ["Bridge not running", "The widget's helper (python3) couldn't start."]
};

var errorIcon = {
    notConfigured: "configure", unauthorized: "dialog-password", forbidden: "dialog-password",
    untrustedCertificate: "security-low", certificateChanged: "security-low", network: "network-disconnect",
    keyring: "dialog-password", bridge: "dialog-error"
};

function errorInfo(err) {
    if (!err) return null;
    var kind = errorText[err.kind] ? err.kind : "network";
    var t = errorText[kind];
    var title = kind === "http" && err.status ? "Console error " + err.status : t[0];
    var message = err.detail || t[1];
    if (kind === "certificateChanged") {
        message = "The console's certificate isn't the one you trusted before (now "
            + String(err.fingerprint || "").slice(0, 23) + "…). If you replaced it or reset the console, trust the new one in Configure… → Console.";
    }
    return { kind: kind, title: title, message: message, icon: errorIcon[kind] || "dialog-warning",
             fingerprint: err.fingerprint || null };
}

function isCertificateProblem(err) {
    return !!err && (err.kind === "untrustedCertificate" || err.kind === "certificateChanged");
}

// MARK: - Console address and trust (ProtectAPI.normalizedHost, Prefs.pinnedFingerprint)

/// Accepts `192.168.1.1`, `https://unifi.local/`, or `host:8443`. Returns "https://host[:port]" or null.
function normalizeHost(text) {
    var s = String(text || "").trim();
    if (!s) return null;
    if (s.indexOf("://") < 0) s = "https://" + s;
    s = s.replace(/\/+$/, "");
    var m = /^(https?):\/\/(\[[0-9a-fA-F:.]+\]|[^\/\s:?#\[\]@]+)(:(\d{1,5}))?(\/[^\s?#]*)?$/i.exec(s);
    if (!m) return null;
    if (m[4] && Number(m[4]) > 65535) return null;
    return m[1].toLowerCase() + "://" + m[2] + (m[3] || "") + (m[5] || "");
}

function hostName(host) {
    var m = /^https?:\/\/(\[[^\]]+\]|[^\/:]+)/.exec(host || "");
    return m ? m[1] : "";
}

function parsePins(text) {
    try {
        var o = JSON.parse(text || "{}");
        return o && typeof o === "object" && !Array.isArray(o) ? o : {};
    } catch (e) { return {}; }
}

function pinFor(text, host) {
    var p = parsePins(text)[host];
    return typeof p === "string" && p ? p : null;
}

function setPin(text, host, fingerprint) {
    var pins = parsePins(text);
    if (fingerprint) pins[host] = fingerprint;
    else delete pins[host];
    return JSON.stringify(pins);
}

function keyAccount(host) { return "apikey:" + host; }

function webURL(host) { return host ? host + "/protect/dashboard" : null; }
function eventURL(host, id) { return host ? host + "/protect/events/event/" + encodeURIComponent(id) : null; }

// MARK: - Bridge (protect-bridge.py)

function bridgeURL(info, path, query) {
    var q = ["token=" + encodeURIComponent(info.token)];
    Object.keys(query || {}).forEach(function (k) {
        q.push(encodeURIComponent(k) + "=" + encodeURIComponent(query[k]));
    });
    return "http://127.0.0.1:" + info.port + path + "?" + q.join("&");
}

function parseBridgeInfo(stdout) {
    var lines = String(stdout || "").trim().split("\n");
    try {
        var o = JSON.parse(lines[lines.length - 1]);
        return o && o.port && o.token ? o : null;
    } catch (e) { return null; }
}

/// Event ids are hex; anything else is reduced to safe characters (same rule as the bridge).
function thumbnailPath(dataDir, id) {
    var safe = String(id).replace(/[^A-Za-z0-9-]/g, "").slice(0, 100);
    return dataDir + "/thumbnails/" + (safe || "invalid") + ".jpg";
}

function fileURL(path) { return "file://" + String(path).split("/").map(encodeURIComponent).join("/"); }

/// The plasmoid's file:// URL for a package file, as a local path.
function localPath(url) { return decodeURIComponent(String(url).replace(/^file:\/\//, "")); }

/// Single-quotes a value for /bin/sh.
function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

function keyringError(code, stderr) {
    if (code === 0 || code === 1) return null;
    if (code === 127) return apiError("keyring", "secret-tool isn't installed. It comes with libsecret (libsecret-tools on Debian/Ubuntu).");
    if (code === 124) return apiError("keyring", "The keyring didn't answer in time. Is it locked?");
    return apiError("keyring", String(stderr || "").trim() || "secret-tool failed (exit " + code + ").");
}

// MARK: - Snooze (SnoozeOption)

var SNOOZE = [
    { id: "thirtyMinutes", title: "For 30 Minutes" },
    { id: "oneHour", title: "For 1 Hour" },
    { id: "fourHours", title: "For 4 Hours" },
    { id: "tomorrow", title: "Until Tomorrow Morning" }
];

function snoozeUntil(option, now) {
    switch (option) {
    case "thirtyMinutes": return now + 30 * 60000;
    case "oneHour": return now + 3600000;
    case "fourHours": return now + 4 * 3600000;
    default:
        // The next 7 AM: this morning if it's still before then (paused after midnight).
        var d = new Date(now);
        d.setHours(7, 0, 0, 0);
        if (d.getTime() > now) return d.getTime();
        d.setDate(d.getDate() + 1);
        d.setHours(7, 0, 0, 0);
        return d.getTime();
    }
}

// MARK: - Formatting (Fmt)

function ago(t, now, short) {
    var s = Math.max(0, (now - t) / 1000);
    if (s < 60) return short ? "now" : "just now";
    var m = Math.floor(s / 60), v;
    if (m < 60) v = m + "m";
    else if (m < 1440) v = Math.floor(m / 60) + "h";
    else v = Math.floor(m / 1440) + "d";
    return short ? v : v + " ago";
}

var weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/// "3:41 PM" today, "Yesterday 3:41 PM", "Mon 3:41 PM" this week, else "Nov 18, 3:41 PM".
/// `timeText` formats a Date's time in the user's locale.
function clock(t, now, timeText) {
    var d = new Date(t), n = new Date(now);
    var time = timeText(d);
    if (sameDay(d, n)) return time;
    var y = new Date(now);
    y.setDate(y.getDate() - 1);
    if (sameDay(d, y)) return "Yesterday " + time;
    if (now - t < 6 * 86400000) return weekdays[d.getDay()] + " " + time;
    return months[d.getMonth()] + " " + d.getDate() + ", " + time;
}

/// A time today, or "Nov 18, 3:41 PM" (Fmt.time).
function when(t, now, timeText) {
    var d = new Date(t);
    return sameDay(d, new Date(now)) ? timeText(d) : months[d.getMonth()] + " " + d.getDate() + ", " + timeText(d);
}

function countText(n) { return n > 99 ? "99+" : String(n); }

/// "3 cameras · 1 offline".
function camerasText(cameras) {
    var off = offlineCount(cameras);
    return cameras.length + " camera" + (cameras.length === 1 ? "" : "s") + (off ? " · " + off + " offline" : "");
}

/// The camera list the Notifications settings page shows (it can't see the widget's state).
function cameraListJSON(cameras) {
    return JSON.stringify(cameras.map(function (c) { return { id: c.id, name: c.name, isDoorbell: c.isDoorbell }; }));
}
