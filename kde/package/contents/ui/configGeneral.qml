import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property string cfg_iconColor
    property string cfg_badgeStyle
    property int cfg_gridRefresh
    property bool cfg_showMotionInList
    property int cfg_requestClearLog
    property string cfg_consoleStatus

    readonly property var status: { try { return JSON.parse(cfg_consoleStatus || "{}") } catch (e) { return {} } }
    property bool clearPending: false

    component Choice: QQC2.ComboBox {
        required property var current
        signal picked(var value)
        textRole: "text"
        valueRole: "value"
        Component.onCompleted: currentIndex = Math.max(0, indexOfValue(current))
        onActivated: picked(currentValue)
    }

    component Note: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        wrapMode: Text.WordWrap
        opacity: 0.7
        font: Kirigami.Theme.smallFont
    }

    Kirigami.FormLayout {
        Choice {
            Kirigami.FormData.label: i18n("Icon:")
            current: page.cfg_iconColor
            model: [
                { value: "monochrome", text: i18n("Monochrome (follows the panel's text color)") },
                { value: "color", text: i18n("Blue") }
            ]
            onPicked: value => page.cfg_iconColor = value
        }
        Choice {
            Kirigami.FormData.label: i18n("New events:")
            current: page.cfg_badgeStyle
            model: [
                { value: "badge", text: i18n("Count") },
                { value: "dot", text: i18n("Dot") },
                { value: "none", text: i18n("None") }
            ]
            onPicked: value => page.cfg_badgeStyle = value
        }
        Note {
            text: i18n("The badge counts events you'd be notified about that arrived since you last opened the popup. The icon dims while the widget isn't receiving events, and an orange dot means an error.")
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        Choice {
            Kirigami.FormData.label: i18n("Refresh snapshots every:")
            current: page.cfg_gridRefresh
            model: [
                { value: 2, text: i18n("2 seconds") },
                { value: 5, text: i18n("5 seconds") },
                { value: 10, text: i18n("10 seconds") },
                { value: 30, text: i18n("30 seconds") }
            ]
            onPicked: value => page.cfg_gridRefresh = value
        }
        Note {
            text: i18n("Only while the cameras are on screen. A camera you click on refreshes about once a second in high quality.")
        }
        QQC2.CheckBox {
            text: i18n("Show plain motion in the event list")
            checked: page.cfg_showMotionInList
            onToggled: page.cfg_showMotionInList = checked
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        RowLayout {
            Kirigami.FormData.label: i18n("Event log:")
            QQC2.Label {
                text: page.clearPending ? i18n("Cleared when you apply")
                    : i18np("%1 event from the last 7 days", "%1 events from the last 7 days", page.status.events || 0)
            }
            QQC2.Button {
                text: i18n("Clear")
                icon.name: "edit-clear-history"
                enabled: !page.clearPending && (page.status.events || 0) > 0
                onClicked: { page.cfg_requestClearLog = page.cfg_requestClearLog + 1; page.clearPending = true }
            }
        }
        Note {
            text: i18n("Protect's API sends events as they happen but can't list past ones, so the list only covers time when the widget was running and connected. It's kept with its thumbnails in ~/.local/share/protect-cameras-kde/.")
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: i18n("Middle-click the panel icon to refresh. Right-click it to pause notifications or send a test notification.")
        }
    }
}
