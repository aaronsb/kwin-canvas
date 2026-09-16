import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kquickcontrols as KQuickControls
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: root
    twinFormLayouts: parentLayout

    property alias cfg_Background: backgroundButton.color
    property alias cfg_LineColor: lineButton.color
    property alias cfg_GridBase: gridBase.value
    property alias cfg_TileImage: tileImage.text
    property alias cfg_ShowLabels: showLabels.checked
    property alias formLayout: root

    KQuickControls.ColorButton {
        id: backgroundButton
        Kirigami.FormData.label: "Background:"
    }
    KQuickControls.ColorButton {
        id: lineButton
        Kirigami.FormData.label: "Grid lines:"
    }
    QQC2.SpinBox {
        id: gridBase
        Kirigami.FormData.label: "Minor grid spacing:"
        from: 8
        to: 1024
    }
    QQC2.TextField {
        id: tileImage
        Kirigami.FormData.label: "Tile image (optional):"
        placeholderText: "file:///path/to/tile.png"
    }
    QQC2.CheckBox {
        id: showLabels
        Kirigami.FormData.label: "Coordinate labels:"
    }
}
