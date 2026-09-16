import QtQuick
import qs.Ui
import "components"

BarWidget {
    id: root
    moduleName: "omabib"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        tooltipText: "Omabib · bibliography search (Super+B)"
        onPressed: if(root.bar && root.bar.shell)root.bar.shell.toggle("omabib", "{}")
        iconComponent: OmabibMark { color: button.foreground }
    }
}
