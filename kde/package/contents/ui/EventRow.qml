import QtQuick
import org.kde.plasma.plasmoid
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/protect.js" as P

// One event in the list (EventRow in PopoverView.swift): the snapshot taken when it arrived, what
// happened, where and when, and a dot until you've seen it.
PlasmaComponents.ItemDelegate {
    id: row

    required property var event
    property bool showCamera: true
    readonly property bool isNew: event.start > Plasmoid.configuration.lastSeen
    readonly property string kind: P.primaryKind(event)
    readonly property bool active: P.isActive(event, root.now)

    function tintColor(t) {
        switch (t) {
        case "orange": return "#f67400"
        case "red": return Kirigami.Theme.negativeTextColor
        case "blue": return "#3daee9"
        case "purple": return "#9b59b6"
        case "brown": return "#a0785a"
        case "green": return Kirigami.Theme.positiveTextColor
        default: return Kirigami.Theme.disabledTextColor
        }
    }

    leftPadding: Kirigami.Units.largeSpacing
    rightPadding: Kirigami.Units.largeSpacing
    topPadding: Kirigami.Units.smallSpacing
    bottomPadding: Kirigami.Units.smallSpacing

    contentItem: RowLayout {
        spacing: Kirigami.Units.largeSpacing

        Rectangle {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
            Layout.preferredHeight: Layout.preferredWidth * 9 / 16
            radius: Kirigami.Units.cornerRadius / 2
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
            clip: true
            Image {
                id: thumb
                anchors.fill: parent
                source: root.thumbnailURL(row.event)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: Kirigami.Units.gridUnit * 8
                visible: status === Image.Ready
            }
            Kirigami.Icon {
                anchors.centerIn: parent
                visible: thumb.status !== Image.Ready
                width: Kirigami.Units.iconSizes.small
                height: width
                source: P.kindInfo[row.kind].icon
                opacity: 0.4
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: P.kindInfo[row.kind].icon
                    color: row.tintColor(P.kindInfo[row.kind].tint)
                    isMask: P.kindInfo[row.kind].tint !== ""
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: P.summary(row.event)
                    font.weight: row.isNew ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                }
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                readonly property string time: P.clock(row.event.start, root.now, root.timeText)
                text: row.showCamera
                    ? (root.cameraName(row.event.cameraID) || row.event.cameraName || i18n("Unknown camera")) + " · " + time
                    : time
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                elide: Text.ElideRight
            }
        }

        PlasmaComponents.Label {
            text: row.active ? i18n("NOW") : P.ago(row.event.start, root.now, true)
            color: row.active ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
            opacity: row.active ? 1 : 0.7
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            font.weight: row.active ? Font.Bold : Font.Normal
            font.features: { "tnum": 1 }
        }
        Rectangle {
            Layout.preferredWidth: Math.round(Kirigami.Units.smallSpacing * 1.75)
            Layout.preferredHeight: Layout.preferredWidth
            radius: width / 2
            color: row.isNew ? Kirigami.Theme.highlightColor : "transparent"
        }
    }
}
