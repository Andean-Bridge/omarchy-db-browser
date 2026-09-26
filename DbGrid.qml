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
  readonly property int firstVisibleColumn: Math.max(0, Math.floor(horizontal.contentX / cellWidth) - 1)
  readonly property int lastVisibleColumn: Math.min(columns.length, Math.ceil((horizontal.contentX + horizontal.width) / cellWidth) + 1)

  onColumnsChanged: horizontal.contentX = 0

  function scrollHorizontally(delta) {
    var maxX = Math.max(0, horizontal.contentWidth - horizontal.width)
    horizontal.contentX = Math.max(0, Math.min(maxX, horizontal.contentX + delta))
  }

  function handleGridWheel(event) {
    var horizontalDelta = event.pixelDelta.x || event.angleDelta.x * 0.6
    if (!horizontalDelta && (event.modifiers & Qt.ShiftModifier))
      horizontalDelta = event.pixelDelta.y || event.angleDelta.y * 0.6
    if (horizontalDelta) {
      scrollHorizontally(-horizontalDelta)
    } else {
      var verticalDelta = event.pixelDelta.y || event.angleDelta.y * 0.6
      if (!verticalDelta) { event.accepted = false; return }
      var maxY = Math.max(0, body.contentHeight - body.height)
      body.contentY = Math.max(0, Math.min(maxY, body.contentY - verticalDelta))
    }
    event.accepted = true
  }

  function visibleColumnIndexes() {
    var indexes = []
    for (var i = firstVisibleColumn; i < lastVisibleColumn; i++) indexes.push(i)
    return indexes
  }

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
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: horizontalControls.visible ? horizontalControls.top : parent.bottom
        visible: grid.columns.length > 0 && !grid.error
        contentWidth: grid.tableWidth
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
          width: grid.tableWidth
          height: horizontal.height
          spacing: 0

          Row {
            width: parent.width
            height: 42
            Item { width: grid.firstVisibleColumn * grid.cellWidth; height: 42 }
            Repeater {
              model: grid.visibleColumnIndexes()
              delegate: Rectangle {
                id: headerCell
                required property int modelData
                width: grid.cellWidth
                height: 42
                clip: true
                color: Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.045)
                border.width: 1
                border.color: grid.line
                Text {
                  anchors.fill: parent
                  anchors.leftMargin: 14
                  anchors.rightMargin: 10
                  verticalAlignment: Text.AlignVCenter
                  text: grid.columnName(grid.columns[headerCell.modelData])
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
            WheelHandler {
              target: null
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: function(event) { grid.handleGridWheel(event) }
            }
            delegate: Row {
              id: rowDelegate
              required property var modelData
              required property int index
              property var values: modelData
              width: grid.tableWidth
              height: 39
              Item { width: grid.firstVisibleColumn * grid.cellWidth; height: 39 }
              Repeater {
                model: grid.visibleColumnIndexes()
                delegate: Rectangle {
                  id: bodyCell
                  required property int modelData
                  width: grid.cellWidth
                  height: 39
                  clip: true
                  color: rowDelegate.index % 2 === 0 ? "transparent" : grid.stripe
                  border.width: 1
                  border.color: grid.line
                  Text {
                    id: cellTextItem
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 10
                    verticalAlignment: Text.AlignVCenter
                    text: grid.cellText(rowDelegate.values[bodyCell.modelData])
                    textFormat: Text.PlainText
                    color: rowDelegate.values[bodyCell.modelData] === null ? grid.mutedInk : grid.ink
                    font.family: Style.font.family
                    font.pixelSize: Math.max(14, Style.font.body)
                    elide: Text.ElideRight
                    ToolTip {
                      visible: cellHover.hovered && cellTextItem.truncated
                      delay: 400
                      contentItem: Text {
                        text: cellTextItem.text.length > 2000 ? cellTextItem.text.slice(0, 2000) + "…" : cellTextItem.text
                        textFormat: Text.PlainText
                        color: grid.ink
                        font.family: Style.font.family
                        font.pixelSize: Math.max(13, Style.font.bodySmall)
                        wrapMode: Text.WrapAnywhere
                        width: Math.min(600, implicitWidth)
                      }
                    }
                    HoverHandler { id: cellHover }
                  }
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: horizontalControls
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? 34 : 0
        visible: horizontal.visible && horizontal.contentWidth > horizontal.width + 1
        color: grid.surface
        border.width: 1
        border.color: grid.line
        z: 2

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 8
          anchors.rightMargin: 8
          spacing: 8

          Button {
            id: scrollLeft
            text: "◀"
            Layout.preferredWidth: 34
            Layout.preferredHeight: 26
            enabled: horizontal.contentX > 0
            onClicked: grid.scrollHorizontally(-Math.max(grid.cellWidth, horizontal.width * 0.75))
            background: Rectangle { radius: 5; color: scrollLeft.hovered ? grid.stripe : grid.surface; border.width: 1; border.color: grid.line }
            contentItem: Text { text: scrollLeft.text; color: scrollLeft.enabled ? grid.ink : grid.mutedInk; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
          }
          Text {
            text: "Scroll columns"
            color: grid.mutedInk
            font.family: Style.font.family
            font.pixelSize: Math.max(12, Style.font.caption)
          }
          Slider {
            id: horizontalSlider
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            from: 0
            to: Math.max(0, horizontal.contentWidth - horizontal.width)
            value: horizontal.contentX
            onMoved: horizontal.contentX = value
            background: Rectangle {
              x: horizontalSlider.leftPadding
              y: horizontalSlider.topPadding + horizontalSlider.availableHeight / 2 - height / 2
              width: horizontalSlider.availableWidth
              height: 8
              radius: 4
              color: Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.28)
            }
            handle: Rectangle {
              width: Math.max(48, Math.min(horizontalSlider.availableWidth,
                horizontalSlider.availableWidth * horizontal.width / Math.max(1, horizontal.contentWidth)))
              height: 18
              radius: 8
              x: horizontalSlider.leftPadding + horizontalSlider.visualPosition * (horizontalSlider.availableWidth - width)
              y: horizontalSlider.topPadding + horizontalSlider.availableHeight / 2 - height / 2
              color: horizontalSlider.pressed ? Color.accent : Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.78)
            }
          }
          Button {
            id: scrollRight
            text: "▶"
            Layout.preferredWidth: 34
            Layout.preferredHeight: 26
            enabled: horizontal.contentX < horizontal.contentWidth - horizontal.width - 1
            onClicked: grid.scrollHorizontally(Math.max(grid.cellWidth, horizontal.width * 0.75))
            background: Rectangle { radius: 5; color: scrollRight.hovered ? grid.stripe : grid.surface; border.width: 1; border.color: grid.line }
            contentItem: Text { text: scrollRight.text; color: scrollRight.enabled ? grid.ink : grid.mutedInk; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
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
