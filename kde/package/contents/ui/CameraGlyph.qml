import QtQuick
import QtQuick.Shapes

// A wall-mounted bullet camera on a 24×24 grid, the lens knocked out of the housing (CameraGlyph
// in Logo.swift). Not the UniFi Protect logo: that belongs to Ubiquiti.
Item {
    id: glyph

    property color color: "black"

    implicitWidth: 16
    implicitHeight: 16
    // Overlapping parts would show through each other at partial opacity.
    layer.enabled: opacity < 1
    layer.smooth: true

    function rounded(x, y, w, h, r) {
        return "M" + (x + r) + "," + y + " H" + (x + w - r) + " A" + r + "," + r + " 0 0 1 " + (x + w) + "," + (y + r)
            + " V" + (y + h - r) + " A" + r + "," + r + " 0 0 1 " + (x + w - r) + "," + (y + h)
            + " H" + (x + r) + " A" + r + "," + r + " 0 0 1 " + x + "," + (y + h - r)
            + " V" + (y + r) + " A" + r + "," + r + " 0 0 1 " + (x + r) + "," + y + " Z"
    }
    function circle(cx, cy, r) {
        return "M" + (cx - r) + "," + cy + " A" + r + "," + r + " 0 1 0 " + (cx + r) + "," + cy
            + " A" + r + "," + r + " 0 1 0 " + (cx - r) + "," + cy + " Z"
    }

    Item {
        width: 24
        height: 24
        anchors.centerIn: parent
        scale: Math.min(glyph.width, glyph.height) / 24

        // Mount arm and wall plate.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillColor: glyph.color
                PathSvg { path: "M7.6,11.8 h2.6 v7 h-2.6 Z" }
            }
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillColor: glyph.color
                PathSvg { path: "M3.4,16.2 h6.8 v2.6 h-6.8 Z" }
            }
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillColor: glyph.color
                PathSvg { path: glyph.rounded(1.5, 13.3, 3, 8.2, 1) }
            }
        }

        // Housing and sun shield, tilted down toward what it watches.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            transform: Rotation { origin.x: 12.5; origin.y: 9.5; angle: 18.33 }
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillColor: glyph.color
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: glyph.rounded(4, 5.5, 17, 8, 2.6) + " " + glyph.circle(18.3, 10, 1.7) }
            }
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillColor: glyph.color
                PathSvg { path: glyph.rounded(6, 3.9, 17, 2.6, 1.3) }
            }
        }
    }
}
