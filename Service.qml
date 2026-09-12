import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// CAVA analyzer adapted from ryrobes.beatbar (MIT, Ryan Robitaille).
// Beatdeck used to call serviceFor("ryrobes.beatbar"), which is silent unless
// that plugin is enabled. Owning the analyzer here means the bar widget that
// is actually on the bar is enough to drive the spectrum.
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

  Timer {
    id: silenceWatchdog
    interval: 650
    repeat: false
    onTriggered: root.clearSpectrum()
  }

  IpcHandler {
    target: "nixfred.beatdeck"

    function status(): string {
      return JSON.stringify({
        available: root.available,
        active: root.active,
        level: root.level,
        bass: root.bass,
        beatCount: root.beatCount,
        lastBeatAt: root.lastBeatAt,
        bands: root.bands,
        error: root.lastError,
        source: root.sinkMonitorSource
      })
    }

    function restart(): void {
      root.restartAnalyzer()
    }
  }
}
