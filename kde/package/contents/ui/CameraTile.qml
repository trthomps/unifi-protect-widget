import QtQuick
import org.kde.plasma.plasmoid
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/protect.js" as P

// One camera in the grid (CameraTile in PopoverView.swift): a fixed 16:9 frame the snapshot
// fills, its name, and a red outline and icon while a detection is in progress.
Item {
    id: tile

    required property var camera
    property int tick: 0
    property bool active: true
    readonly property string activeKind: P.activeKind(root.events, camera.id, root.now, Plasmoid.configuration.showMotionInList)
    readonly property bool muted: root.mutedCameras.indexOf(camera.id) >= 0
    readonly property bool connected: P.isConnected(camera)

    signal clicked()

    implicitHeight: width * 9 / 16

    SnapshotImage {
        id: image
        anchors.fill: parent
        radius: Kirigami.Units.cornerRadius
        cameraID: tile.camera.id
        offline: !tile.connected
        tick: tile.tick
        active: tile.active
        decodeWidth: Math.round(tile.width * 2)
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: parent.height / 2
        radius: Kirigami.Units.cornerRadius
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.55) }
        }
    }

    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Math.round(Kirigami.Units.smallSpacing / 2)
        Kirigami.Icon {
            visible: tile.camera.isDoorbell
            source: "notifications-symbolic"
            color: "white"
            isMask: true
            Layout.preferredWidth: Math.round(Kirigami.Units.iconSizes.small * 0.75)
            Layout.preferredHeight: Layout.preferredWidth
        }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: tile.camera.name
            color: "white"
            elide: Text.ElideRight
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            font.weight: Font.DemiBold
            style: Text.Raised
            styleColor: Qt.rgba(0, 0, 0, 0.5)
        }
        Kirigami.Icon {
            visible: tile.muted
            source: "notifications-disabled-symbolic"
            color: "white"
            isMask: true
            opacity: 0.8
            Layout.preferredWidth: Math.round(Kirigami.Units.iconSizes.small * 0.75)
            Layout.preferredHeight: Layout.preferredWidth
        }
    }

    Rectangle {
        visible: tile.activeKind !== null
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Kirigami.Units.smallSpacing
        width: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
        height: width
        radius: width / 2
        color: tile.activeKind === "ring" ? "#f67400" : Kirigami.Theme.negativeTextColor
        Kirigami.Icon {
            anchors.centerIn: parent
            width: Math.round(Kirigami.Units.iconSizes.small * 0.75)
            height: width
            source: tile.activeKind ? P.kindInfo[tile.activeKind].icon : ""
            color: "white"
            isMask: true
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: Kirigami.Units.cornerRadius
        border.width: tile.activeKind !== null ? 2 : 1
        border.color: tile.activeKind !== null ? Kirigami.Theme.negativeTextColor
            : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b,
                      mouse.containsMouse ? 0.35 : 0.1)
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.clicked()
    }

    PlasmaComponents.ToolTip {
        text: tile.connected ? i18n("Show %1", tile.camera.name) : i18n("%1 is offline", tile.camera.name)
        visible: mouse.containsMouse
    }
}
