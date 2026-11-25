// Run: node kde/test/protect.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const src = fs.readFileSync(path.join(__dirname, "../package/contents/code/protect.js"), "utf8")
    .replace(/^\.pragma library.*$/m, "");
const P = {};
vm.runInNewContext(src + "\nObject.assign(P, this);", { P });

const now = Date.parse("2026-11-25T12:00:00Z");
let pass = 0;
// Objects come from another VM realm, so compare by value.
const eq = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b));
function test(name, fn) {
    try { fn(); pass++; } catch (e) { console.error("FAIL " + name); throw e; }
}

const ev = (over = {}) => Object.assign({
    id: "e1", type: "smartDetectZone", start: now - 5000, end: null, cameraID: "cam1",
    smartDetectTypes: ["person"], cameraName: "Front Door", hasThumbnail: false, notified: false,
}, over);

const prefs = (over = {}) => P.notifyPrefs(Object.assign({
    notificationsEnabled: true, snoozedUntil: 0, notifyKinds: P.DEFAULT_KINDS, mutedCameras: "", cooldown: 60,
}, over), now);

test("kinds", () => {
    eq(P.eventKinds(ev()), ["person"]);
    eq(P.eventKinds(ev({ type: "ring", smartDetectTypes: [] })), ["ring"]);
    eq(P.eventKinds(ev({ type: "motion", smartDetectTypes: [] })), ["motion"]);
    eq(P.eventKinds(ev({ type: "smartDetectZone", smartDetectTypes: [] })), ["motion"]);
    eq(P.eventKinds(ev({ type: "smartAudioDetect", smartDetectTypes: ["alrmSmoke"] })), ["audioAlarm"]);
    eq(P.eventKinds(ev({ type: "sensorOpened", smartDetectTypes: [] })), ["sensor"]);
    eq(P.eventKinds(ev({ type: "weird", smartDetectTypes: [] })), ["other"]);
    eq(P.eventKinds(ev({ smartDetectTypes: ["vehicle", "person", "car"] })), ["vehicle", "person"]);
    assert.strictEqual(P.primaryKind(ev({ smartDetectTypes: ["vehicle", "person"] })), "person");
    assert.strictEqual(P.primaryKind(ev({ type: "ring", smartDetectTypes: ["person"] })), "ring");
    assert.strictEqual(P.DEFAULT_KINDS, "ring,person,vehicle,package,audioAlarm,sensor");
});

test("summaries", () => {
    assert.strictEqual(P.summary(ev()), "Person detected");
    assert.strictEqual(P.summary(ev({ smartDetectTypes: ["vehicle", "person"] })), "Person & vehicle detected");
    assert.strictEqual(P.summary(ev({ smartDetectTypes: ["licensePlate"] })), "License plate detected");
    assert.strictEqual(P.summary(ev({ type: "ring", smartDetectTypes: [] })), "Doorbell rang");
    assert.strictEqual(P.summary(ev({ type: "smartAudioDetect", smartDetectTypes: ["alrmSmoke"] })), "Smoke alarm heard");
    assert.strictEqual(P.summary(ev({ type: "smartAudioDetect", smartDetectTypes: ["alrmDogHowl"] })), "Dog howl heard");
    assert.strictEqual(P.summary(ev({ type: "smartAudioDetect", smartDetectTypes: [] })), "Alarm sound heard");
    assert.strictEqual(P.summary(ev({ type: "sensorWaterLeak", smartDetectTypes: [] })), "Water leak");
    assert.strictEqual(P.summary(ev({ type: "sensorSomethingNew", smartDetectTypes: [] })), "Sensor something new");
    assert.strictEqual(P.summary(ev({ type: "motion", smartDetectTypes: [] })), "Motion");
    assert.strictEqual(P.summary(ev({ type: "doorAccess", smartDetectTypes: [] })), "Door access");
});

test("event messages: add, update, remove", () => {
    const names = id => id === "cam1" ? "Front Door" : null;
    let r = P.applyEventMessage([], { type: "add", item: { modelKey: "event", id: "a", type: "motion", start: now - 1000, device: "cam1" } }, now, names);
    assert.ok(r.changed);
    assert.strictEqual(r.announce, "a");
    assert.strictEqual(r.events[0].cameraName, "Front Door");
    assert.strictEqual(r.events[0].end, null);

    // Motion that turns into a person is worth another look.
    let u = P.applyEventMessage(r.events, { type: "update", item: { modelKey: "event", id: "a", smartDetectTypes: ["person"] } }, now, names);
    assert.strictEqual(u.announce, "a");
    eq(u.events[0].smartDetectTypes, ["person"]);
    // Ending it changes nothing worth announcing.
    let e = P.applyEventMessage(u.events, { type: "update", item: { modelKey: "event", id: "a", end: String(now) } }, now, names);
    assert.strictEqual(e.announce, null);
    assert.strictEqual(e.events[0].end, now);
    // The original array isn't touched.
    assert.strictEqual(r.events[0].smartDetectTypes.length, 0);

    // Removes, non-events and junk are ignored.
    assert.ok(!P.applyEventMessage(e.events, { type: "remove", item: { modelKey: "event", id: "a" } }, now).changed);
    assert.ok(!P.applyEventMessage([], { type: "add", item: { modelKey: "camera", id: "x" } }, now).changed);
    assert.ok(!P.applyEventMessage([], { type: "add", item: { modelKey: "event", id: "b", type: "ring" } }, now).changed);
    assert.ok(!P.applyEventMessage([], null, now).changed);
});

test("event messages: late updates and ordering", () => {
    // An update for an event we never saw starts it, unless it's old.
    let r = P.applyEventMessage([], { type: "update", item: { modelKey: "event", id: "late", type: "ring", start: now - 60000 } }, now);
    assert.ok(r.changed);
    assert.ok(!P.applyEventMessage([], { type: "update", item: { modelKey: "event", id: "old", type: "ring", start: now - 400000 } }, now).changed);
    // Newest first, even when an older one arrives late.
    const list = [ev({ id: "n", start: now - 1000 }), ev({ id: "o", start: now - 100000 })];
    r = P.applyEventMessage(list, { type: "update", item: { modelKey: "event", id: "m", type: "ring", start: now - 50000 } }, now);
    eq(r.events.map(e => e.id), ["n", "m", "o"]);
    r = P.applyEventMessage(list, { type: "add", item: { modelKey: "event", id: "z", type: "ring", start: now - 900000 } }, now);
    eq(r.events.map(e => e.id), ["n", "o", "z"]);
});

test("prune and log", () => {
    const list = [ev({ id: "new" }), ev({ id: "old", start: now - 8 * 86400000 })];
    const p = P.prune(list, now);
    eq(p.events.map(e => e.id), ["new"]);
    assert.strictEqual(p.removed, 1);
    assert.strictEqual(P.prune([ev()], now).removed, 0);
    const many = Array.from({ length: 510 }, (_, i) => ev({ id: "e" + i, start: now - i * 1000 }));
    assert.strictEqual(P.prune(many, now).events.length, 500);

    const text = JSON.stringify([ev({ id: "b", start: now - 10 }), ev({ id: "a" }), { id: 3 }, null, ev({ id: "c", start: "x" })]);
    eq(P.parseLog(text).map(e => e.id), ["b", "a"]);
    eq(P.parseLog("not json"), []);
    eq(P.parseLog("{}"), []);
});

test("notification rules", () => {
    const marks = {};
    assert.ok(P.shouldNotify(ev(), prefs(), marks, now));
    assert.ok(!P.shouldNotify(ev({ notified: true }), prefs(), marks, now));
    assert.ok(!P.shouldNotify(ev(), prefs({ notificationsEnabled: false }), marks, now));
    assert.ok(!P.shouldNotify(ev(), prefs({ snoozedUntil: now + 1000 }), marks, now));
    assert.ok(P.shouldNotify(ev(), prefs({ snoozedUntil: now - 1000 }), marks, now));
    assert.ok(!P.shouldNotify(ev({ start: now - 130000 }), prefs(), marks, now));
    assert.ok(!P.shouldNotify(ev(), prefs({ mutedCameras: "cam0,cam1" }), marks, now));
    assert.ok(!P.shouldNotify(ev({ smartDetectTypes: ["animal"] }), prefs(), marks, now));
    assert.ok(P.shouldNotify(ev({ smartDetectTypes: ["animal"] }), prefs({ notifyKinds: "animal" }), marks, now));
    // Any of an event's kinds counts.
    assert.ok(P.shouldNotify(ev({ smartDetectTypes: ["animal", "vehicle"] }), prefs(), marks, now));

    // Cooldown per camera and kind; rings repeat after 10 s at most.
    const recent = {};
    recent[P.cooldownKey(ev())] = now - 30000;
    assert.ok(!P.shouldNotify(ev(), prefs(), recent, now));
    assert.ok(P.shouldNotify(ev(), prefs({ cooldown: 0 }), recent, now));
    assert.ok(P.shouldNotify(ev({ cameraID: "cam2" }), prefs(), recent, now));
    const ring = ev({ type: "ring", smartDetectTypes: [] });
    const rang = {};
    rang[P.cooldownKey(ring)] = now - 11000;
    assert.ok(P.shouldNotify(ring, prefs(), rang, now));
    rang[P.cooldownKey(ring)] = now - 5000;
    assert.ok(!P.shouldNotify(ring, prefs(), rang, now));
});

test("unseen count and visibility", () => {
    const list = [
        ev({ id: "1", start: now - 1000 }),
        ev({ id: "2", start: now - 2000, type: "motion", smartDetectTypes: [] }),
        ev({ id: "3", start: now - 3000, cameraID: "muted" }),
        ev({ id: "4", start: now - 9000 }),
    ];
    assert.strictEqual(P.unseenCount(list, now - 5000, prefs({ mutedCameras: "muted" })), 1);
    assert.strictEqual(P.unseenCount(list, 0, prefs()), 3);
    assert.strictEqual(P.visibleEvents(list, false).length, 3);
    assert.strictEqual(P.visibleEvents(list, true).length, 4);
    assert.strictEqual(P.activeKind(list, "cam1", now, false), "person");
    assert.strictEqual(P.activeKind(list, "cam1", now + 200000, false), null);
    assert.strictEqual(P.activeKind([ev({ end: now })], "cam1", now, false), null);
    assert.strictEqual(P.activeKind([ev({ type: "ring", smartDetectTypes: ["person"] })], "cam1", now, false), "ring");
});

test("cameras", () => {
    const list = P.parseCameras([
        { id: "b", name: "  Yard  ", state: "CONNECTED", featureFlags: { smartDetectTypes: ["person"], supportFullHdSnapshot: true } },
        { id: "a", name: "Doorbell", state: "DISCONNECTED", lcdMessage: {} },
        { id: "c", name: "Camera 10" }, { id: "d", name: "Camera 9" }, { name: "no id" },
    ]);
    eq(list.map(c => c.id), ["d", "c", "a", "b"]);
    const yard = list[3];
    assert.strictEqual(yard.name, "Yard");
    assert.ok(yard.supportsFullHDSnapshot);
    eq(yard.smartDetectTypes, ["person"]);
    assert.ok(list[2].isDoorbell);
    assert.ok(!list[0].isDoorbell);
    assert.strictEqual(list[0].state, "UNKNOWN");
    assert.strictEqual(P.offlineCount(list), 3);
    assert.strictEqual(P.camerasText(list), "4 cameras · 3 offline");
    assert.strictEqual(P.camerasText([yard]), "1 camera");
    assert.throws(() => P.parseCameras({}));
    assert.strictEqual(P.parseCamera({ id: "x", name: "" }).name, "Camera");
    assert.strictEqual(P.consoleName({ name: "UDM Pro" }), "UDM Pro");
    assert.strictEqual(P.consoleName([{ name: "NVR" }]), "NVR");
    assert.strictEqual(P.consoleName([]), null);
});

test("device messages", () => {
    const cams = P.parseCameras([{ id: "a", name: "A", state: "CONNECTED" }, { id: "b", name: "B", state: "CONNECTED" }]);
    let r = P.applyDeviceMessage(cams, { type: "update", item: { modelKey: "camera", id: "a", state: "DISCONNECTED" } });
    assert.ok(r.changed);
    assert.strictEqual(r.cameras[0].state, "DISCONNECTED");
    assert.strictEqual(cams[0].state, "CONNECTED");
    r = P.applyDeviceMessage(cams, { type: "update", item: { modelKey: "camera", id: ["a", "b"], name: " Renamed " } });
    eq(r.cameras.map(c => c.name), ["Renamed", "Renamed"]);
    assert.ok(!P.applyDeviceMessage(cams, { type: "update", item: { modelKey: "camera", id: "a", state: "CONNECTED" } }).changed);
    assert.ok(P.applyDeviceMessage(cams, { type: "add", item: { modelKey: "camera", id: "z" } }).refresh);
    assert.ok(!P.applyDeviceMessage(cams, { type: "update", item: { modelKey: "light", id: "a", state: "x" } }).changed);
});

test("hosts and pins", () => {
    assert.strictEqual(P.normalizeHost("192.168.1.1"), "https://192.168.1.1");
    assert.strictEqual(P.normalizeHost(" https://Unifi.local/ "), "https://Unifi.local");
    assert.strictEqual(P.normalizeHost("host:8443"), "https://host:8443");
    assert.strictEqual(P.normalizeHost("http://10.0.0.1:80//"), "http://10.0.0.1:80");
    assert.strictEqual(P.normalizeHost("[fe80::1]:443"), "https://[fe80::1]:443");
    assert.strictEqual(P.normalizeHost(""), null);
    assert.strictEqual(P.normalizeHost("ftp://x"), null);
    assert.strictEqual(P.normalizeHost("a b"), null);
    assert.strictEqual(P.normalizeHost("host:99999"), null);
    assert.strictEqual(P.hostName("https://10.0.0.1:8443"), "10.0.0.1");

    let pins = P.setPin("{}", "https://a", "AB:CD");
    assert.strictEqual(P.pinFor(pins, "https://a"), "AB:CD");
    assert.strictEqual(P.pinFor(pins, "https://b"), null);
    pins = P.setPin(pins, "https://a", null);
    assert.strictEqual(P.pinFor(pins, "https://a"), null);
    assert.strictEqual(P.pinFor("garbage", "https://a"), null);
    assert.strictEqual(P.keyAccount("https://a"), "apikey:https://a");
    assert.strictEqual(P.webURL("https://a"), "https://a/protect/dashboard");
    assert.strictEqual(P.eventURL("https://a", "x/y"), "https://a/protect/events/event/x%2Fy");
});

test("errors", () => {
    const changed = P.errorInfo(P.fromBridge({ kind: "certificateChanged", fingerprint: "AB:CD:EF:01:23:45:67:89:AB:CD:EF" }));
    assert.strictEqual(changed.title, "Certificate changed");
    assert.ok(changed.message.indexOf("AB:CD:EF:01:23:45:67:89") >= 0);
    assert.strictEqual(P.errorInfo(P.fromBridge({ kind: "http", status: 500 })).title, "Console error 500");
    assert.strictEqual(P.errorInfo(P.fromBridge({ kind: "unauthorized", detail: "Nope" })).message, "Nope");
    assert.strictEqual(P.errorInfo(P.fromBridge({ kind: "mystery" })).kind, "network");
    assert.ok(P.isCertificateProblem(P.fromBridge({ kind: "untrustedCertificate" })));
    assert.ok(!P.isCertificateProblem(P.fromBridge({ kind: "network" })));
    assert.strictEqual(P.keyringError(0, ""), null);
    assert.strictEqual(P.keyringError(1, ""), null);
    assert.ok(/locked/.test(P.keyringError(124, "").detail));
    assert.strictEqual(P.keyringError(5, " boom \n").detail, "boom");
});

test("bridge helpers", () => {
    const info = { port: 4242, token: "t/k" };
    assert.strictEqual(P.bridgeURL(info, "/snapshot", { camera: "a b", hq: 1 }),
                       "http://127.0.0.1:4242/snapshot?token=t%2Fk&camera=a%20b&hq=1");
    eq(P.parseBridgeInfo('noise\n{"port": 1, "token": "x", "pid": 3}\n'), { port: 1, token: "x", pid: 3 });
    assert.strictEqual(P.parseBridgeInfo("nope"), null);
    assert.strictEqual(P.thumbnailPath("/d", "ab-12/../x"), "/d/thumbnails/ab-12x.jpg");
    assert.strictEqual(P.thumbnailPath("/d", "../"), "/d/thumbnails/invalid.jpg");
    assert.strictEqual(P.fileURL("/home/me/a b.jpg"), "file:///home/me/a%20b.jpg");
    assert.strictEqual(P.localPath("file:///home/me/a%20b/x.py"), "/home/me/a b/x.py");
    assert.strictEqual(P.shellQuote("it's"), "'it'\\''s'");
});

test("csv toggles", () => {
    assert.strictEqual(P.toggleCSV("b,a", "c", true), "a,b,c");
    assert.strictEqual(P.toggleCSV("a,b", "a", false), "b");
    assert.strictEqual(P.toggleCSV("", "a", false), "");
    assert.strictEqual(P.toggleCSV("motion,ring", "person", true, P.KINDS), "ring,person,motion");
});

test("snooze", () => {
    const at = (h, m) => { const d = new Date(2026, 10, 25, h, m); return d.getTime(); };
    assert.strictEqual(P.snoozeUntil("thirtyMinutes", at(12, 0)), at(12, 30));
    assert.strictEqual(P.snoozeUntil("fourHours", at(12, 0)), at(16, 0));
    // After midnight, "tomorrow morning" is this morning.
    assert.strictEqual(P.snoozeUntil("tomorrow", at(1, 0)), at(7, 0));
    assert.strictEqual(P.snoozeUntil("tomorrow", at(22, 0)), new Date(2026, 10, 26, 7, 0).getTime());
});

test("formatting", () => {
    const t = d => d.getHours() + ":" + String(d.getMinutes()).padStart(2, "0");
    const base = new Date(2026, 10, 25, 15, 0).getTime();
    assert.strictEqual(P.ago(base - 30000, base), "just now");
    assert.strictEqual(P.ago(base - 30000, base, true), "now");
    assert.strictEqual(P.ago(base - 5 * 60000, base), "5m ago");
    assert.strictEqual(P.ago(base - 3 * 3600000, base, true), "3h");
    assert.strictEqual(P.ago(base - 2 * 86400000, base), "2d ago");
    assert.strictEqual(P.clock(new Date(2026, 10, 25, 9, 5).getTime(), base, t), "9:05");
    assert.strictEqual(P.clock(new Date(2026, 10, 24, 9, 5).getTime(), base, t), "Yesterday 9:05");
    assert.strictEqual(P.clock(new Date(2026, 10, 21, 9, 5).getTime(), base, t), "Sat 9:05");
    assert.strictEqual(P.clock(new Date(2026, 10, 2, 9, 5).getTime(), base, t), "Nov 2, 9:05");
    assert.strictEqual(P.when(new Date(2026, 10, 26, 7, 0).getTime(), base, t), "Nov 26, 7:00");
    assert.strictEqual(P.countText(120), "99+");
});

console.log(`${pass} tests passed`);
