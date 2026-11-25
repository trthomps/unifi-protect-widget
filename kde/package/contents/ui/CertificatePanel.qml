import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/protect.js" as P

// A self-signed (or changed) certificate: its SHA-256 fingerprint to compare with the browser's,
// and the button that trusts exactly that certificate from now on.
ColumnLayout {
    id: panel

    readonly property var info: P.errorInfo(root.error)
    readonly property string fingerprint: info && info.fingerprint ? info.fingerprint : ""

    spacing: Kirigami.Units.smallSpacing

    PlasmaComponents.Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        opacity: 0.8
        text: root.error && root.error.kind === "certificateChanged"
            ? i18n("The console's certificate changed since you trusted it. That's expected after a console reset, a firmware update that regenerated it, or installing your own. Otherwise, something may be intercepting the connection.")
            : i18n("%1 presented a certificate your system doesn't trust, which is normal for a UniFi console's built-in self-signed one. Compare this SHA-256 fingerprint with the one your browser shows for the console (click the lock or warning icon in the address bar → certificate details), then trust it. The widget will only accept this exact certificate from now on.",
                   P.hostName(root.pinHost) || i18n("The console"))
    }
    PlasmaComponents.TextArea {
        Layout.fillWidth: true
        readOnly: true
        wrapMode: Text.WrapAnywhere
        font.family: "monospace"
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        text: panel.fingerprint
    }
    PlasmaComponents.Button {
        Layout.alignment: Qt.AlignRight
        text: i18n("Trust This Certificate")
        icon.name: "security-high"
        enabled: panel.fingerprint !== "" && root.pinHost !== ""
        onClicked: root.trustCertificate(panel.fingerprint)
    }
}
