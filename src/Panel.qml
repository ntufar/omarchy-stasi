import QtQuick
import Quickshell
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
        text: root.stopCode === "" ? "Stasi" : "Στάση " + root.stopCode
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        text: root.error !== "" ? root.error : Model.formatAge(root.fetchedAt, root.tick)
        visible: text !== ""
      }

      Repeater {
        model: root.arrivals

        Text {
          required property var modelData
          width: board.width
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: 20
          font.bold: true
          wrapMode: Text.WordWrap
          text: Model.rowLabel(modelData, root.fetchedAt, root.tick)
        }
      }

      Text {
        width: parent.width
        color: root.contentForeground
        opacity: 0.6
        font.family: root.contentFontFamily
        font.pixelSize: 12
        wrapMode: Text.WordWrap
        text: root.stopCode === ""
          ? "Set a stop: omarchy bar set io.github.ntufar.stasi stop <code>"
          : (root.arrivals.length === 0 && root.error === "" ? "No live arrivals." : "")
        visible: text !== ""
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
            if (root.hostWidget) root.hostWidget.refresh()
          }
        }
      }
    }
  }
}
