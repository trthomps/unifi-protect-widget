import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// A camera snapshot from the bridge that fills whatever space it's given (SnapshotImage in
// PopoverView.swift). A new frame loads behind the old one and replaces it once it's decoded, so
// refreshes don't flicker.
//
// `tick` drives grid refreshes: each change fetches a new frame. With `live`, frames load back to
// back about once a second instead (slower after a failure, rather than hammer the console).
Rectangle {
    id: snap

    property string cameraID: ""
    property bool offline: false
    property bool highQuality: false
    property bool live: false
    property int tick: 0
    property bool active: true
    /// Limits decoding for small tiles.
    property int decodeWidth: 0
    property bool fill: true

    /// When the frame on screen was fetched (0 before the first).
    property real takenAt: 0
    readonly property real frameAspect: shown && shown.implicitHeight > 0 ? shown.implicitWidth / shown.implicitHeight : 16 / 9
    property bool failed: false
    property int serial: 0
    property Image shown: null
    property real requestedAt: 0

    color: Qt.rgba(0, 0, 0, 0.85)
    clip: true

    function load() {
        if (!cameraID || offline || !active) return
        const url = root.snapshotURL(cameraID, highQuality, ++serial)
        if (!url) return
        const back = shown === a ? b : a
        requestedAt = Date.now()
        back.source = url
    }

    function loaded(img) {
        if (img.status === Image.Ready) {
            if (img !== shown) {
                const old = shown
                shown = img
                if (old) old.source = ""
            }
            takenAt = requestedAt
            failed = false
            if (live) nextFrame.interval = Math.max(250, 1000 - (Date.now() - requestedAt))
        } else if (img.status === Image.Error) {
            failed = true
            img.source = ""
            if (live) nextFrame.interval = 3000
        } else {
            return
        }
        if (live && active) nextFrame.restart()
    }

    onTickChanged: if (!live) load()
    onActiveChanged: if (active) load(); else nextFrame.stop()
    onCameraIDChanged: { takenAt = 0; failed = false; if (a.source != "") a.source = ""; if (b.source != "") b.source = ""; shown = null; load() }
    onLiveChanged: load()
    Component.onCompleted: load()

    Timer {
        id: nextFrame
        onTriggered: snap.load()
    }

    Image {
        id: a
        anchors.fill: parent
        visible: snap.shown === a
        asynchronous: true
        cache: false
        fillMode: snap.fill ? Image.PreserveAspectCrop : Image.PreserveAspectFit
        sourceSize.width: snap.decodeWidth
        opacity: snap.offline ? 0.35 : 1
        onStatusChanged: snap.loaded(a)
    }
    Image {
        id: b
        anchors.fill: parent
        visible: snap.shown === b
        asynchronous: true
        cache: false
        fillMode: a.fillMode
        sourceSize.width: snap.decodeWidth
        opacity: a.opacity
        onStatusChanged: snap.loaded(b)
    }

    RowLayout {
        anchors.centerIn: parent
        visible: snap.offline || !snap.shown
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Icon {
            visible: snap.offline || snap.failed
            source: snap.offline ? "camera-off" : "dialog-warning"
            color: "white"
            isMask: true
            opacity: 0.8
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }
        PlasmaComponents.Label {
            visible: snap.offline || snap.failed
            text: snap.offline ? i18n("Offline") : i18n("No snapshot")
            color: "white"
            opacity: 0.8
            font: Kirigami.Theme.smallFont
        }
        PlasmaComponents.BusyIndicator {
            visible: !snap.offline && !snap.failed
            running: visible
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
        }
    }
}
