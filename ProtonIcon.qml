import QtQuick
import QtQuick.Shapes
import qs.Commons

// Proton's mark is a shield, so the widget draws one natively rather than
// shipping an SVG: the bar slot is tiny, and a Shape stays crisp and takes the
// theme color directly. Filled reads as "protected", outline as "exposed".
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool filled: false
  property bool slashed: false
  property real strokeWidth: Math.max(1, iconSize * 0.11)

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real w: width
  readonly property real h: height

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.filled ? root.color : "transparent"
      strokeColor: root.filled ? "transparent" : root.color
      strokeWidth: root.filled ? 0 : root.strokeWidth
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap

      startX: root.w * 0.5;  startY: root.h * 0.07
      PathLine { x: root.w * 0.89; y: root.h * 0.22 }
      PathLine { x: root.w * 0.89; y: root.h * 0.50 }
      PathCubic {
        x: root.w * 0.5;  y: root.h * 0.95
        control1X: root.w * 0.89; control1Y: root.h * 0.76
        control2X: root.w * 0.71; control2Y: root.h * 0.88
      }
      PathCubic {
        x: root.w * 0.11; y: root.h * 0.50
        control1X: root.w * 0.29; control1Y: root.h * 0.88
        control2X: root.w * 0.11; control2Y: root.h * 0.76
      }
      PathLine { x: root.w * 0.11; y: root.h * 0.22 }
      PathLine { x: root.w * 0.5;  y: root.h * 0.07 }
    }
  }

  // Cut the slash out of the shield with a background-colored underlay so the
  // stroke reads on both filled and outline shields.
  Rectangle {
    visible: root.slashed
    anchors.centerIn: parent
    width: parent.width * 1.25
    height: Math.max(1, root.strokeWidth)
    radius: height / 2
    color: root.color
    rotation: -45
  }
}
