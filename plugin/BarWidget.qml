import QtQuick
import qs.Ui
import "components"

BarWidget {
    id: root
    moduleName: "io.github.atomashevic.omabib"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        tooltipText: "Omabib · bibliography search"
        onPressed: if(root.bar && root.bar.shell)root.bar.shell.toggle("io.github.atomashevic.omabib", "{}")
        iconComponent: OmabibMark { color: button.foreground }
    }
}
