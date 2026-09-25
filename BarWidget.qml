import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "andean-bridge.db-browser"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "DB Studio"
    active: root.bar && root.bar.shell ? root.bar.shell.isPluginOpen(root.moduleName) : false
    iconComponent: Component {
      Canvas {
        id: databaseIcon
        property color ink: button.active && button.useActiveColor ? button.activeColor : button.foreground
        onInkChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          if (!width || !height) return
          var side = Math.min(width, height)
          ctx.save()
          ctx.translate((width - side) / 2, (height - side) / 2)
          ctx.scale(side / 20, side / 20)
          ctx.strokeStyle = databaseIcon.ink
          ctx.lineWidth = 1.7
          ctx.lineCap = "round"
          ctx.lineJoin = "round"
          ctx.beginPath()
          ctx.moveTo(2, 5)
          ctx.bezierCurveTo(2, 2, 18, 2, 18, 5)
          ctx.bezierCurveTo(18, 8, 2, 8, 2, 5)
          ctx.moveTo(2, 5)
          ctx.lineTo(2, 15)
          ctx.bezierCurveTo(2, 18, 18, 18, 18, 15)
          ctx.lineTo(18, 5)
          ctx.moveTo(2, 10)
          ctx.bezierCurveTo(2, 13, 18, 13, 18, 10)
          ctx.stroke()
          ctx.restore()
        }
      }
    }
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton && root.bar && root.bar.shell)
        root.bar.shell.toggle(root.moduleName, "{}")
    }
  }
}
