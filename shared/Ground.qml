/*
    SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/
/*
    Ground plane: the canvas-space reference everything else sits on.

    originX/originY are the screen-local pixel position of canvas (0,0).
    zoom is the view scale (1.0 = one canvas pixel per screen pixel).
    Both the effect (any zoom) and the wallpaper (zoom 1) draw with this item,
    so the ground looks the same whether the effect is open or closed.
*/
import QtQuick

Item {
    id: ground

    property real originX: 0
    property real originY: 0
    property real zoom: 1.0

    property int baseSpacing: 64
    property int octaveFactor: 8
    property int octaves: 4
    property color background: "#1c1f26"
    property color lineColor: "#7f8fb0"
    property string tileImage: ""
    property bool showLabels: true

    // Screen spacing below which an octave is invisible, and above which it is fully drawn.
    readonly property real fadeIn: 14
    readonly property real fadeFull: 72

    function mod(a, b) { return ((a % b) + b) % b; }
    function fade(s) { return Math.max(0, Math.min(1, (s - fadeIn) / (fadeFull - fadeIn))); }

    Rectangle {
        anchors.fill: parent
        color: ground.background
    }

    // Optional raster ground: one image tiled across the canvas at 1:1, scaled with the view.
    Image {
        id: tile
        visible: ground.tileImage !== "" && status === Image.Ready
        source: ground.tileImage
        fillMode: Image.Tile
        smooth: true
        mipmap: true
        readonly property real sw: sourceSize.width * ground.zoom
        readonly property real sh: sourceSize.height * ground.zoom
        x: sw > 0 ? ground.mod(ground.originX, sw) - sw : 0
        y: sh > 0 ? ground.mod(ground.originY, sh) - sh : 0
        width: sw > 0 ? (ground.width + 2 * sw) / ground.zoom : 0
        height: sh > 0 ? (ground.height + 2 * sh) / ground.zoom : 0
        transform: Scale { xScale: ground.zoom; yScale: ground.zoom }
    }

    // Procedural ground: grid octaves that fade in as their screen spacing grows,
    // so there is always a legible spacing at any zoom.
    Repeater {
        model: ground.tileImage === "" ? ground.octaves : 0
        delegate: Item {
            id: octave
            required property int index
            anchors.fill: parent
            readonly property real canvasSpacing: ground.baseSpacing * Math.pow(ground.octaveFactor, index)
            readonly property real spacing: canvasSpacing * ground.zoom
            readonly property real weight: 0.10 + 0.22 * index
            readonly property real lineWidth: index >= 2 ? 2 : 1
            readonly property bool labelled: ground.showLabels && index >= 1 && spacing >= 260 && spacing <= Math.max(ground.width, ground.height) * 2
            opacity: ground.fade(spacing) * weight
            visible: opacity > 0.005

            Repeater {
                model: octave.visible ? Math.ceil(ground.width / octave.spacing) + 2 : 0
                delegate: Rectangle {
                    required property int index
                    x: ground.mod(ground.originX, octave.spacing) + (index - 1) * octave.spacing - octave.lineWidth / 2
                    y: 0
                    width: octave.lineWidth
                    height: ground.height
                    color: ground.lineColor
                }
            }
            Repeater {
                model: octave.visible ? Math.ceil(ground.height / octave.spacing) + 2 : 0
                delegate: Rectangle {
                    required property int index
                    x: 0
                    y: ground.mod(ground.originY, octave.spacing) + (index - 1) * octave.spacing - octave.lineWidth / 2
                    width: ground.width
                    height: octave.lineWidth
                    color: ground.lineColor
                }
            }

            // Coordinate labels at this octave's intersections: unique landmarks, like map tiles.
            Repeater {
                model: octave.labelled ? (Math.ceil(ground.width / octave.spacing) + 2) * (Math.ceil(ground.height / octave.spacing) + 2) : 0
                delegate: Text {
                    required property int index
                    readonly property int cols: Math.ceil(ground.width / octave.spacing) + 2
                    readonly property int ci: (index % cols) - 1
                    readonly property int ri: Math.floor(index / cols) - 1
                    readonly property real sx: ground.mod(ground.originX, octave.spacing) + ci * octave.spacing
                    readonly property real sy: ground.mod(ground.originY, octave.spacing) + ri * octave.spacing
                    readonly property int cx: Math.round((sx - ground.originX) / ground.zoom)
                    readonly property int cy: Math.round((sy - ground.originY) / ground.zoom)
                    x: sx + 6
                    y: sy + 4
                    text: cx + ", " + cy
                    color: ground.lineColor
                    font.pixelSize: 12
                    font.family: "monospace"
                }
            }
        }
    }

    // Canvas axes: the one landmark that never repeats.
    Rectangle {
        x: ground.originX - 1
        y: 0
        width: 2
        height: ground.height
        color: ground.lineColor
        opacity: 0.9
        visible: ground.tileImage === ""
    }
    Rectangle {
        x: 0
        y: ground.originY - 1
        width: ground.width
        height: 2
        color: ground.lineColor
        opacity: 0.9
        visible: ground.tileImage === ""
    }
}
