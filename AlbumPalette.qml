import QtQuick
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property string sourceUrl: ""
  property color fallback: Color.accent
  property color sampled: fallback
  // Hues the active theme actually contains, from the widget. Empty means the
  // theme shipped no colors.toml, or the user turned theme colours off; either
  // way the artwork colour is then used raw, exactly as it was before.
  property var themeHues: []
  readonly property color accent: mixColor(fallback, snapHue(sampled), 0.72)

  // A lime album cover used to make the whole deck lime whatever the theme
  // was, because the tint is 72% artwork. Snapping the sampled hue to the
  // nearest hue the theme owns keeps the deck responding to the album while
  // landing on a colour that belongs here. Saturation and lightness are the
  // artwork's, so a muted cover still reads muted.
  // Pure, so it can be tested without a QML colour. -1 when there is nothing
  // to snap to. Hue is a circle, so 0.98 and 0.02 are neighbours, not opposites.
  function nearestHue(src, hues) {
    var best = -1, bestDistance = 2
    for (var i = 0; i < hues.length; i++) {
      var d = Math.abs(hues[i] - src)
      if (d > 0.5) d = 1 - d
      if (d < bestDistance) { bestDistance = d; best = hues[i] }
    }
    return best
  }

  function snapHue(c) {
    if (!themeHues || themeHues.length === 0) return c
    // A near-grey sample has no meaningful hue; snapping it would invent one.
    if (c.hslSaturation < 0.08) return c
    var h = nearestHue(c.hslHue, themeHues)
    if (h < 0) return c
    return Qt.hsla(h, c.hslSaturation, c.hslLightness, 1)
  }

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
