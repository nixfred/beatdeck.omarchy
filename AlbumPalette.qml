import QtQuick
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property string sourceUrl: ""
  property color fallback: Color.accent
  property color sampled: fallback
  readonly property color accent: mixColor(fallback, sampled, 0.72)

  function clamp(value) {
    return Math.max(0, Math.min(1, Number(value) || 0))
  }

  function mixColor(from, to, amount) {
    var t = clamp(amount)
    return Qt.rgba(
      from.r + (to.r - from.r) * t,
      from.g + (to.g - from.g) * t,
      from.b + (to.b - from.b) * t,
      1)
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") !== 0) return ""
    try {
      return decodeURIComponent(value.slice(7))
    } catch (error) {
      return value.slice(7)
    }
  }

  function refresh() {
    sampled = fallback
    var path = localPath(sourceUrl)
    if (!path) return
    sampler.command = [
      "magick", path + "[0]",
      "-resize", "1x1!",
      "-colorspace", "sRGB",
      "-format", "%[hex:p{0,0}]",
      "info:"
    ]
    sampler.running = true
  }

  onSourceUrlChanged: refresh()
  onFallbackChanged: if (!localPath(sourceUrl)) sampled = fallback
  Component.onCompleted: refresh()

  Process {
    id: sampler
    property string result: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: sampler.result = text.trim()
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var match = sampler.result.match(/^([0-9a-fA-F]{6})/)
      if (match) root.sampled = "#" + match[1]
    }
  }
}
