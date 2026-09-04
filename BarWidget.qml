import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "nixfred.beatdeck"

  readonly property var mediaService: bar && bar.shell
    ? bar.shell.serviceFor("pi.media") : null
  readonly property var spectrum: bar && bar.shell
    ? bar.shell.serviceFor("ryrobes.beatbar") : null
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null

  readonly property bool hasMedia: activePlayer !== null
    && (activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property bool playing: activePlayer ? activePlayer.isPlaying : false
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer ? (activePlayer.trackAlbum || "") : ""
  readonly property string artUrl: activePlayer ? (activePlayer.trackArtUrl || "") : ""
  readonly property string playIcon: playing ? "󰏤" : "󰐊"
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color cockpitAccent: Qt.lighter(palette.accent, 1.22)
  readonly property real bass: spectrum ? Number(spectrum.bass || 0) : 0

  property bool popupOpen: false
  property real intro: 0
  property real trackPosition: 0
  property real beatPulse: 0
  property real maxLabelWidth: 196

  readonly property real trackLength: activePlayer && activePlayer.lengthSupported
    ? Math.max(0, Number(activePlayer.length) || 0) : 0
  readonly property real progress: trackLength > 0
    ? Math.max(0, Math.min(1, trackPosition / trackLength)) : 0
  readonly property real artReveal: Math.max(0, Math.min(1, intro / 0.42))
  readonly property real copyReveal: Math.max(0, Math.min(1, (intro - 0.2) / 0.48))
  readonly property real controlReveal: Math.max(0, Math.min(1, (intro - 0.46) / 0.54))

  function close() { popupOpen = false }

  function formatTime(seconds) {
    var value = Math.max(0, Math.floor(Number(seconds) || 0))
    var minutes = Math.floor(value / 60)
    var remainder = value % 60
    return minutes + ":" + (remainder < 10 ? "0" : "") + remainder
  }

  function refreshPosition() {
    if (!activePlayer || !activePlayer.positionSupported) {
      trackPosition = 0
      return
    }
    activePlayer.positionChanged()
    var raw = Math.max(0, Number(activePlayer.position) || 0)
    trackPosition = trackLength > 0 ? Math.min(trackLength, raw) : raw
  }

  function action(name) {
    if (!mediaService || !activePlayer) return
    mediaService.runAction(name, false, mediaService.playerKey(activePlayer))
  }

  function seek(ratio) {
    if (!activePlayer || !activePlayer.canSeek || !activePlayer.positionSupported
        || trackLength <= 0) return
    var next = Math.max(0, Math.min(1, ratio)) * trackLength
    activePlayer.position = next
    trackPosition = next
  }

  onPopupOpenChanged: {
    if (popupOpen) {
      intro = 0
      introAnimation.restart()
      refreshPosition()
    } else {
      introAnimation.stop()
      intro = 0
    }
  }
  onActivePlayerChanged: refreshPosition()
  onTitleChanged: refreshPosition()

  visible: true
  implicitWidth: vertical ? barSize : Style.spaceReal(configuredWidth)
  implicitHeight: vertical ? Style.spaceReal(configuredWidth) : barSize

  AlbumPalette {
    id: palette
    sourceUrl: root.artUrl
    fallback: Color.accent
  }

  NumberAnimation {
    id: introAnimation
    target: root
    property: "intro"
    from: 0
    to: 1
    duration: 560
    easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: beatDecay
    target: root
    property: "beatPulse"
    to: 0
    duration: 460
    easing.type: Easing.OutCubic
  }

  Connections {
    target: root.spectrum
    ignoreUnknownSignals: true
    function onBeat(strength) {
      root.beatPulse = Math.max(root.beatPulse, Number(strength) || 0)
      beatDecay.restart()
    }
  }

  Timer {
    interval: 500
    running: root.popupOpen && root.activePlayer !== null
      && root.activePlayer.positionSupported
    repeat: true
    onTriggered: root.refreshPosition()
  }

  Timer {
    interval: 16
    running: root.popupOpen && root.playing
    repeat: true
    onTriggered: record.rotation = (record.rotation + 0.36) % 360
  }

  // ---------------------------------------------------------------- EQ deck
  // Spectrum visuals lifted from ryrobes.beatbar (MIT, Ryan Robitaille).
  // Left click opens the media cockpit; right click cycles the visualization.

  readonly property int configuredWidth: Math.max(72, Math.min(220,
    Number(setting("width", 112)) || 112))
  readonly property int configuredGain: Math.max(40, Math.min(250,
    Number(setting("gain", 100)) || 100))
  readonly property real visualGain: configuredGain / 100
  readonly property bool auroraPulse: setting("auroraPulse", true) === true
  readonly property bool showIdleLine: setting("showIdleLine", true) === true
  readonly property bool showLabel: setting("showLabel", true) === true
  readonly property string mode: {
    var value = String(setting("mode", "Aurora"))
    return ["Garden", "Mirror", "Aurora"].indexOf(value) >= 0 ? value : "Aurora"
  }
  readonly property string bassMotion: {
    var value = String(setting("bassMotion", "Subtle"))
    return ["Off", "Subtle", "Loose"].indexOf(value) >= 0 ? value : "Subtle"
  }

  readonly property color themeForeground: bar ? bar.barForeground : Color.foreground
  readonly property color themeAccent: Color.accent
  readonly property color themeMuted: Color.muted
  readonly property color themeUrgent: Color.urgent

  property real beatGlow: 0
  property real kickEnergy: 0
  property real shakePhase: 0
  property real pulsePosition: 1
  property real pulseEnergy: 0

  readonly property real bassMotionScale: bassMotion === "Loose" ? 2.4
    : bassMotion === "Subtle" ? 1.15 : 0
  readonly property real shakeX: Math.sin(shakePhase) * kickEnergy * bassMotionScale
  readonly property real shakeY: Math.sin(shakePhase * 1.7 + 0.5)
    * kickEnergy * bassMotionScale * 0.42
  readonly property real kickScale: 1 + kickEnergy * bassMotionScale * 0.006

  function clamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value))
  }

  function mixColor(from, to, amount) {
    var t = clamp(amount, 0, 1)
    return Qt.rgba(
      from.r + (to.r - from.r) * t,
      from.g + (to.g - from.g) * t,
      from.b + (to.b - from.b) * t,
      from.a + (to.a - from.a) * t)
  }

  function withAlpha(color, alpha) {
    return Qt.rgba(color.r, color.g, color.b, clamp(alpha, 0, 1))
  }

  function scaledBands() {
    var source = spectrum && Array.isArray(spectrum.bands) ? spectrum.bands : []
    var values = []
    for (var i = 0; i < source.length; i++)
      values.push(clamp(Number(source[i] || 0) * visualGain, 0, 1))
    return values
  }

  // Tint the spectrum with the album art palette when something is playing,
  // otherwise fall back to the plain theme accent.
  readonly property color spectrumAccent: hasMedia
    ? mixColor(themeAccent, cockpitAccent, 0.75) : themeAccent

  function frequencyColor(index, count, value) {
    var center = (count - 1) / 2
    var distance = count > 1 ? Math.abs(index - center) / center : 0
    var base = mixColor(spectrumAccent, themeForeground, Math.pow(distance, 0.72))
    base = mixColor(themeMuted, base, 0.42 + value * 0.58)
    var heat = clamp((value - 0.68) / 0.32 + beatGlow * 0.45, 0, 1)
    return mixColor(base, themeUrgent, heat)
  }

  function persist(values) {
    var entry = { id: moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    for (var key in values) entry[key] = values[key]
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function cycleMode() {
    var modes = ["Garden", "Mirror", "Aurora"]
    persist({ mode: modes[(modes.indexOf(mode) + 1) % modes.length] })
  }

  function adjustGain(direction) {
    var next = clamp(configuredGain + direction * 10, 40, 250)
    if (next !== configuredGain) persist({ gain: next })
  }

  function paintIdle(context, width, height) {
    if (!showIdleLine) return
    context.fillStyle = String(withAlpha(themeMuted, 0.34))
    context.fillRect(0, Math.floor(height / 2), width, 1)
  }

  function paintGarden(context, values, width, height) {
    var count = values.length
    if (count === 0) {
      paintIdle(context, width, height)
      return
    }
    var gap = Math.max(1, Math.floor(width / count * 0.24))
    var barWidth = Math.max(1, (width - gap * (count - 1)) / count)
    var floorY = height - 2
    var maximum = Math.max(1, height - 5)
    var alive = false

    for (var i = 0; i < count; i++) {
      var value = values[i]
      if (value > 0.012) alive = true
      var barHeight = Math.max(value > 0 ? 1 : 0, value * maximum)
      var x = i * (barWidth + gap)
      context.fillStyle = String(frequencyColor(i, count, value))
      context.fillRect(x, floorY - barHeight, barWidth, barHeight)
    }
    if (!alive) paintIdle(context, width, height)
  }

  function paintMirror(context, values, width, height) {
    var count = values.length
    if (count === 0) {
      paintIdle(context, width, height)
      return
    }
    var gap = Math.max(1, Math.floor(width / count * 0.22))
    var barWidth = Math.max(1, (width - gap * (count - 1)) / count)
    var centerY = height / 2
    var maximum = Math.max(1, height / 2 - 2)
    var alive = false

    context.fillStyle = String(withAlpha(themeMuted, 0.22))
    context.fillRect(0, Math.floor(centerY), width, 1)
    for (var i = 0; i < count; i++) {
      var value = values[i]
      if (value > 0.012) alive = true
      var halfHeight = Math.max(value > 0 ? 0.5 : 0, value * maximum)
      var x = i * (barWidth + gap)
      context.fillStyle = String(frequencyColor(i, count, value))
      context.fillRect(x, centerY - halfHeight, barWidth, halfHeight * 2)
    }
    if (!alive && !showIdleLine) context.clearRect(0, 0, width, height)
  }

  function paintAurora(context, values, width, height) {
    var count = values.length
    if (count < 2) {
      paintIdle(context, width, height)
      return
    }
    var maximum = Math.max(1, height - 5)
    var floorY = height - 2
    var alive = false
    var gradient = context.createLinearGradient(0, 0, width, 0)
    gradient.addColorStop(0, String(withAlpha(themeMuted, 0.32)))
    gradient.addColorStop(0.5, String(withAlpha(mixColor(spectrumAccent, themeUrgent, beatGlow * 0.5), 0.78)))
    gradient.addColorStop(1, String(withAlpha(themeForeground, 0.36)))

    context.beginPath()
    context.moveTo(0, floorY)
    for (var i = 0; i < count; i++) {
      var value = values[i]
      if (value > 0.012) alive = true
      var x = i * width / (count - 1)
      var y = floorY - value * maximum
      context.lineTo(x, y)
    }
    context.lineTo(width, floorY)
    context.closePath()
    context.fillStyle = gradient
    context.fill()

    if (auroraPulse && pulseEnergy > 0.001) {
      var position = clamp(pulsePosition, 0, 1)
      var radius = 0.11
      var leadingEdge = Math.max(0, position - radius)
      var trailingEdge = Math.min(1, position + radius)
      var transparent = String(withAlpha(spectrumAccent, 0))
      var pulseColor = mixColor(themeForeground, themeUrgent,
        0.12 + pulseEnergy * 0.38)
      var pulseGradient = context.createLinearGradient(0, 0, width, 0)

      pulseGradient.addColorStop(0, transparent)
      if (leadingEdge > 0) pulseGradient.addColorStop(leadingEdge, transparent)
      pulseGradient.addColorStop(position,
        String(withAlpha(pulseColor, 0.22 + pulseEnergy * 0.7)))
      if (trailingEdge < 1) pulseGradient.addColorStop(trailingEdge, transparent)
      pulseGradient.addColorStop(1, transparent)

      context.save()
      context.clip()
      context.fillStyle = pulseGradient
      context.fillRect(0, 0, width, height)
      context.restore()
    }

    context.beginPath()
    for (var j = 0; j < count; j++) {
      var px = j * width / (count - 1)
      var py = floorY - values[j] * maximum
      if (j === 0) context.moveTo(px, py)
      else context.lineTo(px, py)
    }
    context.strokeStyle = String(mixColor(spectrumAccent, themeUrgent, beatGlow * 0.65))
    context.lineWidth = 1
    context.stroke()

    if (!alive) {
      context.clearRect(0, 0, width, height)
      paintIdle(context, width, height)
    }
  }

  function paintSpectrum(context, width, height) {
    var values = scaledBands()
    if (mode === "Mirror") paintMirror(context, values, width, height)
    else if (mode === "Aurora") paintAurora(context, values, width, height)
    else paintGarden(context, values, width, height)
  }

  onModeChanged: {
    if (mode !== "Aurora") {
      pulseTravel.stop()
      pulseDecay.stop()
      pulseEnergy = 0
    }
    visualization.requestPaint()
  }
  onAuroraPulseChanged: {
    if (!auroraPulse) {
      pulseTravel.stop()
      pulseDecay.stop()
      pulseEnergy = 0
    }
    visualization.requestPaint()
  }
  onBassMotionChanged: {
    if (bassMotion === "Off") {
      kickPhase.stop()
      kickDecay.stop()
      kickEnergy = 0
      shakePhase = 0
    }
    visualization.requestPaint()
  }
  onVisualGainChanged: visualization.requestPaint()
  onShowIdleLineChanged: visualization.requestPaint()
  onThemeForegroundChanged: visualization.requestPaint()
  onSpectrumAccentChanged: visualization.requestPaint()
  onThemeMutedChanged: visualization.requestPaint()
  onThemeUrgentChanged: visualization.requestPaint()
  onBeatGlowChanged: visualization.requestPaint()
  onShakePhaseChanged: visualization.requestPaint()
  onKickEnergyChanged: visualization.requestPaint()
  onPulsePositionChanged: visualization.requestPaint()
  onPulseEnergyChanged: visualization.requestPaint()

  Connections {
    target: root.spectrum
    ignoreUnknownSignals: true

    function onBandsChanged() { visualization.requestPaint() }

    function onBeat(strength) {
      root.beatGlow = Math.max(root.beatGlow, Number(strength) || 0)
      eqGlowDecay.from = root.beatGlow
      eqGlowDecay.restart()

      if (root.mode === "Aurora" && root.auroraPulse) {
        pulseDecay.stop()
        root.pulseEnergy = Math.max(root.pulseEnergy,
          root.clamp((Number(strength) || 0) * 1.15, 0, 1))
        if (!pulseTravel.running) {
          root.pulsePosition = 0
          pulseTravel.restart()
        }
        pulseDecay.from = root.pulseEnergy
        pulseDecay.restart()
      }

      if (root.bassMotion !== "Off") {
        kickPhase.stop()
        kickDecay.stop()
        root.kickEnergy = Math.max(root.kickEnergy, Number(strength) || 0)
        root.shakePhase = 0
        kickPhase.restart()
        kickDecay.from = root.kickEnergy
        kickDecay.restart()
      }
      visualization.requestPaint()
    }
  }

  NumberAnimation {
    id: eqGlowDecay
    target: root
    property: "beatGlow"
    to: 0
    duration: 180
    easing.type: Easing.OutCubic
    onRunningChanged: visualization.requestPaint()
  }

  NumberAnimation {
    id: kickPhase
    target: root
    property: "shakePhase"
    from: 0
    to: Math.PI * 6
    duration: 180
    easing.type: Easing.OutQuad
  }

  NumberAnimation {
    id: kickDecay
    target: root
    property: "kickEnergy"
    to: 0
    duration: 200
    easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: pulseTravel
    target: root
    property: "pulsePosition"
    from: 0
    to: 1
    duration: 520
    easing.type: Easing.InOutQuad
  }

  NumberAnimation {
    id: pulseDecay
    target: root
    property: "pulseEnergy"
    to: 0
    duration: 560
    easing.type: Easing.OutQuad
  }

  Canvas {
    id: visualization
    anchors.fill: parent
    antialiasing: true

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var context = getContext("2d")
      context.clearRect(0, 0, width, height)
      if (width <= 0 || height <= 0) return

      context.save()
      context.translate(root.shakeX, root.shakeY)
      context.translate(width / 2, height / 2)
      context.scale(root.kickScale, root.kickScale)
      context.translate(-width / 2, -height / 2)

      if (root.vertical) {
        context.translate(width, 0)
        context.rotate(Math.PI / 2)
        root.paintSpectrum(context, height, width)
      } else {
        root.paintSpectrum(context, width, height)
      }
      context.restore()
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) {
        // Left click is the cockpit. With nothing playing there is nothing to
        // show, so fall back to cycling the visuals rather than doing nothing.
        if (root.activePlayer) root.popupOpen = !root.popupOpen
        else root.cycleMode()
      } else if (mouse.button === Qt.RightButton) {
        root.cycleMode()
      } else if (mouse.button === Qt.MiddleButton) {
        root.action("playPause")
      }
    }

    onWheel: function(wheel) {
      // Plain wheel rides the visual gain (the old Beatbar behaviour);
      // Shift + wheel skips tracks.
      if (wheel.modifiers & Qt.ShiftModifier) {
        if (wheel.angleDelta.y > 0) root.action("previous")
        else if (wheel.angleDelta.y < 0) root.action("next")
      } else {
        root.adjustGain(wheel.angleDelta.y >= 0 ? 1 : -1)
      }
      wheel.accepted = true
    }

    onEntered: if (root.bar) root.bar.showTooltip(root,
      (root.hasMedia
        ? root.title + (root.artist ? " — " + root.artist : "")
        : "Nothing playing")
      + "\nLeft: cockpit  ·  Right: " + root.mode + " visuals"
      + "\nMiddle: play/pause  ·  Wheel: gain " + root.configuredGain
      + "%  ·  Shift+wheel: tracks")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    padding: 0
    borderSpec: Border.none()
    contentWidth: popup.fittedContentWidth(Style.space(520))
    contentHeight: popup.cappedContentHeight(Style.space(326))

    Rectangle {
      id: cockpit
      anchors.fill: parent
      radius: Math.max(Style.cornerRadius, Style.space(16))
      clip: false
      color: Color.background

      Image {
        id: backdropSource
        anchors.fill: parent
        visible: false
        source: root.artUrl
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: cockpit.width
        sourceSize.height: cockpit.height
      }

      MultiEffect {
        anchors.fill: parent
        source: backdropSource
        visible: backdropSource.status === Image.Ready
        maskEnabled: true
        maskSource: backdropMask
        maskThresholdMin: 0.08
        maskSpreadAtMin: 0.12
        blurEnabled: true
        blur: 1
        blurMax: 92
        blurMultiplier: 1.3
        saturation: 0.25
        contrast: -0.12
        opacity: 0.52
      }

      Item {
        id: backdropMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        Rectangle {
          anchors.fill: parent
          radius: cockpit.radius
          color: "white"
          antialiasing: true
        }
      }

      Rectangle {
        anchors.fill: parent
        radius: cockpit.radius
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop {
            position: 0
            color: Qt.rgba(root.cockpitAccent.r, root.cockpitAccent.g,
              root.cockpitAccent.b, 0.34)
          }
          GradientStop { position: 0.48; color: Qt.rgba(0.025, 0.025, 0.035, 0.83) }
          GradientStop { position: 1; color: Qt.rgba(0.01, 0.01, 0.018, 0.96) }
        }
      }

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: Style.space(1)
        border.color: Qt.rgba(root.cockpitAccent.r, root.cockpitAccent.g,
          root.cockpitAccent.b, 0.55)
        radius: cockpit.radius
      }

      Item {
        id: artStage
        width: Style.space(206)
        height: width
        anchors.left: parent.left
        anchors.leftMargin: Style.space(26)
        anchors.verticalCenter: parent.verticalCenter
        opacity: root.artReveal
        scale: (0.7 + root.artReveal * 0.3)
          * (1 + root.beatPulse * 0.026)
        rotation: -9 * (1 - root.artReveal)

        Rectangle {
          anchors.centerIn: parent
          width: parent.width + Style.space(28) + root.bass * Style.space(9)
          height: width
          radius: width / 2
          color: Qt.rgba(root.cockpitAccent.r, root.cockpitAccent.g,
            root.cockpitAccent.b, 0.055)
          border.width: Style.space(1)
          border.color: Qt.rgba(root.cockpitAccent.r, root.cockpitAccent.g,
            root.cockpitAccent.b, 0.28 + root.beatPulse * 0.38)
        }

        Rectangle {
          anchors.centerIn: parent
          width: parent.width + Style.space(12)
          height: width
          radius: width / 2
          color: Qt.rgba(0, 0, 0, 0.46)
          border.width: Style.space(4)
          border.color: Qt.rgba(0.03, 0.03, 0.04, 0.92)
        }

        Item {
          id: record
          anchors.centerIn: parent
          width: Style.space(188)
          height: width

          Image {
            id: coverSource
            anchors.fill: parent
            visible: false
            source: root.artUrl
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: width
            sourceSize.height: height
          }

          Item {
            id: coverMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle { anchors.fill: parent; radius: width / 2 }
          }

          MultiEffect {
            anchors.fill: parent
            source: coverSource
            visible: coverSource.status === Image.Ready
            maskEnabled: true
            maskSource: coverMask
          }

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            visible: coverSource.status !== Image.Ready
            color: Qt.rgba(root.cockpitAccent.r, root.cockpitAccent.g,
              root.cockpitAccent.b, 0.32)
            Text {
              anchors.centerIn: parent
              text: "󰎆"
              color: root.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge * 2
            }
          }

          Repeater {
            model: 5
            Rectangle {
              required property int index
              anchors.centerIn: parent
              width: record.width - Style.space(18 + index * 22)
              height: width
              radius: width / 2
              color: "transparent"
              border.width: Style.space(1)
              border.color: Qt.rgba(1, 1, 1, 0.065)
            }
          }

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(30)
            height: width
            radius: width / 2
            color: Qt.rgba(0.015, 0.015, 0.02, 0.88)
            border.width: Style.space(3)
            border.color: Qt.rgba(root.foreground.r, root.foreground.g,
              root.foreground.b, 0.68)
            Rectangle {
              anchors.centerIn: parent
              width: Style.space(7)
              height: width
              radius: width / 2
              color: root.cockpitAccent
            }
          }
        }
      }

      Column {
        id: info
        anchors.left: artStage.right
        anchors.leftMargin: Style.space(26)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(26)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)
        opacity: root.copyReveal
        transform: Translate { x: Style.space(22) * (1 - root.copyReveal) }

        Text {
          width: parent.width
          text: root.playing ? "NOW PLAYING" : "PAUSED"
          textFormat: Text.PlainText
          color: root.cockpitAccent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: Style.spaceReal(1.8)
        }

        Text {
          width: parent.width
          text: root.title || "Nothing playing"
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          maximumLineCount: 2
          wrapMode: Text.Wrap
          elide: Text.ElideRight
          lineHeight: 0.94
        }

        Text {
          width: parent.width
          text: root.artist + (root.album ? "  ·  " + root.album : "")
          textFormat: Text.PlainText
          color: Qt.rgba(root.foreground.r, root.foreground.g,
            root.foreground.b, 0.72)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          maximumLineCount: 1
          elide: Text.ElideRight
        }

        ReactiveSpectrum {
          width: parent.width
          height: Style.space(42)
          spectrum: root.spectrum
          accent: root.cockpitAccent
          foreground: root.foreground
          playing: root.playing
          reveal: root.controlReveal
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          opacity: root.controlReveal

          Item {
            width: parent.width
            height: Style.space(14)

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(3)
              radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g,
                root.foreground.b, 0.18)
            }

            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width * root.progress
              height: Style.space(4)
              radius: height / 2
              color: root.cockpitAccent
              Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }

            Rectangle {
              x: Math.max(0, Math.min(parent.width - width,
                parent.width * root.progress - width / 2))
              anchors.verticalCenter: parent.verticalCenter
              width: progressHover.hovered ? Style.space(12) : Style.space(8)
              height: width
              radius: width / 2
              color: root.foreground
              opacity: root.trackLength > 0 ? 1 : 0
              Behavior on width { SpringAnimation { spring: 4; damping: 0.48 } }
            }

            HoverHandler { id: progressHover }
            TapHandler {
              acceptedButtons: Qt.LeftButton
              enabled: root.activePlayer && root.activePlayer.canSeek
              onTapped: function(eventPoint) {
                root.seek(eventPoint.position.x / parent.width)
              }
            }
          }

          Row {
            width: parent.width
            Text {
              id: currentTime
              text: root.formatTime(root.trackPosition)
              color: Qt.rgba(root.foreground.r, root.foreground.g,
                root.foreground.b, 0.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item {
              width: parent.width - currentTime.implicitWidth - remaining.implicitWidth
              height: 1
            }
            Text {
              id: remaining
              text: root.trackLength > 0 ? "−" + root.formatTime(
                Math.max(0, root.trackLength - root.trackPosition)) : "LIVE"
              color: Qt.rgba(root.foreground.r, root.foreground.g,
                root.foreground.b, 0.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(14)
          opacity: root.controlReveal

          MediaControl {
            icon: "󰒮"
            foreground: root.foreground
            accent: root.cockpitAccent
            reveal: root.controlReveal
            controlEnabled: root.activePlayer && root.activePlayer.canGoPrevious
            onClicked: root.action("previous")
          }

          MediaControl {
            icon: root.playIcon
            foreground: root.foreground
            accent: root.cockpitAccent
            reveal: root.controlReveal
            primary: true
            controlEnabled: root.activePlayer && (root.activePlayer.canTogglePlaying
              || root.activePlayer.canPlay || root.activePlayer.canPause)
            onClicked: root.action("playPause")
          }

          MediaControl {
            icon: "󰒭"
            foreground: root.foreground
            accent: root.cockpitAccent
            reveal: root.controlReveal
            controlEnabled: root.activePlayer && root.activePlayer.canGoNext
            onClicked: root.action("next")
          }
        }
      }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(10)
        text: root.activePlayer
          ? (root.activePlayer.identity || root.activePlayer.desktopEntry || "MPRIS") : "MPRIS"
        textFormat: Text.PlainText
        color: Qt.rgba(root.foreground.r, root.foreground.g,
          root.foreground.b, 0.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        opacity: root.artReveal
      }
    }
  }
}
