pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

// A bounded, virtualized result grid. Editing intentionally waits for v2.
Item {
  id: grid
  property var columns: []
  property var rows: []
  property bool busy: false
  property bool hasMore: false
  property int offset: 0
  property int limit: 200
  property string error: ""
  property string emptyText: "No rows returned"
  property bool paged: false
  signal nextPage()
  signal previousPage()

  readonly property color ink: Color.popups.text
  readonly property color mutedInk: Qt.rgba(ink.r, ink.g, ink.b, 0.58)
  readonly property color line: Qt.rgba(ink.r, ink.g, ink.b, 0.13)
  readonly property color stripe: Qt.rgba(ink.r, ink.g, ink.b, 0.025)
  readonly property color surface: Qt.tint(Color.popups.background, Qt.rgba(ink.r, ink.g, ink.b, 0.035))
  readonly property int cellWidth: Math.max(160, Math.min(250, width / Math.max(1, columns.length)))
  readonly property int tableWidth: Math.max(width, columns.length * cellWidth)

  function columnName(column) {
    return typeof column === "string" ? column : String((column || {}).name || "")
  }
  function cellText(value) {
    if (value === null || value === undefined) return "NULL"
    if (typeof value === "object") return JSON.stringify(value)
    return String(value)
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    Rectangle {
      id: tableFrame
      Layout.fillWidth: true
      Layout.fillHeight: true
      color: grid.surface
      radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 8) : 5
      border.width: 1
      border.color: grid.line
      clip: true

      Flickable {
        id: horizontal
        anchors.fill: parent
        anchors.bottomMargin: horizontalBar.visible ? horizontalBar.height : 0
        visible: grid.columns.length > 0 && !grid.error
        contentWidth: grid.tableWidth
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.horizontal: ScrollBar {
          id: horizontalBar
          parent: tableFrame
          width: tableFrame.width
          y: tableFrame.height - height
          height: 14
          padding: 2
          policy: ScrollBar.AlwaysOn
          visible: horizontal.visible && horizontal.contentWidth > horizontal.width
          active: true
          background: Rectangle {
            color: grid.surface
            border.width: 1
            border.color: grid.line
          }
          contentItem: Rectangle {
            radius: height / 2
            color: horizontalBar.pressed ? Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.8)
              : horizontalBar.hovered ? Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.65)
              : Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.45)
          }
        }

        Column {
          width: grid.tableWidth
          height: horizontal.height
          spacing: 0

          Row {
            width: parent.width
            height: 42
            Repeater {
              model: grid.columns
              delegate: Rectangle {
                id: headerCell
                required property var modelData
                width: grid.cellWidth
                height: 42
                color: Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.045)
                border.width: 1
                border.color: grid.line
                Text {
                  anchors.fill: parent
                  anchors.leftMargin: 14
                  anchors.rightMargin: 10
                  verticalAlignment: Text.AlignVCenter
                  text: grid.columnName(headerCell.modelData)
                  textFormat: Text.PlainText
                  color: grid.ink
                  font.family: Style.font.family
                  font.pixelSize: Math.max(14, Style.font.body)
                  font.bold: true
                  elide: Text.ElideRight
                }
              }
            }
          }

          ListView {
            id: body
            width: parent.width
            height: parent.height - 42
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: grid.rows
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: Row {
              id: rowDelegate
              required property var modelData
              required property int index
              property var values: modelData
              width: grid.tableWidth
              height: 39
              Repeater {
                model: grid.columns
                delegate: Rectangle {
                  id: bodyCell
                  required property int index
                  width: grid.cellWidth
                  height: 39
                  color: rowDelegate.index % 2 === 0 ? "transparent" : grid.stripe
                  border.width: 1
                  border.color: grid.line
                  Text {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 10
                    verticalAlignment: Text.AlignVCenter
                    text: grid.cellText(rowDelegate.values[bodyCell.index])
                    textFormat: Text.PlainText
                    color: rowDelegate.values[bodyCell.index] === null ? grid.mutedInk : grid.ink
                    font.family: Style.font.family
                    font.pixelSize: Math.max(14, Style.font.body)
                    elide: Text.ElideRight
                    ToolTip.visible: cellHover.hovered && truncated
                    ToolTip.text: text
                    HoverHandler { id: cellHover }
                  }
                }
              }
            }
          }
        }
      }

      Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 420)
        spacing: 7
        visible: grid.busy || grid.error !== "" || grid.columns.length === 0 || grid.rows.length === 0
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: grid.busy ? "Loading rows…" : grid.error ? "Could not load rows" : grid.columns.length === 0 ? "No results yet" : grid.emptyText
          color: grid.ink
          font.family: Style.font.family
          font.pixelSize: Math.max(16, Style.font.title)
          font.bold: true
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          visible: grid.error !== ""
          text: grid.error
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Math.max(14, Style.font.body)
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.preferredHeight: grid.paged ? 40 : 0
      visible: grid.paged
      spacing: 10
      Text {
        text: grid.rows.length === 0 ? "0 rows" : (grid.offset + 1) + "–" + (grid.offset + grid.rows.length) + (grid.hasMore ? " · more available" : "")
        color: grid.mutedInk
        font.family: Style.font.family
        font.pixelSize: Math.max(12, Style.font.caption)
      }
      Item { Layout.fillWidth: true }
      Button { text: "Previous"; enabled: !grid.busy && grid.offset > 0; onClicked: grid.previousPage() }
      Button { text: "Next"; enabled: !grid.busy && grid.hasMore; onClicked: grid.nextPage() }
    }
  }
}
