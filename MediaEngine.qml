import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire

// The spectrum and the now-playing state, in one object the bar widget owns.
//
// CAVA analyzer adapted from ryrobes.beatbar (MIT, Ryan Robitaille).
// Beatdeck used to call serviceFor("ryrobes.beatbar"), which is silent unless
// that plugin is enabled, and then serviceFor("pi.media") for the track. Both
// lookups go through the shell's scoped plugin API, which hands a widget only
// its own plugin's service — and hands a widget hosted by a third-party bar
// nothing at all, because the widget's `bar.shell` is the *bar's* scoped API.
// So on any bar other than the stock one, Beatdeck saw neither a spectrum nor
// a player and sat on its idle play button while music was audibly playing.
// Nothing here asks the shell for anything: the widget on the bar is the
// whole plugin.
Item {
  id: root

  property var shell: null

  width: 0
  height: 0
  visible: false

  readonly property int bandCount: 24
  readonly property var defaultSink: Pipewire.defaultAudioSink

  // cava's pipewire backend resolves `source = auto` to the default *capture*
  // device (a microphone), not the default sink's monitor. On a host with no
  // mic — or one whose audio leaves over the network to a Sonos — that means
  // cava reads pure silence and the spectrum sits flat while music plays. So
  // we point cava at the monitor of whatever sink is currently the default,
  // and rebuild it whenever that sink changes (see onDefaultSinkChanged).
  // The monitor node name is the sink node name with ".monitor" appended,
  // which is what pactl/pw report for every sink including the DLNA ones.
  readonly property string sinkMonitorSource: (defaultSink && defaultSink.name)
    ? defaultSink.name + ".monitor" : "auto"

  // cava needs a config file (-p); it has no CLI override for the source, so
  // we render a runtime copy with the resolved source into the runtime dir
  // and hand cava that. The shipped cava.conf is the template of record.
  readonly property string runtimeConfigPath:
    (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/nixfred-beatdeck-cava.conf"

  // Kept in sync with cava.conf; __SOURCE__ is swapped for sinkMonitorSource.
  // Embedded rather than read from disk so the first render never races an
  // async file load before cava starts.
  readonly property string cavaConfigTemplate:
    "[general]\n"
    + "framerate = 15\n"
    + "bars = 24\n"
    + "autosens = 1\n"
    + "sensitivity = 100\n"
    + "lower_cutoff_freq = 45\n"
    + "higher_cutoff_freq = 16000\n"
    + "sleep_timer = 2\n"
    + "\n"
    + "[input]\n"
    + "method = pipewire\n"
    + "source = __SOURCE__\n"
    + "sample_rate = 48000\n"
    + "active = 1\n"
    + "remix = 1\n"
    + "virtual = 1\n"
    + "\n"
    + "[output]\n"
    + "method = raw\n"
    + "channels = stereo\n"
    + "raw_target = /dev/stdout\n"
    + "data_format = ascii\n"
    + "ascii_max_range = 1000\n"
    + "bar_delimiter = 59\n"
    + "frame_delimiter = 10\n"
    + "\n"
    + "[smoothing]\n"
    + "noise_reduction = 65\n"

  property var bands: zeroBands()
  property real level: 0
  property real bass: 0
  property real bassAverage: 0
  property bool active: false
  property bool available: false
  property bool componentReady: false
  property bool expectedStop: false
  property bool cavaNoticePending: false
  property bool cavaNoticeShown: false
  property double lastBeatAt: 0
  property int beatCount: 0
  property string lastError: ""

  signal beat(real strength)

  // ── Now playing ───────────────────────────────────────────────────────────
  // Beatdeck used to read the track from serviceFor("pi.media"). The shell
  // sandboxes a third-party plugin to its OWN service — serviceFor() of any
  // other plugin id returns null for anything that is not the bar itself — so
  // that lookup silently produced no player and the widget sat collapsed on
  // its idle play button while music was audibly playing. Owning an MPRIS
  // read here is the same fix already applied to the cava analyzer above: the
  // widget on the bar is enough to drive everything it shows.
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  // Quickshell 0.3.1 does not reliably pick up a player that registers on the
  // bus after the shell started: a Cliamp restarted mid-session stayed missing
  // from Mpris.players (and from pi.media, which uses the same service) while
  // it was audibly playing, so the cockpit fell back to an idle Brave tab and
  // said "Nothing playing". busPlayers is a plain D-Bus poll that fills in any
  // player Quickshell does not list, with the same property and method names.
  property var busPlayers: []
  readonly property var players: mprisPlayers.concat(busPlayers)
  property int playerRevision: 0
  readonly property var activePlayer: {
    playerRevision // re-select when any player's state changes, not just the list
    return selectActivePlayer()
  }

  function hasTrackMetadata(player) {
    return !!(player && (player.trackTitle || player.trackArtist))
  }

  function isProxyPlayer(player) {
    var dbus = String(player && player.dbusName || "").toLowerCase()
    var entry = String(player && player.desktopEntry || "").toLowerCase()
    return dbus.indexOf("playerctld") !== -1 || entry === "playerctld"
  }

  // Prefer something actually playing with a track on it, then anything
  // playing, then anything with a track. A playerctld proxy is only ever a
  // last resort, because it mirrors a real player that is usually also listed.
  function selectActivePlayer() {
    var playingTrack = null, playing = null, track = null, any = null
    var proxyFallback = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      if (isProxyPlayer(p)) { if (!proxyFallback) proxyFallback = p; continue }
      if (p.isPlaying && hasTrackMetadata(p)) { if (!playingTrack) playingTrack = p }
      else if (p.isPlaying) { if (!playing) playing = p }
      else if (hasTrackMetadata(p)) { if (!track) track = p }
      else if (!any) any = p
    }
    return playingTrack || playing || track || any || proxyFallback || null
  }

  function playerKey(player) {
    return String(player && (player.dbusName || player.identity || "") || "")
  }

  // The subset of pi.media's runAction that the cockpit actually calls. The
  // extra arguments keep the call shape identical, so BarWidget can talk to
  // either service without branching.
  function runAction(action, showFeedback, targetKey) {
    var player = activePlayer
    if (targetKey) {
      for (var i = 0; i < players.length; i++)
        if (playerKey(players[i]) === targetKey) { player = players[i]; break }
    }
    if (!player) return

    if (action === "next") {
      if (player.canGoNext) player.next()
    } else if (action === "previous") {
      if (player.canGoPrevious) player.previous()
    } else if (action === "play") {
      if (player.canPlay) player.play()
      else if (player.canTogglePlaying && !player.isPlaying) player.togglePlaying()
    } else if (action === "pause") {
      if (player.canPause) player.pause()
      else if (player.canTogglePlaying && player.isPlaying) player.togglePlaying()
    } else {
      if (player.canTogglePlaying) player.togglePlaying()
      else if (player.isPlaying && player.canPause) player.pause()
      else if (!player.isPlaying && player.canPlay) player.play()
    }
  }

  // A binding on `players` alone never re-fires when a player merely starts or
  // stops playing, or swaps track. Watch each live player and bump a revision
  // the activePlayer binding depends on.
  Instantiator {
    model: root.mprisPlayers
    delegate: QtObject {
      required property var modelData
      readonly property Connections watcher: Connections {
        target: modelData
        function onPlaybackStateChanged() { root.playerRevision++ }
        function onTrackTitleChanged() { root.playerRevision++ }
        function onTrackArtistChanged() { root.playerRevision++ }
      }
    }
  }

  function busSuffix(name) {
    return String(name || "").replace(/^org\.mpris\.MediaPlayer2\./, "")
  }

  // One poll result line -> a player object shaped like Quickshell's
  // MprisPlayer, for the handful of members Beatdeck reads and calls.
  function makeBusPlayer(entry) {
    var name = String(entry.name || "")
    var props = entry.player && entry.player.data && entry.player.data[0] ? entry.player.data[0] : {}
    function v(key, fallback) {
      return props[key] && props[key].data !== undefined ? props[key].data : fallback
    }
    var meta = v("Metadata", {})
    function m(key) {
      var item = meta[key]
      if (!item || item.data === undefined) return ""
      return Array.isArray(item.data) ? item.data.join(", ") : String(item.data)
    }
    var status = String(v("PlaybackStatus", "Stopped"))
    var lengthUs = Number(meta["mpris:length"] ? meta["mpris:length"].data : 0) || 0
    var basePosition = (Number(v("Position", 0)) || 0) / 1000000
    var polledAt = Date.now()
    var playing = status === "Playing"

    function call(method) {
      Quickshell.execDetached(["busctl", "--user", "call", name, "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player", method])
      busPoll.soon()
    }

    var player = {
      dbusName: name,
      identity: entry.identity && entry.identity.data ? String(entry.identity.data) : busSuffix(name),
      desktopEntry: "",
      trackTitle: m("xesam:title"),
      trackArtist: m("xesam:artist"),
      trackAlbum: m("xesam:album"),
      trackArtUrl: m("mpris:artUrl"),
      isPlaying: playing,
      canControl: v("CanControl", false) === true,
      canGoNext: v("CanGoNext", false) === true,
      canGoPrevious: v("CanGoPrevious", false) === true,
      canPlay: v("CanPlay", false) === true,
      canPause: v("CanPause", false) === true,
      canTogglePlaying: v("CanPlay", false) === true || v("CanPause", false) === true,
      canSeek: false,
      lengthSupported: lengthUs > 0,
      length: lengthUs / 1000000,
      positionSupported: props.Position !== undefined,
      positionChanged: function() {},
      next: function() { call("Next") },
      previous: function() { call("Previous") },
      play: function() { call("Play") },
      pause: function() { call("Pause") },
      togglePlaying: function() { call("PlayPause") },
      signature: name + "|" + status + "|" + m("xesam:title") + "|" + m("xesam:artist")
        + "|" + m("mpris:artUrl")
    }
    // Extrapolated between polls so the progress bar moves smoothly.
    Object.defineProperty(player, "position", {
      get: function() { return playing ? basePosition + (Date.now() - polledAt) / 1000 : basePosition },
      set: function(value) {}
    })
    return player
  }

  function applyBusPoll(lines) {
    var known = {}
    for (var i = 0; i < mprisPlayers.length; i++) {
      var p = mprisPlayers[i]
      if (p) known[busSuffix(p.dbusName)] = true
    }
    var next = []
    for (var j = 0; j < lines.length; j++) {
      var entry
      try { entry = JSON.parse(lines[j]) } catch (e) { continue }
      if (!entry || !entry.name || known[busSuffix(entry.name)]) continue
      next.push(makeBusPlayer(entry))
    }
    // Only replace the list when something a viewer can see changed, so the
    // cockpit is not rebuilt on every poll just because Position ticked.
    var before = busPlayers.map(function(p) { return p.signature }).join("\n")
    var after = next.map(function(p) { return p.signature }).join("\n")
    if (before !== after) busPlayers = next
  }

  function zeroBands() {
    var values = []
    for (var i = 0; i < bandCount; i++) values.push(0)
    return values
  }

  function clearSpectrum() {
    bands = zeroBands()
    level = 0
    bass = 0
    active = false
  }

  function normalized(value) {
    var raw = Math.max(0, Math.min(1000, Number(value) || 0)) / 1000
    return Math.pow(raw, 0.72)
  }

  // Render the runtime cava config for the current default sink. Returns the
  // effective source so callers can log what cava will actually listen to.
  function writeRuntimeConfig() {
    var body = cavaConfigTemplate.replace("__SOURCE__", sinkMonitorSource)
    runtimeConfFile.setText(body)
    return sinkMonitorSource
  }

  function consumeFrame(line) {
    var fields = String(line || "").trim().split(";")
    var values = []
    for (var i = 0; i < fields.length; i++) {
      if (fields[i] !== "") values.push(normalized(fields[i]))
    }
    if (values.length !== bandCount) return

    var peak = 0
    for (var j = 0; j < values.length; j++) peak = Math.max(peak, values[j])

    // CAVA's stereo layout mirrors the channels with the lowest frequencies
    // toward the center, so the middle six bands form a useful beat envelope.
    var center = Math.floor(values.length / 2)
    var bassNow = 0
    for (var k = center - 3; k < center + 3; k++) bassNow += values[k]
    bassNow /= 6

    var previousAverage = bassAverage
    bassAverage = previousAverage <= 0
      ? bassNow
      : previousAverage * 0.94 + bassNow * 0.06

    var now = Date.now()
    var flux = bassNow - previousAverage
    var threshold = Math.max(0.045, previousAverage * 0.32)
    if (bassNow > 0.16 && flux > threshold && now - lastBeatAt > 180) {
      lastBeatAt = now
      beatCount += 1
      beat(Math.min(1, bassNow + flux))
    }

    bands = values
    level = peak
    bass = bassNow
    active = peak > 0.018
    silenceWatchdog.restart()
  }

  function restartAnalyzer() {
    if (!componentReady) return
    // The config is (re)rendered at the moment cava starts (restartTimer),
    // using the sink in force *then* — not now — so a transient default-sink
    // blip during the stop/start gap cannot leave a stale source in the file.
    if (analyzer.running) {
      expectedStop = true
      analyzer.running = false
    }
    restartTimer.restart()
  }

  function cavaIsUnavailable(message, exitCode) {
    var detail = String(message || "").toLowerCase()
    return Number(exitCode) === 127
      && detail.indexOf("cava") !== -1
      && (detail.indexOf("no such file") !== -1
        || detail.indexOf("not found") !== -1)
  }

  function showCavaUnavailableNotice() {
    if (cavaNoticeShown) return
    cavaNoticePending = true
    if (!shell || typeof shell.summon !== "function") return

    cavaNoticePending = false
    cavaNoticeShown = true
    shell.summon("omarchy.osd", JSON.stringify({
      icon: "media",
      message: "Beatdeck paused: CAVA is unavailable.",
      duration: 6000
    }))
  }

  // The default sink moving (local speakers → Sonos, or between speakers)
  // changes which monitor carries the audio. Re-render and restart cava.
  onDefaultSinkChanged: restartAnalyzer()
  onShellChanged: if (cavaNoticePending) showCavaUnavailableNotice()

  Component.onCompleted: {
    componentReady = true
    // The runtime config is rendered by restartTimer right before cava starts.
    restartTimer.restart()
  }

  FileView {
    id: runtimeConfFile
    path: root.runtimeConfigPath
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: analyzer
    command: [
      "setpriv",
      "--pdeathsig",
      "TERM",
      "cava",
      "-p",
      root.runtimeConfigPath
    ]

    stdout: SplitParser {
      onRead: function(line) { root.consumeFrame(line) }
    }

    stderr: SplitParser {
      onRead: function(line) {
        var message = String(line || "").trim()
        if (message !== "") root.lastError = message
      }
    }

    onStarted: {
      root.available = true
      root.lastError = ""
    }

    onExited: function(exitCode) {
      root.available = false
      root.clearSpectrum()
      if (root.expectedStop) {
        root.expectedStop = false
      } else {
        if (!root.lastError) root.lastError = "cava exited with status " + exitCode
        if (root.cavaIsUnavailable(root.lastError, exitCode))
          root.showCavaUnavailableNotice()
      }
      if (root.componentReady) restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 1800
    repeat: false
    onTriggered: {
      if (!root.componentReady || analyzer.running) return
      // Render for the sink that is current at start time, then launch cava
      // on it. FileView.atomicWrites means the file is complete before the
      // process starts on the same event-loop pass.
      root.writeRuntimeConfig()
      analyzer.running = true
    }
  }

  Process {
    id: busPoll
    property var pending: []
    function soon() { busPollTimer.interval = 350; busPollTimer.restart() }
    command: ["bash", "-c",
      "for n in $(busctl --user list --no-legend 2>/dev/null | awk '$1 ~ /^org[.]mpris[.]MediaPlayer2[.]/ {print $1}'); do "
      + "p=$(busctl --user -j call \"$n\" /org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties GetAll s org.mpris.MediaPlayer2.Player 2>/dev/null) || continue; "
      + "i=$(busctl --user -j get-property \"$n\" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2 Identity 2>/dev/null); "
      + "printf '{\"name\":\"%s\",\"player\":%s,\"identity\":%s}\\n' \"$n\" \"$p\" \"${i:-null}\"; "
      + "done"]
    stdout: SplitParser {
      onRead: function(line) { busPoll.pending.push(line) }
    }
    onStarted: pending = []
    onExited: {
      root.applyBusPoll(pending)
      pending = []
      busPollTimer.interval = 2000
      busPollTimer.restart()
    }
  }

  Timer {
    id: busPollTimer
    interval: 1200
    repeat: false
    running: true
    onTriggered: if (!busPoll.running) busPoll.running = true
  }

  Timer {
    id: silenceWatchdog
    interval: 650
    repeat: false
    onTriggered: root.clearSpectrum()
  }
}
