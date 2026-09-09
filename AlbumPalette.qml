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
  // Remote art is a request to a third party on every track change, so it is
  // gated by a setting and memoised: one fetch per URL per session.
  property bool remoteArt: true
  property var remoteCache: ({})

  // Fetched, not opened: curl is pinned to http and https on both the initial
  // request and any redirect, so a redirect cannot walk the fetch onto file://
  // or gopher://. Bounded in time and size so a hostile or broken host cannot
  // stall the deck or pull down something enormous.
  readonly property string remoteScript:
    "curl -fsSL --proto =http,https --proto-redir =http,https" +
    " --max-time 6 --max-filesize 8000000 -- \"$1\"" +
    " | magick - -resize 1x1! -colorspace sRGB -format '%[hex:p{0,0}]' info:"
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

  // Everything MPRIS hands us that we can actually sample. A player may give a
  // path, or it may inline the bytes; mpv and anything else with the cover
  // embedded in the file send a data: URI, and treating those as "no art" left
  // the deck untinted for them entirely.
  function refresh() {
    sampled = fallback
    sampler.payload = ""
    sampler.remoteUrl = ""
    var url = String(sourceUrl || "")

    if (url.indexOf("data:") === 0) {
      var comma = url.indexOf(",")
      // Only base64 payloads. A percent-encoded data: URI is legal but no
      // player emits one for cover art, and guessing at it would be worse
      // than leaving the tint alone.
      if (comma < 0 || url.lastIndexOf(";base64", comma) < 0) return
      sampler.payload = url.slice(comma + 1)
      // Over stdin, never argv: a cover can be megabytes of base64 and would
      // blow ARG_MAX. `magick -` reads the first frame from the pipe, which is
      // the same frame the [0] below selects.
      sampler.command = ["sh", "-c",
        "base64 -d | magick - -resize 1x1! -colorspace sRGB -format '%[hex:p{0,0}]' info:"]
      sampler.running = true
      return
    }

    if (url.indexOf("http://") === 0 || url.indexOf("https://") === 0) {
      if (!remoteArt) return
      var hit = remoteCache[url]
      if (hit) { sampled = hit; return }
      sampler.remoteUrl = url
      sampler.command = ["sh", "-c", remoteScript, "sh", url]
      sampler.running = true
      return
    }

    var path = localPath(url)
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
    // Set when the art arrived inline and has to be fed in rather than opened.
    property string payload: ""
    // Set when this run fetched a remote URL, so the result can be memoised.
    property string remoteUrl: ""

    stdinEnabled: sampler.payload !== ""
    onStarted: {
      if (payload === "") return
      write(payload)
      // Closing the write channel is what gives `base64 -d` its EOF. Without
      // it the pipeline waits for more input and the sample never lands.
      stdinEnabled = false
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: sampler.result = text.trim()
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var match = sampler.result.match(/^([0-9a-fA-F]{6})/)
      if (!match) return
      root.sampled = "#" + match[1]
      if (sampler.remoteUrl !== "") {
        // Bounded so a long shuffle cannot grow it without limit. Dropping the
        // whole map is fine: the cost of a miss is one fetch.
        if (Object.keys(root.remoteCache).length >= 24) root.remoteCache = ({})
        root.remoteCache[sampler.remoteUrl] = root.sampled
        sampler.remoteUrl = ""
      }
    }
  }
}
