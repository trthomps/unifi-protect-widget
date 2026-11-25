import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

import "../code/protect.js" as P

// The panel item (MenuBarRenderer in Logo.swift): the camera glyph with a new-event badge or dot.
// It dims while events aren't coming in, and an orange dot means an error.
MouseArea {
    id: compact

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool mono: Plasmoid.configuration.iconColor === "monochrome"
    readonly property string badgeStyle: Plasmoid.configuration.badgeStyle
    readonly property int count: root.unseenCount
    readonly property string state_: root.iconState
    readonly property bool badgeVisible: count > 0 && badgeStyle !== "none"
    readonly property real side: Math.min(vertical ? width : height, Kirigami.Units.iconSizes.large)
    readonly property real glyphSide: Kirigami.Units.iconSizes.roundedIconSize(side * 0.85)
    readonly property color ink: Kirigami.Theme.textColor
    /// Red while events are coming in; gray when they aren't (the count may be behind).
    readonly property color badgeColor: mono ? ink : state_ === "ok" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor

    Layout.minimumWidth: vertical ? -1 : Math.max(side, glyphSide) + (badge.visible ? Math.round(badge.width * 0.4) : 0)
    Layout.preferredWidth: Layout.minimumWidth
    Layout.minimumHeight: vertical ? side : -1
    Layout.preferredHeight: Layout.minimumHeight

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton) {
            root.refresh(true)
        } else {
            // A click on the icon always starts at the camera grid.
            if (!root.expanded) root.focusedCamera = ""
            root.expanded = !root.expanded
        }
    }

    CameraGlyph {
        id: glyph
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: badge.visible && !compact.vertical ? -Math.round(badge.width * 0.2) : 0
        width: compact.glyphSide
        height: compact.glyphSide
        color: compact.mono ? compact.ink : root.unifiBlue
        opacity: compact.state_ === "ok" ? (root.snoozed ? 0.5 : 1)
            : compact.state_ === "error" ? 0.4 : 0.45
    }

    // New-event count, tucked over the glyph's top-right corner.
    Rectangle {
        id: badge
        visible: compact.badgeVisible && compact.badgeStyle === "badge"
        readonly property real h: Math.max(10, Math.round(compact.glyphSide * 0.55))
        height: h
        width: Math.max(h, badgeText.implicitWidth + h * 0.5)
        radius: h / 2
        color: compact.badgeColor
        border.width: 1
        border.color: Kirigami.Theme.backgroundColor
        anchors.left: glyph.right
        anchors.top: glyph.top
        anchors.leftMargin: -Math.round(h * 0.6)
        anchors.topMargin: -Math.round(h * 0.25)
        Text {
            id: badgeText
            anchors.centerIn: parent
            text: P.countText(compact.count)
            color: compact.mono ? Kirigami.Theme.backgroundColor : "white"
            font.pixelSize: Math.round(parent.h * 0.72)
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
        }
    }

    // New-events dot, or an orange one at the bottom when something's wrong and no count shows.
    Rectangle {
        readonly property bool errorDot: compact.state_ === "error" && !compact.badgeVisible
        visible: errorDot || (compact.badgeVisible && compact.badgeStyle === "dot")
        readonly property real d: Math.max(5, Math.round(compact.glyphSide * 0.32))
        width: d
        height: d
        radius: d / 2
        color: errorDot ? (compact.mono ? compact.ink : Kirigami.Theme.neutralTextColor) : compact.badgeColor
        border.width: 1
        border.color: Kirigami.Theme.backgroundColor
        x: glyph.x + glyph.width - d + Math.round(d * 0.3)
        y: errorDot ? glyph.y + glyph.height - d : glyph.y
    }
}
