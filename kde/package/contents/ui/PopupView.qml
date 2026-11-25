import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

import "../code/protect.js" as P

// The popup (PopoverView.swift): a camera grid or the event log, one camera large, and the
// pause/open controls.
PlasmaExtras.Representation {
    id: popup

    readonly property string tab: Plasmoid.configuration.popupTab === "events" ? "events" : "cameras"
    readonly property var focused: root.camera(root.focusedCamera)
    readonly property var errorInfo: P.errorInfo(root.error)
    /// Nothing to show yet: an error, or the first load.
    readonly property bool blank: root.cameras.length === 0 && (root.error !== null || root.lastFetched === 0)
    readonly property bool gridShown: root.feedsActive && !blank && root.focusedCamera === "" && tab === "cameras"

    Layout.minimumWidth: Kirigami.Units.gridUnit * 22
    Layout.preferredWidth: Kirigami.Units.gridUnit * 28
    Layout.minimumHeight: Kirigami.Units.gridUnit * 14
    Layout.preferredHeight: Kirigami.Units.gridUnit * 30
    collapseMarginsHint: true

    // Grid snapshots refresh on a timer while the grid is on screen; nothing is fetched otherwise.
    property int gridTick: 0
    Timer {
        interval: root.gridRefresh * 1000
        repeat: true
        running: popup.gridShown
        onTriggered: popup.gridTick += 1
    }
    // On the desktop the popup never closes, so leaving the event list is what marks events seen.
    onTabChanged: if (root.planar && tab !== "events") root.markSeen()

    Keys.onEscapePressed: event => {
        if (root.focusedCamera !== "") { root.focusedCamera = ""; event.accepted = true }
        else event.accepted = false
    }

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.ToolButton {
                visible: root.focusedCamera !== ""
                icon.name: "go-previous"
                onClicked: root.focusedCamera = ""
                PlasmaComponents.ToolTip { text: i18n("Back") }
            }
            CameraGlyph {
                visible: root.focusedCamera === ""
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.leftMargin: Kirigami.Units.smallSpacing
                color: root.unifiBlue
            }
            Kirigami.Heading {
                level: 4
                Layout.maximumWidth: popup.width * 0.4
                elide: Text.ElideRight
                text: popup.focused ? popup.focused.name : (root.consoleInfo && root.consoleInfo.name) || i18n("Protect")
            }
            RowLayout {
                visible: root.lastFetched > 0
                spacing: Math.round(Kirigami.Units.smallSpacing / 2)
                Rectangle {
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
                    color: root.isLive ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                }
                PlasmaComponents.Label {
                    id: liveLabel
                    text: root.isLive ? i18n("Live") : i18n("No events")
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    MouseArea {
                        id: liveHover
                        anchors.fill: parent
                        hoverEnabled: true
                    }
                    PlasmaComponents.ToolTip {
                        visible: liveHover.containsMouse
                        text: {
                            if (root.isLive) return i18n("Connected to Protect's event stream")
                            const e = P.errorInfo(root.socketError)
                            return e ? i18n("Not receiving events: %1. %2", e.title, e.message) : i18n("Not receiving events. Reconnecting…")
                        }
                    }
                }
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.ToolButton {
                visible: root.focusedCamera === "" && !popup.blank
                text: i18n("Cameras")
                checkable: true
                checked: popup.tab === "cameras"
                onClicked: Plasmoid.configuration.popupTab = "cameras"
            }
            PlasmaComponents.ToolButton {
                visible: root.focusedCamera === "" && !popup.blank
                text: root.unseenCount > 0 ? i18n("Events (%1)", root.unseenCount) : i18n("Events")
                checkable: true
                checked: popup.tab === "events"
                onClicked: Plasmoid.configuration.popupTab = "events"
            }
            PlasmaComponents.BusyIndicator {
                visible: root.refreshing
                running: visible
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }
            PlasmaComponents.ToolButton {
                visible: !root.refreshing
                icon.name: "view-refresh"
                onClicked: { root.refresh(true); popup.gridTick += 1 }
                PlasmaComponents.ToolTip { text: i18n("Refresh now") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "configure"
                onClicked: Plasmoid.internalAction("configure").trigger()
                PlasmaComponents.ToolTip { text: i18n("Settings") }
            }
        }
    }

    footer: PlasmaExtras.PlasmoidHeading {
        position: PlasmaComponents.ToolBar.Footer
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                visible: root.snoozed
                source: "notifications-disabled"
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }
            PlasmaComponents.Label {
                Layout.leftMargin: root.snoozed ? 0 : Kirigami.Units.smallSpacing
                Layout.fillWidth: true
                elide: Text.ElideRight
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                text: root.snoozed ? i18n("Paused until %1", P.when(Plasmoid.configuration.snoozedUntil, root.now, root.timeText))
                    : root.lastFetched > 0 ? i18n("%1 · updated %2", P.camerasText(root.cameras), P.ago(root.lastFetched, root.now))
                    : ""
            }
            PlasmaComponents.ToolButton {
                visible: root.snoozed
                text: i18n("Resume")
                font: Kirigami.Theme.smallFont
                onClicked: root.snooze("")
            }
            PlasmaComponents.ToolButton {
                id: pauseButton
                visible: !root.snoozed
                icon.name: "notifications-disabled"
                onClicked: pauseMenu.popup(pauseButton, 0, pauseButton.height)
                PlasmaComponents.ToolTip { text: i18n("Pause notifications") }
                QQC2.Menu {
                    id: pauseMenu
                    Repeater {
                        model: P.SNOOZE
                        delegate: QQC2.MenuItem {
                            required property var modelData
                            text: i18n(modelData.title)
                            onTriggered: root.snooze(modelData.id)
                        }
                    }
                }
            }
            PlasmaComponents.ToolButton {
                text: i18n("Open Protect")
                icon.name: "globe"
                font: Kirigami.Theme.smallFont
                enabled: root.host !== ""
                onClicked: root.openURL(P.webURL(root.host))
            }
        }
    }

    // MARK: - Nothing yet: an error or the first load (StatusMessage)

    ColumnLayout {
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 2
        visible: popup.blank
        spacing: Kirigami.Units.largeSpacing

        PlasmaExtras.PlaceholderMessage {
            Layout.fillWidth: true
            iconName: popup.errorInfo ? popup.errorInfo.icon : "view-refresh"
            text: popup.errorInfo ? popup.errorInfo.title
                : i18n("Connecting to %1…", P.hostName(root.host || root.configuredHost) || i18n("the console"))
            // The certificate panel below says it all for those.
            explanation: popup.errorInfo && !P.isCertificateProblem(root.error) ? popup.errorInfo.message : ""
        }
        CertificatePanel {
            Layout.fillWidth: true
            visible: P.isCertificateProblem(root.error)
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            visible: root.error !== null
            PlasmaComponents.Button {
                text: i18n("Settings…")
                icon.name: "configure"
                onClicked: Plasmoid.internalAction("configure").trigger()
            }
            PlasmaComponents.Button {
                visible: root.error !== null && root.error.kind !== "notConfigured"
                text: i18n("Try Again")
                icon.name: "view-refresh"
                onClicked: root.refresh(true)
            }
        }
    }

    // MARK: - Content

    ColumnLayout {
        anchors.fill: parent
        visible: !popup.blank
        spacing: 0

        // An error with cameras already showing (they may be out of date).
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            visible: popup.errorInfo !== null && root.focusedCamera === ""
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: "dialog-warning"
                color: Kirigami.Theme.neutralTextColor
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.alignment: Qt.AlignTop
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                opacity: 0.8
                text: popup.errorInfo ? popup.errorInfo.title + ". " + popup.errorInfo.message : ""
            }
        }
        CertificatePanel {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            visible: P.isCertificateProblem(root.error) && root.focusedCamera === ""
        }

        // One camera large.
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: root.focusedCamera !== ""
            visible: active
            sourceComponent: popup.focused ? detailComponent : goneComponent
        }

        // The grid.
        PlasmaComponents.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.focusedCamera === "" && popup.tab === "cameras"
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            // A plain Grid with an explicit column count: GridView fits columns to its width itself,
            // and in some popup sizes and scales it fit one fewer than the cells were sized for.
            Flickable {
                id: gridFlick
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                contentWidth: width
                contentHeight: tiles.implicitHeight + Kirigami.Units.smallSpacing * 2

                Grid {
                    id: tiles
                    x: Kirigami.Units.smallSpacing
                    y: Kirigami.Units.smallSpacing
                    width: gridFlick.width - Kirigami.Units.smallSpacing * 2
                    columns: gridFlick.width > Kirigami.Units.gridUnit * 40 ? 3 : 2
                    spacing: Kirigami.Units.smallSpacing * 2
                    readonly property real cell: Math.floor((width - spacing * (columns - 1)) / columns)

                    Repeater {
                        model: root.cameras
                        delegate: CameraTile {
                            required property var modelData
                            width: tiles.cell
                            height: Math.round(width * 9 / 16)
                            camera: modelData
                            tick: popup.gridTick
                            active: popup.gridShown
                            onClicked: root.focusedCamera = modelData.id
                        }
                    }
                }
            }
        }

        // The event log.
        PlasmaComponents.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.focusedCamera === "" && popup.tab === "events"

            ListView {
                id: eventList
                model: EventListModel { events: root.visibleEvents }
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                delegate: EventRow {
                    required property string json
                    width: ListView.view.width
                    event: JSON.parse(json)
                    onClicked: if (event.cameraID) root.focusedCamera = event.cameraID
                }

                PlasmaExtras.PlaceholderMessage {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 4
                    visible: eventList.count === 0
                    iconName: "view-calendar-list"
                    text: i18n("No events yet")
                    explanation: i18n("Detections, doorbell rings and alarms show up here as Protect reports them while the widget is running.")
                }
            }
        }
    }

    Component {
        id: detailComponent
        CameraDetail {
            camera: popup.focused
            active: root.feedsActive
        }
    }

    Component {
        id: goneComponent
        Item {
            PlasmaExtras.PlaceholderMessage {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                iconName: "camera-off"
                text: i18n("That camera isn't on this console anymore.")
            }
        }
    }
}
