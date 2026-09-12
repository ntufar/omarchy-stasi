import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
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

  // ---- Tile-map view (pure QML; QtWebEngine cannot init in-process) ----
  // Tiles are never fetched straight from QML: OSM's tile usage policy
  // (osm.wiki/Blocked) requires an identifying User-Agent and local
  // caching, so every tile goes through `stasi-client map-tiles` (proper
  // UA + disk cache) and Image only ever loads the cached file:// result.
  property real mapLat: 37.9755
  property real mapLng: 23.7348
  property int mapZoom: 13
  property var mapTiles: []
  property var tileCache: ({})
  property var tileQueue: []
  property var visibleStops: []
  property var overlayGeo: []
  property var overlayStops: []

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

  onHostWidgetChanged: {
    root.updateTiles()
    root.loadMapMarkers()
  }

  // hostWidget.helperPath can still be "" right when the panel opens (the
  // bar widget registry populates it asynchronously on shell startup), so
  // the calls above silently no-op. Retry everything once it lands instead
  // of leaving the map blank and stale "helper unavailable" text on screen.
  readonly property string helperPath: hostWidget ? hostWidget.helperPath : ""
  onHelperPathChanged: {
    if (helperPath === "") return
    root.updateTiles()
    root.loadMapMarkers()
    if (root.searchError === "helper unavailable") root.runSearch(searchField.text)
    if (root.lineError === "helper unavailable") root.runLineSearch(searchField.text)
    if (root.previewError === "helper unavailable" && root.previewCode !== "")
      root.previewStop(root.previewCode, root.previewDescr)
  }

  function updateTiles() {
    var n = Math.pow(2, mapZoom)
    var cx = Model.lonToTileX(mapLng, mapZoom)
    var cy = Model.latToTileY(mapLat, mapZoom)
    var x0 = Math.floor(cx - 220 / 256), x1 = Math.floor(cx + 220 / 256)
    var y0 = Math.floor(cy - 260 / 256), y1 = Math.floor(cy + 260 / 256)
    var tiles = []
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        if (y < 0 || y >= n) continue
        var wx = ((x % n) + n) % n
        var key = mapZoom + "/" + wx + "/" + y
        var path = root.tileCache[key] || ""
        if (path === "") root.queueTileFetch(key)
        tiles.push({
          path: path,
          px: (x - cx) * 256 + 220,
          py: (y - cy) * 256 + 260
        })
      }
    }
    root.mapTiles = tiles
  }

  function queueTileFetch(key) {
    if (root.tileCache.hasOwnProperty(key)) return
    if (root.tileQueue.indexOf(key) !== -1) return
    root.tileQueue = root.tileQueue.concat([key])
    tileFetchDebounce.restart()
  }

  function fetchQueuedTiles() {
    if (!hostWidget || !hostWidget.helperPath) return
    if (root.tileQueue.length === 0) return
    if (tileProc.running) {
      tileFetchDebounce.restart()
      return
    }
    var batch = root.tileQueue
    root.tileQueue = []
    var args = [hostWidget.helperPath, "map-tiles"]
    for (var i = 0; i < batch.length; i++) {
      args.push("--tile")
      args.push(batch[i])
    }
    tileProc.command = args
    tileProc.running = true
  }

  function projectStops(list) {
    var out = []
    for (var i = 0; i < list.length && out.length < 500; i++) {
      var s = list[i]
      if (s.lat === null || s.lat === undefined || s.lng === null || s.lng === undefined) continue
      var p = Model.geoToPixel(s.lat, s.lng, mapLat, mapLng, mapZoom, 440, 520)
      if (p.x < -10 || p.x > 450 || p.y < -10 || p.y > 530) continue
      out.push({ code: s.stop_code, descr: s.descr, px: p.x, py: p.y })
    }
    return out
  }

  function updateMarkers() {
    root.visibleStops = projectStops(geoCache)
    root.overlayStops = projectStops(overlayGeo)
  }

  function panMapBy(dx, dy) {
    var z = mapZoom
    var cx = Model.lonToTileX(mapLng, z) * 256 + dx
    var cy = Model.latToTileY(mapLat, z) * 256 + dy
    mapLng = Model.tileXToLon(cx / 256, z)
    mapLat = Model.tileYToLat(cy / 256, z)
    updateTiles()
  }

  function zoomMap(delta) {
    mapZoom = Math.max(2, Math.min(18, mapZoom + delta))
    updateTiles()
    updateMarkers()
  }

  function recenterSyntagma() {
    mapLat = 37.9755
    mapLng = 23.7348
    mapZoom = 13
    updateTiles()
    updateMarkers()
  }

  function focusStopOnMap(code) {
    for (var i = 0; i < geoCache.length; i++) {
      if (geoCache[i].stop_code === code && geoCache[i].lat !== null) {
        mapLat = geoCache[i].lat
        mapLng = geoCache[i].lng
        mapZoom = Math.max(mapZoom, 15)
        updateTiles()
        updateMarkers()
        return
      }
    }
  }

  function tapMapAt(px, py) {
    var best = null
    var bestD = 24 * 24
    for (var i = 0; i < visibleStops.length; i++) {
      var d = Math.pow(visibleStops[i].px - px, 2) + Math.pow(visibleStops[i].py - py, 2)
      if (d < bestD) {
        bestD = d
        best = visibleStops[i]
      }
    }
    if (best) root.previewStop(best.code, best.descr)
  }

  function fitZoom(lat0, lng0, lat1, lng1) {
    for (var z = 18; z >= 2; z--) {
      var w = Math.abs(Model.lonToTileX(lng1, z) - Model.lonToTileX(lng0, z)) * 256
      var h = Math.abs(Model.latToTileY(lat1, z) - Model.latToTileY(lat0, z)) * 256
      if (w <= 400 && h <= 480) return z
    }
    return 2
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
    root.overlayGeo = []
    root.overlayStops = []
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

  // Coalesces the tile requests a drag/zoom generates into one batched
  // `map-tiles` call instead of a process per tile.
  Timer {
    id: tileFetchDebounce
    interval: 120
    repeat: false
    onTriggered: root.fetchQueuedTiles()
  }

  Process {
    id: tileProc
    stdout: StdioCollector {
      id: tileOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          var payload = JSON.parse(tileOut.text)
          var results = (payload && payload.tiles) || []
          var cache = Object.assign({}, root.tileCache)
          for (var i = 0; i < results.length; i++) {
            var t = results[i]
            if (t && t.path) cache[t.z + "/" + t.x + "/" + t.y] = "file://" + t.path
          }
          root.tileCache = cache
        } catch (e) {
          // leave the failed keys uncached; the next pan/zoom re-queues them
        }
      }
      if (root.tileQueue.length > 0) tileFetchDebounce.restart()
      root.updateTiles()
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
        root.updateMarkers()
        root.mapState = stops.length + " stations"
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
        var geo = []
        var routes = (payload && payload.routes) || []
        for (var r = 0; r < routes.length; r++) {
          var stops = routes[r].stops || []
          for (var i = 0; i < stops.length; i++) {
            geo.push(stops[i])
          }
        }
        root.overlayGeo = geo
        var lat0 = 90, lng0 = 180, lat1 = -90, lng1 = -180
        var found = false
        for (var i = 0; i < geo.length; i++) {
          if (geo[i].lat === null || geo[i].lat === undefined) continue
          found = true
          lat0 = Math.min(lat0, geo[i].lat)
          lat1 = Math.max(lat1, geo[i].lat)
          lng0 = Math.min(lng0, geo[i].lng)
          lng1 = Math.max(lng1, geo[i].lng)
        }
        if (found) {
          mapLat = (lat0 + lat1) / 2
          mapLng = (lng0 + lng1) / 2
          mapZoom = fitZoom(lat0, lng0, lat1, lng1)
          updateTiles()
        }
        root.updateMarkers()
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

      Row {
        width: parent.width
        spacing: 16

        Text {
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: 14
          font.bold: true
          text: "＋"

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.zoomMap(1)
          }
        }

        Text {
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: 14
          font.bold: true
          text: "－"

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.zoomMap(-1)
          }
        }

        Text {
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: 12
          font.underline: true
          text: "⌖ Syntagma"

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.recenterSyntagma()
          }
        }

        Text {
          color: root.contentForeground
          opacity: 0.6
          font.family: root.contentFontFamily
          font.pixelSize: 12
          text: "drag to pan · scroll to zoom · tap a dot"
        }
      }

      Item {
        id: mapView
        width: 440
        height: 520
        clip: true

        MouseArea {
          id: mapPan
          anchors.fill: parent
          property real pressX: 0
          property real pressY: 0
          property bool panning: false
          onPressed: function(e) {
            pressX = e.x
            pressY = e.y
            panning = false
          }
          onPositionChanged: function(e) {
            if (!pressed) return
            if (!panning && Math.hypot(e.x - pressX, e.y - pressY) < 4) return
            panning = true
            root.panMapBy(pressX - e.x, pressY - e.y)
            pressX = e.x
            pressY = e.y
          }
          onReleased: function(e) {
            if (panning) {
              panning = false
              root.updateMarkers()
            } else {
              root.tapMapAt(e.x, e.y)
            }
          }
          onWheel: function(w) {
            if (w.angleDelta.y > 0) root.zoomMap(1)
            else root.zoomMap(-1)
          }
        }

        Repeater {
          model: root.mapTiles

          Image {
            required property var modelData
            x: modelData.px
            y: modelData.py
            width: 256
            height: 256
            source: modelData.path
            asynchronous: true
          }
        }

        Repeater {
          model: root.overlayStops

          Rectangle {
            required property var modelData
            x: modelData.px - 7
            y: modelData.py - 7
            width: 14
            height: 14
            radius: 7
            color: "#b3541e"
            border.color: "white"
            border.width: 2

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.previewStop(modelData.code, "")
            }
          }
        }

        Repeater {
          model: root.visibleStops

          Rectangle {
            required property var modelData
            x: modelData.px - 5
            y: modelData.py - 5
            width: 10
            height: 10
            radius: 5
            color: "white"
            border.color: "#333333"
            border.width: 1
            visible: root.overlayStops.length === 0

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.previewStop(modelData.code, modelData.descr)
            }
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
          ? "Line " + root.overlayDescr + " — tap to clear"
          : root.mapState
        visible: text !== ""

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          enabled: root.overlayLine !== ""
          onClicked: root.clearLineOverlay()
        }
      }

      Component.onCompleted: root.updateTiles()
    }
  }
}
