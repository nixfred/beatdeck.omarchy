import QtQuick
import qs.Commons

Item {
  id: root

  property var spectrum: null
  property color accent: Color.accent
  property color foreground: Color.foreground
  property real reveal: 1
  property bool playing: false
  property real beatFlash: 0

  function clamp(value) {
    return Math.max(0, Math.min(1, Number(value) || 0))
  }

  function mixColor(from, to, amount) {
    var t = clamp(amount)
    return Qt.rgba(
      from.r + (to.r - from.r) * t,
      from.g + (to.g - from.g) * t,
      from.b + (to.b - from.b) * t,
      from.a + (to.a - from.a) * t)
  }

  function repaint() { canvas.requestPaint() }

  onAccentChanged: repaint()
  onForegroundChanged: repaint()
  onRevealChanged: repaint()
  onPlayingChanged: repaint()

  Connections {
    target: root.spectrum
    ignoreUnknownSignals: true
    function onBandsChanged() { root.repaint() }
    function onBeat(strength) {
      root.beatFlash = Math.max(root.beatFlash, Number(strength) || 0)
      beatDecay.restart()
    }
  }

  NumberAnimation {
    id: beatDecay
    target: root
    property: "beatFlash"
    to: 0
    duration: 420
    easing.type: Easing.OutCubic
    onFinished: root.repaint()
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    opacity: root.reveal

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var context = getContext("2d")
      context.reset()
      context.clearRect(0, 0, width, height)

      var source = root.spectrum && Array.isArray(root.spectrum.bands)
        ? root.spectrum.bands : []
      var count = source.length > 0 ? source.length : 24
      var gap = Math.max(2, Math.floor(width / count * 0.24))
      var barWidth = Math.max(2, (width - gap * (count - 1)) / count)
      var center = height / 2
      var maximum = Math.max(2, center - 2)
      var time = Date.now() / 1000

      context.fillStyle = String(Qt.rgba(root.foreground.r, root.foreground.g,
        root.foreground.b, 0.12 * root.reveal))
      context.fillRect(0, Math.floor(center), width, 1)

      for (var i = 0; i < count; i++) {
        var raw = source.length > 0 ? Number(source[i] || 0) : 0
        var idle = root.playing ? 0.12 + 0.07 * Math.sin(time * 3 + i * 0.72) : 0.025
        var value = root.clamp(Math.max(raw, idle) + root.beatFlash * 0.09)
        var distance = Math.abs(i - (count - 1) / 2) / Math.max(1, (count - 1) / 2)
        var color = root.mixColor(root.accent, root.foreground,
          Math.pow(distance, 0.7) * 0.72)
        var half = Math.max(1, value * maximum)
        var x = i * (barWidth + gap)
        context.fillStyle = String(Qt.rgba(color.r, color.g, color.b,
          (0.55 + value * 0.45) * root.reveal))
        context.fillRect(x, center - half, barWidth, half * 2)
      }
    }
  }

  Timer {
    interval: 80
    running: root.visible && root.playing
    repeat: true
    onTriggered: root.repaint()
  }
}
