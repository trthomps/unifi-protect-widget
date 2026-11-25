import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

import "../code/protect.js" as P

KCM.SimpleKCM {
    id: page

    property string cfg_host
    property string cfg_pinnedFingerprints
    property string cfg_consoleStatus

    readonly property string host: P.normalizeHost(cfg_host) || ""
    /// The console the widget would use: this one, or PROTECT_CAMERAS_HOST.
    readonly property string effectiveHost: host || (env ? env.host : "")
    readonly property string account: P.keyAccount(effectiveHost)
    /// The widget's state when this page opened (it can't see the widget live).
    readonly property var status: { try { return JSON.parse(cfg_consoleStatus || "{}") } catch (e) { return {} } }
    readonly property bool statusCurrent: (status.host || "") === effectiveHost
    readonly property var statusError: statusCurrent && status.error ? status.error : null
    readonly property string pinned: P.pinFor(cfg_pinnedFingerprints, effectiveHost) || ""
    readonly property string pendingFingerprint: statusError && P.isCertificateProblem(statusError)
        && statusError.fingerprint !== pinned ? statusError.fingerprint : ""

    /// null while unknown, else whether the keyring has a key for this console.
    property var hasKey: null
    property string keyringError: ""
    property var env: null

    onAccountChanged: refreshKeyState()

    Shell { id: shell }

    Timer {
        // The address field changes on every keystroke; look the key up once typing pauses.
        id: keyTimer
        interval: 600
        onTriggered: {
            const account = page.account
            if (!page.effectiveHost) { page.hasKey = null; return }
            shell.hasSecret(account).then(found => {
                if (account !== page.account) return
                page.keyringError = ""
                page.hasKey = found
            }, err => {
                if (account === page.account) page.keyringError = err.detail
            })
        }
    }

    function refreshKeyState() {
        hasKey = null
        keyringError = ""
        keyTimer.restart()
    }

    Component.onCompleted: {
        shell.readEnvironment().then(e => { env = e })
        refreshKeyState()
    }

    function clearKey() {
        shell.run(shell.clearCommand(account)).then(() => refreshKeyState())
    }

    component Note: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 24
        wrapMode: Text.WordWrap
        opacity: 0.7
        font: Kirigami.Theme.smallFont
    }

    component Value: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 24
        wrapMode: Text.WordWrap
    }

    Kirigami.FormLayout {
        QQC2.TextField {
            Kirigami.FormData.label: i18n("Console:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            placeholderText: page.env ? page.env.host : "192.168.1.1 or unifi.example.com"
            text: page.cfg_host
            onTextEdited: page.cfg_host = text.trim()
        }
        Note {
            visible: page.cfg_host.trim() !== "" && page.host !== page.cfg_host.trim()
            text: page.host ? i18n("Uses %1", page.host) : i18n("That doesn't look like an address.")
        }
        Note {
            visible: page.cfg_host.trim() === "" && page.env !== null
            text: page.env ? i18n("Using %1 from PROTECT_CAMERAS_HOST until you fill this in.", page.env.host) : ""
        }
        Note {
            text: i18n("If your console has a real certificate for a hostname, use that name. With an IP address or the built-in self-signed certificate, the widget asks you to confirm the certificate's fingerprint once.")
        }

        // MARK: API key

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("API key") }

        Note {
            opacity: 1
            font: Kirigami.Theme.defaultFont
            text: i18n("Create a key in Protect: Settings → Control Plane → Integrations → Create API Key (UniFi OS 4.1 / Protect 5.3 or later). Then store it in your keyring by running this in a terminal (it asks for the key, so it never lands in your shell history):")
        }

        RowLayout {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
            QQC2.TextField {
                id: storeCommand
                Layout.fillWidth: true
                readOnly: true
                font.family: "monospace"
                text: page.effectiveHost ? shell.storeCommand(page.account, "Protect Cameras (" + page.effectiveHost + ")")
                                         : i18n("Enter the console's address first")
                enabled: page.effectiveHost !== ""
            }
            QQC2.Button {
                icon.name: "edit-copy"
                enabled: page.effectiveHost !== ""
                onClicked: { storeCommand.selectAll(); storeCommand.copy(); storeCommand.deselect() }
                QQC2.ToolTip.text: i18n("Copy")
                QQC2.ToolTip.visible: hovered
            }
        }

        RowLayout {
            visible: page.effectiveHost !== ""
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                source: page.hasKey ? "checkmark" : "dialog-information"
                visible: page.hasKey !== null
            }
            QQC2.Label {
                text: page.keyringError ? page.keyringError
                    : page.hasKey === null ? i18n("Checking the keyring…")
                    : page.hasKey ? i18n("A key is stored for this console.")
                    : page.env && page.env.hasKey && page.env.host === page.effectiveHost ? i18n("Using PROTECT_CAMERAS_API_KEY.")
                    : i18n("No key stored for this console yet.")
            }
            QQC2.Button {
                visible: page.hasKey === true
                text: i18n("Remove")
                icon.name: "edit-delete"
                onClicked: page.clearKey()
            }
            QQC2.Button {
                visible: page.hasKey !== null
                icon.name: "view-refresh"
                onClicked: page.refreshKeyState()
                QQC2.ToolTip.text: i18n("Look again")
                QQC2.ToolTip.visible: hovered
            }
        }
        Note {
            text: i18n("The widget picks up a newly stored key within 30 seconds; middle-click its icon to make it look now. It only reads from Protect: it never changes settings, arms anything, or talks through a doorbell.")
        }

        // MARK: Certificate

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Certificate")
            visible: page.pendingFingerprint !== "" || page.pinned !== ""
        }

        Value {
            visible: page.pendingFingerprint !== ""
            color: Kirigami.Theme.neutralTextColor
            text: page.statusError && page.statusError.kind === "certificateChanged"
                ? i18n("The console's certificate changed since you trusted it. That's expected after a console reset, a firmware update that regenerated it, or installing your own. Otherwise, something may be intercepting the connection.")
                : i18n("%1 presented a certificate your system doesn't trust, which is normal for a UniFi console's built-in self-signed one. Compare this SHA-256 fingerprint with the one your browser shows for the console, then trust it. The widget will only accept this exact certificate from now on.", P.hostName(page.effectiveHost))
        }
        QQC2.TextArea {
            visible: page.pendingFingerprint !== ""
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
            Layout.fillWidth: true
            readOnly: true
            wrapMode: Text.WrapAnywhere
            font.family: "monospace"
            text: page.pendingFingerprint
        }
        QQC2.Button {
            visible: page.pendingFingerprint !== ""
            text: i18n("Trust This Certificate")
            icon.name: "security-high"
            onClicked: page.cfg_pinnedFingerprints = P.setPin(page.cfg_pinnedFingerprints, page.effectiveHost, page.pendingFingerprint)
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Trusted:")
            visible: page.pendingFingerprint === "" && page.pinned !== ""
            QQC2.Label {
                text: page.pinned.slice(0, 23) + "…"
                font.family: "monospace"
                QQC2.ToolTip.text: page.pinned
                QQC2.ToolTip.visible: pinHover.hovered
                HoverHandler { id: pinHover }
            }
            QQC2.Button {
                text: i18n("Forget")
                onClicked: page.cfg_pinnedFingerprints = P.setPin(page.cfg_pinnedFingerprints, page.effectiveHost, null)
            }
        }
        Note {
            visible: page.pendingFingerprint !== "" || page.pinned !== ""
            text: i18n("Takes effect when you apply. The popup also offers to trust a certificate when it sees a new one.")
        }

        // MARK: Status

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Status") }

        Value {
            Kirigami.FormData.label: i18n("Status:")
            text: {
                if (!page.effectiveHost) return i18n("Not set up")
                if (!page.statusCurrent) return i18n("Apply to connect")
                if (page.statusError) {
                    const e = P.errorInfo(P.fromBridge(page.statusError))
                    return P.isCertificateProblem(page.statusError) ? e.title : e.title + ". " + e.message
                }
                if (!page.status.fetched) return i18n("Connecting…")
                return page.status.live ? i18n("Connected, receiving events") : i18n("Connected, event stream reconnecting")
            }
        }
        Value {
            Kirigami.FormData.label: i18n("Console:")
            visible: page.statusCurrent && !!page.status.name
            text: page.status.name || ""
        }
        Value {
            Kirigami.FormData.label: i18n("Protect:")
            visible: page.statusCurrent && !!page.status.version
            text: page.status.version || ""
        }
        Value {
            Kirigami.FormData.label: i18n("Cameras:")
            visible: page.statusCurrent && (page.status.cameras || 0) > 0
            text: page.status.offline ? i18n("%1 (%2 offline)", page.status.cameras, page.status.offline) : String(page.status.cameras || 0)
        }
        Note {
            text: i18n("As of when you opened this page. The key lives in your keyring (KWallet or GNOME Keyring) through the Secret Service; the widget's helper reads it and never shows it to the widget. The address and trusted certificates are in ~/.config/plasma-org.kde.plasma.desktop-appletsrc.")
        }
    }
}
