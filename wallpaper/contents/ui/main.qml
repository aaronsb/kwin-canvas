/*
    SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/
/*
    Canvas ground wallpaper. Draws the same Ground as the effect, at zoom 1,
    offset by the canvas origin the effect last published.
*/
import QtQuick
import QtQuick.Window
import org.kde.plasma.plasmoid

WallpaperItem {
    id: root

    Ground {
        anchors.fill: parent
        zoom: 1.0
        originX: -root.configuration.OffsetX - Screen.virtualX
        originY: -root.configuration.OffsetY - Screen.virtualY
        baseSpacing: root.configuration.GridBase
        octaveFactor: root.configuration.GridOctaveFactor
        octaves: root.configuration.GridOctaves
        background: root.configuration.Background
        lineColor: root.configuration.LineColor
        tileImage: root.configuration.TileImage
        showLabels: root.configuration.ShowLabels
    }
}
