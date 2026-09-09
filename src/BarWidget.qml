import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill: next OASA arrival at the watched stop. Left click toggles the
// arrival board; the pill counts down by wall clock between OASA polls.
BarWidget {
  id: root
  moduleName: "io.github.ntufar.stasi"

  property string stopCode: setting("stop", "")
  property var stopList: Model.parseStops(setting("stops", []), stopCode)
  property var arrivals: []
  property var stopSections: []
  property double fetchedAt: 0
  property string error: ""
  property int tick: 0
  // Alert threshold in minutes, 0 = off. One summary notification per poll
  // cycle at most; fired keys are remembered session-only (notifiedKeys).
  readonly property int alertThreshold: {
    var t = parseInt(setting("alertThreshold", 0), 10)
    return isNaN(t) ? 0 : Math.max(0, t)
  }
  property var notifiedKeys: []

  readonly property var widgetMetadata: bar && bar.barWidgetRegistry
    ? bar.barWidgetRegistry.metadataFor(moduleName) : null
  readonly property string helperPath: widgetMetadata && widgetMetadata.sourceDir
    ? String(widgetMetadata.sourceDir) + "/bin/stasi-client" : ""
  readonly property string displayText: Model.barLabel(
    stopList.length > 0 ? stopList.join(" ") : "", arrivals, fetchedAt, tick, error)
  readonly property string tooltip: stopList.length === 0
    ? "Stasi: search stops in the panel, or `omarchy bar set io.github.ntufar.stasi stops <code1,code2>`"
    : "Stasi " + stopList.join(" · ") + (error !== "" ? " — " + error : "")

  function refresh() {
    if (!helperPath || stopList.length === 0 || fetchProc.running) return
    var cmd = [helperPath, "arrivals"]
    for (var i = 0; i < stopList.length; i++) {
      cmd.push("--stop")
      cmd.push(stopList[i])
    }
    fetchProc.command = cmd
    fetchProc.running = true
  }

  // Watchlist persistence (clock-panel pattern): applied locally first so the
  // UI updates on the click; the shell.json write comes back as the same value.
  // Also clears the legacy single `stop` key so an unwatched stop stays gone.
  function saveStops(list) {
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.stops = list
    entry.stop = ""
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function watchStop(code) {
    code = String(code || "").trim()
    if (code === "" || stopList.indexOf(code) !== -1) return
    var list = stopList.slice()
    list.push(code)
    saveStops(list)
  }

  function unwatchStop(code) {
    var list = []
    for (var i = 0; i < stopList.length; i++) {
      if (stopList[i] !== code) list.push(stopList[i])
    }
    if (list.length !== stopList.length) saveStops(list)
  }

  // Alert cycle: the helper reuses the ~20 s arrivals cache, so this second
  // call costs no extra network. Firing stays best-effort and silent on error.
  function maybeAlert() {
    if (root.alertThreshold <= 0 || root.stopList.length === 0 || alertsProc.running) return
    var cmd = [helperPath, "alerts", "--threshold", String(root.alertThreshold)]
    for (var i = 0; i < stopList.length; i++) {
      cmd.push("--stop")
      cmd.push(stopList[i])
    }
    if (root.notifiedKeys.length > 0) {
      cmd.push("--notified")
      cmd.push(root.notifiedKeys.join(","))
    }
    alertsProc.command = cmd
    alertsProc.running = true
  }

  function fireAlert(due, threshold) {
    if (notifyProc.running) return
    var lines = []
    for (var i = 0; i < due.length && lines.length < 4; i++) {
      var parts = []
      if (due[i].line) parts.push(due[i].line)
      if (due[i].destination) parts.push(due[i].destination)
      parts.push(due[i].minutes === null || due[i].minutes === undefined ? "—" : due[i].minutes + "ʹ")
      if (due[i].stop) parts.push("Στάση " + due[i].stop)
      lines.push(parts.join(" · "))
    }
    if (due.length > lines.length) lines.push("+" + (due.length - lines.length) + " more")
    notifyProc.command = ["notify-send", "--app-name", "Stasi",
      "Stasi · ≤ " + threshold + "ʹ", lines.join("\n")]
    notifyProc.running = true
  }

  function handleResult(exitCode, text) {
    if (exitCode !== 0) {
      try {
        var failed = JSON.parse(text)
        root.error = failed && failed.error ? String(failed.error) : "fetch failed"
      } catch (e) {
        root.error = "fetch failed"
      }
      return
    }
    try {
      var payload = JSON.parse(text)
      if (!payload || payload.error) {
        root.error = payload && payload.error ? String(payload.error) : "bad response"
        return
      }
      root.arrivals = payload.arrivals || []
      root.stopSections = payload.stops || []
      root.fetchedAt = (payload.fetched_at || 0) * 1000
      root.error = ""
      root.maybeAlert()
      if (root.arrivals.length === 0) {
        for (var i = 0; i < root.stopSections.length; i++) {
          if (root.stopSections[i].error) {
            root.error = String(root.stopSections[i].error)
            break
          }
        }
      }
    } catch (e) {
      root.error = "bad response"
    }
  }

  // ---- Panel plumbing (same shape contract as panels/clock) ----
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onStopListChanged: {
    root.arrivals = []
    root.stopSections = []
    root.fetchedAt = 0
    root.error = ""
    root.notifiedKeys = []
    root.refresh()
  }
  onHelperPathChanged: root.refresh()

  Process {
    id: fetchProc
    stdout: StdioCollector {
      id: fetchOut
      waitForEnd: true
    }
    onExited: function(exitCode) { root.handleResult(exitCode, fetchOut.text) }
  }

  Process {
    id: alertsProc
    stdout: StdioCollector {
      id: alertsOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        var payload = JSON.parse(alertsOut.text)
        root.notifiedKeys = (payload && payload.notified) || []
        var due = (payload && payload.notify) || []
        if (due.length > 0) root.fireAlert(due, payload.threshold)
      } catch (e) {
        // Best-effort: a malformed alerts reply must not break the widget.
      }
    }
  }

  Process {
    id: notifyProc
  }

  Timer {
    id: pollTimer
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.tick++
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.ntufar.stasi"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    labelVisible: !root.vertical
    hasVisualContent: text !== ""
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.tooltip
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
