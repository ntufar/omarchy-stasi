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
  property var arrivals: []
  property double fetchedAt: 0
  property string error: ""
  property int tick: 0

  readonly property var widgetMetadata: bar && bar.barWidgetRegistry
    ? bar.barWidgetRegistry.metadataFor(moduleName) : null
  readonly property string helperPath: widgetMetadata && widgetMetadata.sourceDir
    ? String(widgetMetadata.sourceDir) + "/bin/stasi-client" : ""
  readonly property string displayText: Model.barLabel(stopCode, arrivals, fetchedAt, tick, error)
  readonly property string tooltip: stopCode === ""
    ? "Stasi: set a stop via `omarchy bar set io.github.ntufar.stasi stop <code>`"
    : "Stasi " + stopCode + (error !== "" ? " — " + error : "")

  function refresh() {
    if (!helperPath || stopCode === "" || fetchProc.running) return
    fetchProc.command = [helperPath, "arrivals", "--stop", stopCode]
    fetchProc.running = true
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
      root.fetchedAt = (payload.fetched_at || 0) * 1000
      root.error = ""
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
  onStopCodeChanged: {
    root.arrivals = []
    root.fetchedAt = 0
    root.error = ""
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

  Timer {
    id: pollTimer
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.stopCode !== "") root.refresh()
    }
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
