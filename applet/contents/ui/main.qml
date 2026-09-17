/*
    SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
    SPDX-License-Identifier: GPL-2.0-or-later

    A panel button that fires the Toggle Canvas chord: step out to the
    overworld, or back into the location under the screen centre. The chord
    is invoked by name through kglobalaccel, so a rebinding in System
    Settings is followed.
*/

import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    preferredRepresentation: compactRepresentation
    Plasmoid.status: PlasmaCore.Types.ActiveStatus

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => disconnectSource(sourceName)
        function run(cmd) { connectSource(cmd) }
    }

    function toggle() {
        executable.run("qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut 'Toggle Canvas'")
    }

    compactRepresentation: PlasmaComponents3.ToolButton {
        icon.name: "view-grid"
        display: PlasmaComponents3.AbstractButton.IconOnly
        text: i18n("Canvas")
        PlasmaComponents3.ToolTip.text: i18n("Canvas: step out or back in")
        PlasmaComponents3.ToolTip.visible: hovered
        PlasmaComponents3.ToolTip.delay: Qt.styleHints.mousePressAndHoldInterval
        onClicked: root.toggle()
    }

    fullRepresentation: compactRepresentation
}
