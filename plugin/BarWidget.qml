import QtQuick
import qs.Ui

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
        iconComponent: Item {
            Canvas {
                anchors.fill: parent
                property color ink: button.foreground
                onInkChanged: requestPaint()
                onPaint: {
                    var c=getContext("2d");c.reset();c.scale(width/24,height/24)
                    c.strokeStyle=ink;c.lineWidth=1.6;c.lineJoin="round";c.lineCap="round"
                    c.beginPath();c.moveTo(5,2);c.lineTo(20,2);c.lineTo(20,21);c.lineTo(5,21)
                    c.quadraticCurveTo(2,21,2,18);c.lineTo(2,5);c.quadraticCurveTo(2,2,5,2);c.stroke()
                    c.beginPath();c.moveTo(5,2);c.lineTo(5,17);c.lineTo(20,17);c.moveTo(5,17);c.quadraticCurveTo(2,17,2,19);c.stroke()
                }
            }
            Text {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: parent.width*0.03
                anchors.verticalCenterOffset: -parent.height*0.09
                text: "\ue900"
                font.family: "omarchy"
                font.pixelSize: parent.height*0.45
                color: button.foreground
            }
        }
    }
}
