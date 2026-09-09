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
    onTriggered: root.runSearch(searchField.text)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(400)
    contentHeight: panel.fittedContentHeight(board.implicitHeight + 24)

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
      anchors.fill: parent
      anchors.margins: 12
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
                onClicked: root.previewStop(modelData.stop, "")
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
                onClicked: root.previewStop(modelData.stop_code, modelData.descr || "")
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
    }
  }
}
