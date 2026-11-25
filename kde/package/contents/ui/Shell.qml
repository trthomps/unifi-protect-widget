import QtQuick
import org.kde.plasma.plasma5support as P5Support

import "../code/protect.js" as P

// Runs shell commands through Plasma's executable data engine (QML can't start processes on its
// own). run() returns a Promise of { code, stdout, stderr }.
P5Support.DataSource {
    id: shell
    engine: "executable"
    connectedSources: []

    property var callbacks: ({})
    property int serial: 0

    onNewData: (source, data) => {
        const cb = callbacks[source]
        delete callbacks[source]
        disconnectSource(source)
        if (cb) cb(data["exit code"], data["stdout"] || "", data["stderr"] || "")
    }

    function run(command) {
        return new Promise(resolve => {
            // A unique trailing comment lets the same command run again while an old one lingers.
            // Nothing may hang the widget (e.g. secret-tool waiting on a keyring unlock prompt):
            // give every command 25 seconds. timeout signals the whole process group.
            const source = "timeout 25 sh -c " + P.shellQuote(command) + " # " + (++serial)
            callbacks[source] = (code, stdout, stderr) => resolve({ code, stdout, stderr })
            connectSource(source)
        })
    }

    readonly property string secretService: "io.github.trthomps.protect-cameras"
    readonly property string bridgeScript: P.localPath(Qt.resolvedUrl("../code/protect-bridge.py"))

    /// Starts the bridge for this widget instance, or finds the one already running. Resolves to
    /// { port, token, pid, dataDir }; rejects with a "bridge" error.
    function startBridge(instance) {
        return run("python3 " + P.shellQuote(bridgeScript) + " start --instance " + P.shellQuote(String(instance)))
            .then(r => {
                const info = r.code === 0 ? P.parseBridgeInfo(r.stdout) : null
                if (info) return info
                if (r.code === 127) throw P.apiError("bridge", i18n("python3 isn't installed. The widget needs it to talk to the console."))
                throw P.apiError("bridge", (r.stderr.trim().split("\n").pop() || i18n("The widget's helper exited with code %1.", r.code)))
            })
    }

    /// Resolves to whether a key is stored. Rejects (kind "keyring") when secret-tool is missing,
    /// times out on a locked keyring, or fails.
    function hasSecret(account) {
        return run("secret-tool lookup service " + P.shellQuote(secretService) + " account " + P.shellQuote(account)
                   + " >/dev/null").then(r => {
            const err = P.keyringError(r.code, r.stderr)
            if (err) throw err
            return r.code === 0
        })
    }

    /// For the user to run in a terminal: secret-tool prompts for the key, so it never lands in
    /// shell history or a process listing.
    function storeCommand(account, label) {
        return "secret-tool store --label=" + P.shellQuote(label)
            + " service " + P.shellQuote(secretService) + " account " + P.shellQuote(account)
    }

    function clearCommand(account) {
        return "secret-tool clear service " + P.shellQuote(secretService) + " account " + P.shellQuote(account)
    }

    /// PROTECT_CAMERAS_HOST from plasmashell's environment (the key is only checked for presence).
    function readEnvironment() {
        return run('printf "%s\\n" "$PROTECT_CAMERAS_HOST"; [ -n "$PROTECT_CAMERAS_API_KEY" ] && echo key').then(r => {
            const lines = r.stdout.split("\n")
            const host = P.normalizeHost(lines[0] || "")
            return host ? { host: host, hasKey: lines[1] === "key" } : null
        })
    }
}
