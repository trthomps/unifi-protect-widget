import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

import "../code/protect.js" as P

KCM.SimpleKCM {
    id: page

    property bool cfg_notificationsEnabled
    property string cfg_notifyKinds
    property string cfg_mutedCameras
    property int cfg_cooldown
    property string cfg_notificationClick
    property real cfg_snoozedUntil
    property string cfg_cameraList

    readonly property var cameras: { try { return JSON.parse(cfg_cameraList || "[]") } catch (e) { return [] } }
    readonly property var kinds: P.csvList(cfg_notifyKinds)
    readonly property var muted: P.csvList(cfg_mutedCameras)

    component Note: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        wrapMode: Text.WordWrap
        opacity: 0.7
        font: Kirigami.Theme.smallFont
    }

    Kirigami.FormLayout {
        QQC2.CheckBox {
            text: i18n("Show desktop notifications for Protect events")
            checked: page.cfg_notificationsEnabled
            onToggled: page.cfg_notificationsEnabled = checked
        }
        RowLayout {
            visible: page.cfg_snoozedUntil > Date.now()
            QQC2.Label {
                text: i18n("Paused until %1.", Qt.formatDateTime(new Date(page.cfg_snoozedUntil), Qt.locale().dateTimeFormat(Locale.ShortFormat)))
            }
            QQC2.Button {
                text: i18n("Resume")
                onClicked: page.cfg_snoozedUntil = 0
            }
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Notify me about") }

        Repeater {
            model: P.KINDS.filter(k => k !== "other")
            delegate: QQC2.CheckBox {
                required property string modelData
                enabled: page.cfg_notificationsEnabled
                text: i18n(P.kindInfo[modelData].title)
                icon.name: P.kindInfo[modelData].icon
                checked: page.kinds.indexOf(modelData) >= 0
                onToggled: page.cfg_notifyKinds = P.toggleCSV(page.cfg_notifyKinds, modelData, checked, P.KINDS)
            }
        }
        Note {
            text: i18n("What Protect can detect depends on the camera and on the detections turned on in Protect. Plain motion fires a lot, so it's off by default.")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Cameras")
            visible: page.cameras.length > 0
        }

        Repeater {
            model: page.cameras
            delegate: QQC2.CheckBox {
                required property var modelData
                enabled: page.cfg_notificationsEnabled
                text: modelData.isDoorbell ? i18n("%1 (doorbell)", modelData.name) : modelData.name
                checked: page.muted.indexOf(modelData.id) < 0
                onToggled: page.cfg_mutedCameras = P.toggleCSV(page.cfg_mutedCameras, modelData.id, !checked)
            }
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Don't repeat within:")
            enabled: page.cfg_notificationsEnabled
            textRole: "text"
            valueRole: "value"
            model: [
                { value: 0, text: i18n("No limit") },
                { value: 30, text: i18n("30 seconds") },
                { value: 60, text: i18n("1 minute") },
                { value: 120, text: i18n("2 minutes") },
                { value: 300, text: i18n("5 minutes") }
            ]
            Component.onCompleted: {
                const i = indexOfValue(page.cfg_cooldown)
                currentIndex = i >= 0 ? i : 2
            }
            onActivated: page.cfg_cooldown = currentValue
        }
        Note {
            text: i18n("Per camera and per kind, so a person walking around the yard is one notification, not ten. Doorbell rings repeat after 10 seconds at most.")
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Clicking a notification:")
            enabled: page.cfg_notificationsEnabled
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "popover", text: i18n("Shows the camera here") },
                { value: "web", text: i18n("Opens the event in Protect") }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_notificationClick))
            onActivated: page.cfg_notificationClick = currentValue
        }
        Note {
            text: i18n("Notifications carry the snapshot taken when the event arrived. Alarm sounds (smoke, CO…) are sent as urgent. Sounds and popups follow System Settings → Notifications. To try it, right-click the panel icon → Send Test Notification.")
        }
    }
}
