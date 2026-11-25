import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/protect.js" as P

// One camera large (CameraDetail in PopoverView.swift): a high-quality snapshot about once a
// second, a mute button for its notifications, and its recent events.
ColumnLayout {
    id: detail

    required property var camera
    property bool active: true
    readonly property bool connected: P.isConnected(camera)
    readonly property bool muted: root.mutedCameras.indexOf(camera.id) >= 0
    readonly property var recent: root.visibleEvents.filter(e => e.cameraID === camera.id).slice(0, 30)

    spacing: Kirigami.Units.smallSpacing

    Item {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        Layout.bottomMargin: 0
        // Doorbells are 4:3 (or taller); show the whole frame rather than crop it.
        Layout.preferredHeight: width / Math.max(view.frameAspect, 1)

        SnapshotImage {
            id: view
            anchors.fill: parent
            radius: Kirigami.Units.cornerRadius
            cameraID: detail.camera.id
            offline: !detail.connected
            highQuality: detail.camera.supportsFullHDSnapshot
            live: true
            active: detail.active
            fill: false
        }

        Rectangle {
            id: liveBadge
            visible: detail.connected && view.takenAt > 0
            readonly property real age: (clock.t - view.takenAt) / 1000
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Kirigami.Units.smallSpacing
            width: liveRow.implicitWidth + Kirigami.Units.smallSpacing * 2
            height: liveRow.implicitHeight + Kirigami.Units.smallSpacing
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.5)
            RowLayout {
                id: liveRow
                anchors.centerIn: parent
                spacing: Math.round(Kirigami.Units.smallSpacing / 2)
                Rectangle {
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
                    color: liveBadge.age < 4 ? "#da4453" : "gray"
                }
                PlasmaComponents.Label {
                    text: liveBadge.age < 4 ? i18n("LIVE") : i18n("%1s old", Math.floor(liveBadge.age))
                    color: "white"
                    font.pixelSize: Math.round(Kirigami.Theme.smallFont.pixelSize * 0.9)
                    font.weight: Font.Bold
                }
            }
            Timer {
                id: clock
                property real t: Date.now()
                interval: 1000
                repeat: true
                running: liveBadge.visible
                onTriggered: t = Date.now()
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing
        PlasmaComponents.ToolButton {
            text: i18n("Open in Protect")
            icon.name: "globe"
            enabled: root.host !== ""
            onClicked: root.openURL(P.webURL(root.host))
        }
        PlasmaComponents.ToolButton {
            text: i18n("Mute notifications")
            icon.name: "notifications-disabled"
            checkable: true
            checked: detail.muted
            onToggled: root.setMuted(detail.camera.id, checked)
        }
        Item { Layout.fillWidth: true }
        PlasmaComponents.Label {
            text: detail.connected
                ? (detail.camera.supportsFullHDSnapshot ? i18n("about 1 frame per second, HD") : i18n("about 1 frame per second"))
                : i18n("offline")
            font: Kirigami.Theme.smallFont
            opacity: 0.5
        }
    }

    Kirigami.Separator {
        Layout.fillWidth: true
        visible: detail.recent.length > 0
    }

    ListView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: Math.min(contentHeight, Kirigami.Units.gridUnit * 6)
        visible: detail.recent.length > 0
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: EventListModel { events: detail.recent }
        delegate: EventRow {
            required property string json
            width: ListView.view.width
            event: JSON.parse(json)
            showCamera: false
            onClicked: {}
        }
    }

    Item {
        Layout.fillHeight: true
        visible: detail.recent.length === 0
    }
}
