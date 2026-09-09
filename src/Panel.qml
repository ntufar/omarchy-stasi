import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import QtWebEngine
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Arrival board popup for the watched stop. Data lives on the host widget;
// this panel only reads hostWidget.arrivals / .stopCode / .tick so every
// bar instance's popup stays in sync with its own pill.
Panel {
  id: root
  moduleName: "io.github.ntufar.stasi"
  ipcTarget: "io.github.ntufar.stasi"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // The bar tracks the widget mounted in its slot, not this nested panel.
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string stopCode: hostWidget ? hostWidget.stopCode : ""
  readonly property var arrivals: hostWidget ? hostWidget.arrivals : []
  readonly property double fetchedAt: hostWidget ? hostWidget.fetchedAt : 0
  readonly property int tick: hostWidget ? hostWidget.tick : 0
  readonly property string error: hostWidget ? hostWidget.error : ""
  readonly property var watchList: hostWidget && hostWidget.stopList ? hostWidget.stopList : []
  readonly property var stopSections: hostWidget && hostWidget.stopSections ? hostWidget.stopSections : []
  readonly property string watchTitle: watchList.length === 0 ? "Stasi"
    : (watchList.length === 1 ? "Στάση " + watchList[0] : "Stasi · " + watchList.length + " στάσεις")

  // ---- Stop search + arrival preview (tapping a result previews that
  // stop's board without changing the watched stop) ----
  property string searchPending: ""
  property var searchResults: []
  property string searchError: ""
  property bool searching: false
  property string previewCode: ""
  property string previewDescr: ""
  property var previewArrivals: []
  property double previewFetchedAt: 0
  property string previewError: ""

  // ---- Map state (side-by-side Leaflet view, Syntagma-centered) ----
  property string linePending: ""
  property var lineResults: []
  property string lineError: ""
  property bool searchingLines: false
  property var geoCache: []
  property string mapState: ""
  property string overlayLine: ""
  property string overlayDescr: ""

  readonly property string mapUrl: hostWidget && hostWidget.pluginRoot
    ? "file://" + hostWidget.pluginRoot + "/assets/map.html" : ""

  readonly property bool previewing: root.previewCode !== ""
  readonly property var shownArrivals: root.previewing ? root.previewArrivals : root.arrivals
  readonly property double shownFetchedAt: root.previewing ? root.previewFetchedAt : root.fetchedAt
  readonly property string shownError: root.previewing ? root.previewError : root.error
  readonly property string shownTitle: root.previewing
    ? (root.previewDescr !== "" ? root.previewDescr : "Στάση " + root.previewCode)
    : root.watchTitle

  function runSearch(text) {
    var q = (text || "").trim()
    if (q.length < 2) {
      root.searchResults = []
      root.searchError = ""
      root.searching = false
      return
    }
    if (!hostWidget || !hostWidget.helperPath) {
      root.searchError = "helper unavailable"
      return
    }
    if (searchProc.running) {
      root.searchPending = q
      return
    }
    root.searchPending = ""
    root.searching = true
    searchProc.command = [hostWidget.helperPath, "search", q, "--limit", "8"]
    searchProc.running = true
  }

  function previewStop(code, descr) {
    root.previewCode = code
    root.previewDescr = descr || ""
    root.previewArrivals = []
    root.previewFetchedAt = 0
    root.previewError = ""
    if (!hostWidget || !hostWidget.helperPath) {
      root.previewError = "helper unavailable"
      return
    }
    if (previewProc.running) return
    previewProc.command = [hostWidget.helperPath, "arrivals", "--stop", code]
    previewProc.running = true
  }

  function clearPreview() {
    root.previewCode = ""
    root.previewDescr = ""
    root.previewArrivals = []
    root.previewFetchedAt = 0
    root.previewError = ""
  }

  function runLineSearch(text) {
    var q = (text || "").trim()
    if (q.length < 2) {
      root.lineResults = []
      root.lineError = ""
      root.searchingLines = false
      return
    }
    if (!hostWidget || !hostWidget.helperPath) {
      root.lineError = "helper unavailable"
      return
    }
    if (linesProc.running) {
      root.linePending = q
      return
    }
    root.linePending = ""
    root.searchingLines = true
    linesProc.command = [hostWidget.helperPath, "search-lines", q, "--limit", "5"]
    linesProc.running = true
  }

  function loadMapMarkers() {
    if (!hostWidget || !hostWidget.helperPath || geoProc.running) return
    root.mapState = "loading stations…"
    geoProc.command = [hostWidget.helperPath, "stops-geo"]
    geoProc.running = true
  }

  function focusStopOnMap(code) {
    for (var i = 0; i < geoCache.length; i++) {
      if (geoCache[i].stop_code === code) {
        mapView.runJavaScript("focusStop(" + JSON.stringify(code) + ", "
          + geoCache[i].lat + ", " + geoCache[i].lng + ")")
        return
      }
    }
    mapView.runJavaScript("focusStop(" + JSON.stringify(code) + ")")
  }

  function showLineOverlay(lineCode, lineDescr) {
    if (!hostWidget || !hostWidget.helperPath || lineProc.running) return
    root.overlayLine = lineCode
    root.overlayDescr = lineDescr || ""
    lineProc.command = [hostWidget.helperPath, "line-stops", "--line", lineCode]
    lineProc.running = true
  }

  function clearLineOverlay() {
    root.overlayLine = ""
    root.overlayDescr = ""
    mapView.runJavaScript("clearLineStops()")
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      id: searchOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.searching = false
      if (exitCode !== 0) {
        try {
          var failed = JSON.parse(searchOut.text)
          root.searchError = failed && failed.error ? String(failed.error) : "search failed"
        } catch (e) {
          root.searchError = "search failed"
        }
        root.searchResults = []
      } else {
        try {
          var payload = JSON.parse(searchOut.text)
          root.searchResults = (payload && payload.stops) || []
          root.searchError = ""
        } catch (e) {
          root.searchError = "bad response"
          root.searchResults = []
        }
      }
      if (root.searchPending !== "") {
        var q = root.searchPending
        root.searchPending = ""
        root.runSearch(q)
      }
    }
  }

  Process {
    id: previewProc
    stdout: StdioCollector {
      id: previewOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        try {
          var failed = JSON.parse(previewOut.text)
          root.previewError = failed && failed.error ? String(failed.error) : "fetch failed"
        } catch (e) {
          root.previewError = "fetch failed"
        }
        return
      }
      try {
        var payload = JSON.parse(previewOut.text)
        if (!payload || payload.error) {
          root.previewError = payload && payload.error ? String(payload.error) : "bad response"
          return
        }
        root.previewArrivals = payload.arrivals || []
        root.previewFetchedAt = (payload.fetched_at || 0) * 1000
        root.previewError = ""
      } catch (e) {
        root.previewError = "bad response"
      }
    }
  }

  Timer {
    id: searchDebounce
    interval: 250
    onTriggered: {
      root.runSearch(searchField.text)
      root.runLineSearch(searchField.text)
    }
  }

  Process {
    id: linesProc
    stdout: StdioCollector {
      id: linesOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.searchingLines = false
      if (exitCode !== 0) {
        try {
          var failed = JSON.parse(linesOut.text)
          root.lineError = failed && failed.error ? String(failed.error) : "line search failed"
        } catch (e) {
          root.lineError = "line search failed"
        }
        root.lineResults = []
      } else {
        try {
          var payload = JSON.parse(linesOut.text)
          root.lineResults = (payload && payload.lines) || []
          root.lineError = ""
        } catch (e) {
          root.lineError = "bad response"
          root.lineResults = []
        }
      }
      if (root.linePending !== "") {
        var q = root.linePending
        root.linePending = ""
        root.runLineSearch(q)
      }
    }
  }

  Process {
    id: geoProc
    stdout: StdioCollector {
      id: geoOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        try {
          var failed = JSON.parse(geoOut.text)
          root.mapState = failed && failed.error ? String(failed.error) : "stations unavailable"
        } catch (e) {
          root.mapState = "stations unavailable"
        }
        return
      }
      try {
        var payload = JSON.parse(geoOut.text)
        var stops = (payload && payload.stops) || []
        root.geoCache = stops
        var rows = []
        for (var i = 0; i < stops.length; i++) {
          rows.push([stops[i].stop_code, stops[i].lat, stops[i].lng, stops[i].descr])
        }
        mapView.runJavaScript("loadStops(" + JSON.stringify(rows) + ")", function(count) {
          root.mapState = count + " stations"
        })
      } catch (e) {
        root.mapState = "stations unavailable"
      }
    }
  }

  Process {
    id: lineProc
    stdout: StdioCollector {
      id: lineOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.overlayLine = ""
        root.overlayDescr = ""
        return
      }
      try {
        var payload = JSON.parse(lineOut.text)
        var rows = []
        var routes = (payload && payload.routes) || []
        for (var r = 0; r < routes.length; r++) {
          var stops = routes[r].stops || []
          for (var i = 0; i < stops.length; i++) {
            if (stops[i].lat !== undefined && stops[i].lat !== null) {
              rows.push([stops[i].stop_code, stops[i].lat, stops[i].lng, stops[i].descr])
            }
          }
        }
        mapView.runJavaScript("showLineStops(" + JSON.stringify(rows) + ")")
      } catch (e) {
        root.overlayLine = ""
        root.overlayDescr = ""
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(880)
    contentHeight: panel.fittedContentHeight(Math.max(board.implicitHeight, 600) + 24)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Suspend panel hotkeys while typing (cf. weather Panel editingLocation):
      // the catcher runs BeforeItem and would swallow h/j/k/l/x/Space/Enter.
      blocked: searchField.activeFocus
      onCloseRequested: root.close()
    }

    Column {
      id: board
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: 12
      width: 400
      spacing: 8

      Text {
        width: parent.width
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.bold: true
        font.pixelSize: 16
        text: root.shownTitle
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.8
        font.family: root.contentFontFamily
        font.pixelSize: 12
        font.underline: true
        text: "← " + (root.previewCode !== "" ? root.previewCode + " · " : "") + "Watchlist"
        visible: root.previewing

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.clearPreview()
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.8
        font.family: root.contentFontFamily
        font.pixelSize: 12
        font.underline: true
        text: "+ Watch " + root.previewCode
        visible: root.previewing && root.watchList.indexOf(root.previewCode) === -1

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.hostWidget) root.hostWidget.watchStop(root.previewCode)
          }
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        text: root.shownError !== "" ? root.shownError : Model.formatAge(root.shownFetchedAt, root.tick)
        visible: text !== ""
      }

      Repeater {
        model: root.shownArrivals

        Text {
          required property var modelData
          width: board.width
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: 20
          font.bold: true
          wrapMode: Text.WordWrap
          text: Model.rowLabel(modelData, root.shownFetchedAt, root.tick)
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        wrapMode: Text.WordWrap
        text: root.watchList.length === 0 && !root.previewing
          ? "Search for a stop below, or: omarchy bar set io.github.ntufar.stasi stops <code1,code2>"
          : (root.shownArrivals.length === 0 && root.shownError === "" ? "No live arrivals." : "")
        visible: text !== ""
      }

      Repeater {
        model: (!root.previewing && root.watchList.length > 1) ? root.stopSections : []

        Item {
          required property var modelData
          width: board.width
          implicitHeight: watchCol.implicitHeight

          Column {
            id: watchCol
            width: parent.width - 28
            spacing: 0

            Text {
              width: parent.width
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: 14
              font.bold: true
              wrapMode: Text.WordWrap
              text: "Στάση " + modelData.stop

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.previewStop(modelData.stop, "")
                  root.focusStopOnMap(modelData.stop)
                }
              }
            }

            Text {
              width: parent.width
              color: root.contentForeground
              opacity: 0.6
              font.family: root.contentFontFamily
              font.pixelSize: 12
              wrapMode: Text.WordWrap
              text: modelData.error ? String(modelData.error)
                : (modelData.arrivals && modelData.arrivals.length > 0
                  ? Model.rowLabel(modelData.arrivals[0], (modelData.fetched_at || 0) * 1000, root.tick)
                  : "—")
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: root.contentForeground
            opacity: 0.6
            font.family: root.contentFontFamily
            font.pixelSize: 14
            text: "✕"

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.hostWidget) root.hostWidget.unwatchStop(modelData.stop)
              }
            }
          }
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.8
        font.family: root.contentFontFamily
        font.pixelSize: 12
        font.underline: true
        text: "Refresh now"

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.previewing) root.previewStop(root.previewCode, root.previewDescr)
            else if (root.hostWidget) root.hostWidget.refresh()
          }
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.bold: true
        font.pixelSize: 14
        text: "Search stops"
      }

      QQC.TextField {
        id: searchField
        width: parent.width
        placeholderText: "συνταγμα / syntagma / 060123"
        font.family: root.contentFontFamily
        font.pixelSize: 14
        color: root.contentForeground
        background: Rectangle {
          color: "transparent"
          border.color: root.contentForeground
          border.width: 1
          opacity: 0.35
          radius: 6
        }
        onTextChanged: searchDebounce.restart()
        Keys.onEscapePressed: root.close()
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        text: "Searching…"
        visible: root.searching
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        wrapMode: Text.WordWrap
        text: root.searchError
        visible: root.searchError !== ""
      }

      Repeater {
        model: root.searchResults

        Item {
          required property var modelData
          width: board.width
          implicitHeight: rowCol.implicitHeight

          Column {
            id: rowCol
            width: parent.width
            spacing: 0

            Text {
              width: parent.width
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: 14
              font.bold: true
              wrapMode: Text.WordWrap
              text: modelData.descr || modelData.stop_code

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.previewStop(modelData.stop_code, modelData.descr || "")
                  root.focusStopOnMap(modelData.stop_code)
                }
              }
            }

            Text {
              width: parent.width
              color: root.contentForeground
              opacity: 0.6
              font.family: root.contentFontFamily
              font.pixelSize: 12
              text: "Στάση " + modelData.stop_code
            }

            Text {
              width: parent.width
              color: root.contentForeground
              opacity: 0.8
              font.family: root.contentFontFamily
              font.pixelSize: 12
              font.underline: true
              text: "＋ Watch"
              visible: root.watchList.indexOf(modelData.stop_code) === -1

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.hostWidget) root.hostWidget.watchStop(modelData.stop_code)
                }
              }
            }
          }
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.bold: true
        font.pixelSize: 14
        text: "Lines"
        visible: root.lineResults.length > 0 || root.searchingLines
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        text: "Searching lines…"
        visible: root.searchingLines
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        wrapMode: Text.WordWrap
        text: root.lineError
        visible: root.lineError !== ""
      }

      Repeater {
        model: root.lineResults

        Item {
          required property var modelData
          width: board.width
          implicitHeight: lineRow.implicitHeight

          Column {
            id: lineRow
            width: parent.width
            spacing: 0

            Text {
              width: parent.width
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: 14
              font.bold: true
              wrapMode: Text.WordWrap
              text: "Line " + (modelData.line_id || modelData.line_code)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showLineOverlay(modelData.line_code,
                  (modelData.line_id || modelData.line_code) + " · " + (modelData.line_descr || ""))
              }
            }

            Text {
              width: parent.width
              color: root.contentForeground
              opacity: 0.6
              font.family: root.contentFontFamily
              font.pixelSize: 12
              wrapMode: Text.WordWrap
              text: modelData.line_descr || ""
              visible: (modelData.line_descr || "") !== ""
            }
          }
        }
      }
    }

    Column {
      id: mapCol
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: 12
      width: 440
      spacing: 8

      WebEngineView {
        id: mapView
        width: 440
        height: 560
        url: root.mapUrl

        onNavigationRequested: function(request) {
          var target = String(request.url)
          if (target.indexOf("stasi://stop/") === 0) {
            request.action = WebEngineView.IgnoreRequest
            root.previewStop(decodeURIComponent(target.slice(13)), "")
          }
        }

        onLoadingChanged: function(loadRequest) {
          if (loadRequest.status === WebEngineView.LoadSucceededStatus) {
            root.loadMapMarkers()
          } else if (loadRequest.status === WebEngineView.LoadFailedStatus) {
            root.mapState = "map failed to load"
          }
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        wrapMode: Text.WordWrap
        text: root.overlayLine !== ""
          ? "Line " + root.overlayDescr + " — tap × to clear"
          : root.mapState
        visible: text !== ""

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          enabled: root.overlayLine !== ""
          onClicked: root.clearLineOverlay()
        }
      }
    }
  }
}
