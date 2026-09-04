import QtQuick
import qs.Commons

Item {
  id: root

  property string icon: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool primary: false
  property bool controlEnabled: true
  property real reveal: 1
  signal clicked()

  readonly property int controlSize: primary ? Style.space(54) : Style.space(40)
  readonly property bool hot: hover.hovered
  readonly property bool down: tap.pressed

  implicitWidth: controlSize
  implicitHeight: controlSize
  opacity: controlEnabled ? reveal : reveal * 0.32
  scale: down ? 0.88 : (hot ? 1.07 : 1)

  Behavior on scale {
    SpringAnimation { spring: 4.2; damping: 0.42 }
  }

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: root.primary
      ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
          root.down ? 0.22 : (root.hot ? 0.15 : 0.08))
    border.width: root.primary ? 0 : Style.space(1)
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
      root.hot ? 0.34 : 0.16)

    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }
  }

  Rectangle {
    visible: root.primary
    anchors.fill: parent
    anchors.margins: -Style.space(5)
    radius: width / 2
    color: "transparent"
    border.width: Style.space(1)
    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b,
      root.hot ? 0.62 : 0.26)
    scale: root.hot ? 1.08 : 0.94
    opacity: root.reveal
    Behavior on scale { SpringAnimation { spring: 3.4; damping: 0.38 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }
  }

  Text {
    anchors.centerIn: parent
    text: root.icon
    textFormat: Text.PlainText
    color: root.primary ? Color.background : root.foreground
    font.family: Style.font.family
    font.pixelSize: root.primary ? Style.font.display : Style.font.iconLarge
  }

  HoverHandler { id: hover }

  TapHandler {
    id: tap
    enabled: root.controlEnabled
    acceptedButtons: Qt.LeftButton
    onTapped: root.clicked()
  }
}
