pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Theme

// A bounded, virtualized result grid with viewport-anchored scrolling.
Item {
  id: grid
  property var columns: []
  // Widths are remembered per tab and result shape for this workbench session.
  property string layoutKey: ""
  property var savedColumnWidths: ({})
  property var rows: []
  property var cellRefs: []
  property bool busy: false
  property bool hasMore: false
  property int offset: 0
  property int limit: 200
  property string error: ""
  property string emptyText: "No rows returned"
  property bool paged: false
  property int selectedRow: -1
  property int selectedColumn: -1
  property var editableColumns: []
  property var sortableColumns: []
  property var sort: null
  signal sortRequested(string column)
  signal editCell(var cell)
  signal copyRow(int row)
  signal copyResults()
  signal nextPage()
  signal previousPage()
  signal viewCell(var cell)
  signal copyCell(var cell)
  signal copyColumnName(string name)

  readonly property color ink: Theme.Color.popups.text
  readonly property color mutedInk: Qt.rgba(ink.r, ink.g, ink.b, 0.58)
  readonly property color line: Qt.rgba(ink.r, ink.g, ink.b, 0.13)
  readonly property color stripe: Qt.rgba(ink.r, ink.g, ink.b, 0.025)
  readonly property color surface: Qt.tint(Theme.Color.popups.background, Qt.rgba(ink.r, ink.g, ink.b, 0.035))
  readonly property int cellWidth: Math.max(160, Math.min(250, Math.floor(horizontal.width / Math.max(1, columns.length))))
  readonly property string columnLayoutKey: JSON.stringify([layoutKey, columns.map(columnName)])
  readonly property var columnWidths: savedColumnWidths[columnLayoutKey] || []
  readonly property var columnOffsets: {
    var offsets = [0]
    for (var i = 0; i < columns.length; i++) offsets.push(offsets[i] + columnWidth(i))
    return offsets
  }
  readonly property int tableWidth: Math.max(horizontal.width, columnOffsets[columns.length] || 0)
  readonly property int firstVisibleColumn: Math.max(0, columnAt(horizontal.contentX) - 1)
  readonly property int lastVisibleColumn: Math.min(columns.length, columnAt(horizontal.contentX + horizontal.width) + 2)

  onLayoutKeyChanged: horizontal.contentX = 0
  onTableWidthChanged: Qt.callLater(function() { grid.scrollHorizontally(0) })

  function columnWidth(index) { return columnWidths[index] || cellWidth }
  function columnOffset(index) { return columnOffsets[index] || 0 }
  function columnAt(x) {
    var low = 0, high = columns.length
    while (low < high) {
      var middle = Math.floor((low + high) / 2)
      if (columnOffsets[middle + 1] <= x) low = middle + 1
      else high = middle
    }
    return Math.min(columns.length - 1, low)
  }
  function resizeColumn(index, width) {
    if (index < 0 || index >= columns.length) return
    var widths = columnWidths.slice()
    widths[index] = Math.round(Math.max(72, Math.min(1600, width)))
    var saved = Object.assign({}, savedColumnWidths)
    saved[columnLayoutKey] = widths
    savedColumnWidths = saved
  }
  function fitColumn(index) {
    if (index < 0 || index >= columns.length) return
    headerMetrics.text = columnName(columns[index]) + " ↑"
    var width = headerMetrics.advanceWidth
    // Bound measurement work even when a query returns many rows or large values.
    for (var i = 0; i < Math.min(rows.length, 500); i++) {
      valueMetrics.text = cellText(rows[i][index]).slice(0, 512).split("\n")[0]
      width = Math.max(width, valueMetrics.advanceWidth)
    }
    resizeColumn(index, Math.min(800, Math.ceil(width) + 28))
  }
  TextMetrics {
    id: headerMetrics
    font.family: Style.font.family
    font.pixelSize: Math.max(14, Style.font.body)
    font.bold: true
  }
  TextMetrics {
    id: valueMetrics
    font.family: Style.font.family
    font.pixelSize: Math.max(14, Style.font.body)
  }

  onColumnsChanged: {
    horizontal.contentX = 0
    selectedRow = -1
    selectedColumn = -1
  }
  onRowsChanged: {
    body.contentY = 0
    selectedRow = -1
    selectedColumn = -1
  }
  onOffsetChanged: {
    selectedRow = -1
    selectedColumn = -1
  }

  focus: true
  Keys.onPressed: function(event) {
    if (grid.rows.length === 0 || grid.columns.length === 0) return
    if (grid.selectedRow < 0 || grid.selectedColumn < 0) grid.selectCell(0, 0)
    var row = grid.selectedRow
    var column = grid.selectedColumn
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_C) {
      if (event.modifiers & Qt.ShiftModifier) grid.copyRow(row)
      else grid.copyCell(grid.selectedCell())
    } else if (event.key === Qt.Key_F2 && grid.canEditSelectedRow()) {
      grid.editCell(grid.selectedCell())
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      grid.viewCell(grid.selectedCell())
    } else if (event.key === Qt.Key_Left) column--
    else if (event.key === Qt.Key_Right) column++
    else if (event.key === Qt.Key_Up) row--
    else if (event.key === Qt.Key_Down) row++
    else if (event.key === Qt.Key_PageDown) row += Math.max(1, Math.floor(body.height / 39))
    else if (event.key === Qt.Key_PageUp) row -= Math.max(1, Math.floor(body.height / 39))
    else if (event.key === Qt.Key_Home) { column = 0; if (event.modifiers & Qt.ControlModifier) row = 0 }
    else if (event.key === Qt.Key_End) { column = grid.columns.length - 1; if (event.modifiers & Qt.ControlModifier) row = grid.rows.length - 1 }
    else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      column += (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1
      if (column >= grid.columns.length) { column = 0; row++ }
      if (column < 0) { column = grid.columns.length - 1; row-- }
    } else return
    grid.selectCell(Math.max(0, Math.min(grid.rows.length - 1, row)), Math.max(0, Math.min(grid.columns.length - 1, column)))
    grid.ensureSelectedVisible()
    event.accepted = true
  }

  function ensureSelectedVisible() {
    if (selectedRow * 39 < body.contentY) body.contentY = selectedRow * 39
    else if ((selectedRow + 1) * 39 > body.contentY + body.height) body.contentY = Math.min(Math.max(0, body.contentHeight - body.height), (selectedRow + 1) * 39 - body.height)
    var left = columnOffset(selectedColumn)
    var right = columnOffset(selectedColumn + 1)
    if (left < horizontal.contentX || right - left > horizontal.width) horizontal.contentX = left
    else if (right > horizontal.contentX + horizontal.width) scrollHorizontally(right - horizontal.width - horizontal.contentX)
  }
  function canEditSelectedRow() {
    return !busy && selectedRow >= 0 && selectedRow < rows.length && editableColumns.length > 0
  }
  function canEditSelectedCell() {
    return !busy && selectedRow >= 0 && selectedColumn >= 0 && editableColumns.indexOf(columnName(columns[selectedColumn])) >= 0
  }

  function selectCell(row, column) {
    selectedRow = row
    selectedColumn = column
    forceActiveFocus()
  }

  function selectedCell() {
    if (selectedRow < 0 || selectedColumn < 0 || selectedRow >= rows.length || selectedColumn >= columns.length) return null
    var row = rows[selectedRow]
    if (!row || selectedColumn >= row.length) return null
    var rawValue = row[selectedColumn]
    var ref = null
    for (var i = 0; i < cellRefs.length; i++) {
      if (cellRefs[i].row === selectedRow && cellRefs[i].column === selectedColumn) {
        ref = cellRefs[i]
        break
      }
    }
    // Fail closed if an older worker supplied a preview without cellRefs.
    var legacyPreview = !ref && typeof rawValue === "string" &&
      ((rawValue.length === 4097 && rawValue.endsWith("…")) || /^0x[0-9a-f]{8192}… \(\d+ bytes\)$/.test(rawValue))
    return {
      row: selectedRow,
      displayRow: offset + selectedRow + 1,
      column: selectedColumn,
      columnName: columnName(columns[selectedColumn]),
      preview: cellText(rawValue),
      complete: ref ? !!ref.complete : !legacyPreview,
      handle: ref ? ref.handle : null,
      byteLength: ref ? ref.byteLength : null
    }
  }
  function canCopySelectedCell() {
    var selected = selectedCell()
    return !!selected && (selected.complete || !!selected.handle)
  }

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

  component CellAction: MenuItem {
    id: action
    implicitHeight: 38
    contentItem: Text {
      text: action.text
      textFormat: Text.PlainText
      color: action.enabled ? grid.ink : grid.mutedInk
      font.family: Style.font.family
      font.pixelSize: Math.max(13, Style.font.bodySmall)
      verticalAlignment: Text.AlignVCenter
      leftPadding: 12
    }
    background: Rectangle { color: action.highlighted ? grid.stripe : grid.surface }
  }

  Menu {
    id: cellMenu
    background: Rectangle { color: grid.surface; border.width: 1; border.color: grid.line; radius: 5 }
    CellAction {
      text: "Edit row… (F2)"
      visible: grid.editableColumns.length > 0
      height: visible ? implicitHeight : 0
      enabled: grid.canEditSelectedRow()
      onTriggered: grid.editCell(grid.selectedCell())
    }
    CellAction {
      text: "Copy row (Ctrl+Shift+C)"
      enabled: grid.selectedRow >= 0 && !grid.busy
      onTriggered: grid.copyRow(grid.selectedRow)
    }
    CellAction {
      text: "Copy results with headers"
      enabled: grid.rows.length > 0 && !grid.busy
      onTriggered: grid.copyResults()
    }
    CellAction {
      text: "View value"
      enabled: grid.selectedRow >= 0
      onTriggered: grid.viewCell(grid.selectedCell())
    }
    CellAction {
      text: "Copy value"
      enabled: grid.canCopySelectedCell()
      onTriggered: grid.copyCell(grid.selectedCell())
    }
    CellAction {
      text: "Copy column name"
      enabled: grid.selectedColumn >= 0
      onTriggered: grid.copyColumnName(grid.columnName(grid.columns[grid.selectedColumn]))
    }
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
        objectName: "gridHorizontalViewport"
        anchors.left: parent.left
        anchors.right: verticalScroll.left
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
            Item { width: grid.columnOffset(grid.firstVisibleColumn); height: 42 }
            Repeater {
              model: grid.visibleColumnIndexes()
              delegate: Rectangle {
                id: headerCell
                required property int modelData
                objectName: "gridHeader_" + modelData
                width: grid.columnWidth(modelData)
                height: 42
                clip: true
                color: Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.045)
                border.width: 1
                border.color: grid.line
                readonly property string columnName: grid.columnName(grid.columns[headerCell.modelData])
                readonly property bool sortable: !grid.busy && grid.sortableColumns.indexOf(columnName) >= 0
                Accessible.role: sortable ? Accessible.Button : Accessible.StaticText
                Accessible.name: columnName + (sortable ? ": sort column" : "")
                activeFocusOnTab: sortable
                Keys.onReturnPressed: if (sortable) grid.sortRequested(columnName)
                Keys.onSpacePressed: if (sortable) grid.sortRequested(columnName)
                ToolTip.visible: headerMouse.containsMouse && sortable
                ToolTip.delay: 500
                ToolTip.text: "Sort " + columnName + (grid.sort && grid.sort.column === columnName ? grid.sort.direction === "asc" ? " descending" : ": restore default order" : " ascending")
                MouseArea {
                  id: headerMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: headerCell.sortable
                  cursorShape: Qt.PointingHandCursor
                  onClicked: grid.sortRequested(headerCell.columnName)
                }
                Text {
                  anchors.fill: parent
                  anchors.leftMargin: 14
                  anchors.rightMargin: 10
                  verticalAlignment: Text.AlignVCenter
                  text: grid.columnName(grid.columns[headerCell.modelData]) + (grid.sort && grid.sort.column === grid.columnName(grid.columns[headerCell.modelData]) ? (grid.sort.direction === "asc" ? " ↑" : " ↓") : "")
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
            objectName: "gridRowsViewport"
            width: parent.width
            height: parent.height - 42
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: grid.rows
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
              Item { width: grid.columnOffset(grid.firstVisibleColumn); height: 39 }
              Repeater {
                model: grid.visibleColumnIndexes()
                delegate: Rectangle {
                  id: bodyCell
                  required property int modelData
                  objectName: "gridCell_" + rowDelegate.index + "_" + modelData
                  width: grid.columnWidth(modelData)
                  height: 39
                  clip: true
                  color: grid.selectedRow === rowDelegate.index && grid.selectedColumn === bodyCell.modelData
                    ? Qt.rgba(Theme.Color.accent.r, Theme.Color.accent.g, Theme.Color.accent.b, 0.24)
                    : rowDelegate.index % 2 === 0 ? "transparent" : grid.stripe
                  border.width: 1
                  border.color: grid.selectedRow === rowDelegate.index && grid.selectedColumn === bodyCell.modelData ? Theme.Color.accent : grid.line
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
                  }
                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                      grid.selectCell(rowDelegate.index, bodyCell.modelData)
                      if (mouse.button === Qt.RightButton) {
                        var point = bodyCell.mapToItem(grid, mouse.x, mouse.y)
                        cellMenu.x = point.x
                        cellMenu.y = point.y
                        cellMenu.popup()
                      }
                    }
                    onDoubleClicked: function(mouse) {
                      if (mouse.button !== Qt.LeftButton) return
                      grid.selectCell(rowDelegate.index, bodyCell.modelData)
                      if (grid.canEditSelectedCell()) grid.editCell(grid.selectedCell())
                      else grid.viewCell(grid.selectedCell())
                    }
                    onWheel: function(wheel) { wheel.accepted = false }
                  }
                }
              }
            }
          }
        }
      }

      // This viewport-owned hit area keeps the pointer grab while virtualized
      // header delegates are rebuilt during a resize. Other header clicks pass through.
      MouseArea {
        id: columnResize
        objectName: "gridColumnResize"
        anchors.left: horizontal.left
        anchors.top: horizontal.top
        width: horizontal.width
        height: 42
        z: 1
        visible: horizontal.visible
        hoverEnabled: true
        preventStealing: true
        property int resizingColumn: -1
        property real pressX: 0
        property real pressWidth: 0
        property int hoveredColumn: boundaryAt(mouseX)
        function boundaryAt(x) {
          var contentX = x + horizontal.contentX
          var index = grid.columnAt(contentX)
          if (index < 0) return -1
          if (Math.abs(contentX - grid.columnOffset(index + 1)) <= 5) return index
          if (index > 0 && Math.abs(contentX - grid.columnOffset(index)) <= 5) return index - 1
          return -1
        }
        cursorShape: resizingColumn >= 0 || hoveredColumn >= 0 ? Qt.SizeHorCursor
          : grid.sortableColumns.indexOf(grid.columnName(grid.columns[grid.columnAt(mouseX + horizontal.contentX)])) >= 0 && !grid.busy ? Qt.PointingHandCursor : Qt.ArrowCursor
        onPressed: function(mouse) {
          resizingColumn = boundaryAt(mouse.x)
          if (resizingColumn < 0) { mouse.accepted = false; return }
          horizontal.cancelFlick()
          pressX = mouse.x
          pressWidth = grid.columnWidth(resizingColumn)
        }
        onPositionChanged: function(mouse) {
          if (pressed && resizingColumn >= 0) grid.resizeColumn(resizingColumn, pressWidth + mouse.x - pressX)
        }
        onReleased: resizingColumn = -1
        onCanceled: resizingColumn = -1
        onDoubleClicked: function(mouse) { grid.fitColumn(boundaryAt(mouse.x)) }
        ToolTip.visible: containsMouse && hoveredColumn >= 0 && !pressed
        ToolTip.delay: 600
        ToolTip.text: "Drag to resize · Double-click to fit"
        Rectangle {
          visible: columnResize.containsMouse && columnResize.hoveredColumn >= 0 || columnResize.resizingColumn >= 0
          x: grid.columnOffset((columnResize.resizingColumn >= 0 ? columnResize.resizingColumn : columnResize.hoveredColumn) + 1) - horizontal.contentX - 1
          width: 2
          height: parent.height
          color: Theme.Color.accent
        }
      }

      ScrollBar {
        id: verticalScroll
        objectName: "gridVerticalScrollBar"
        anchors.top: parent.top
        anchors.topMargin: 42
        anchors.bottom: horizontalControls.visible ? horizontalControls.top : parent.bottom
        anchors.right: parent.right
        width: 14
        orientation: Qt.Vertical
        policy: ScrollBar.AlwaysOn
        visible: horizontal.visible && body.contentHeight > body.height
        minimumSize: Math.min(1, 28 / Math.max(1, height))
        size: body.visibleArea.heightRatio
        position: body.visibleArea.yPosition
        active: hovered || pressed || body.moving
        onPositionChanged: if (pressed) body.contentY = Math.max(0, Math.min(body.contentHeight - body.height, position * body.contentHeight))
      }

      WheelHandler {
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(event) { grid.handleGridWheel(event) }
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
              color: horizontalSlider.pressed ? Theme.Color.accent : Qt.rgba(grid.ink.r, grid.ink.g, grid.ink.b, 0.78)
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
          color: Theme.Color.urgent
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
      Button { text: "Next"; enabled: !grid.busy && grid.hasMore && grid.rows.length > 0; onClicked: grid.nextPage() }
    }
  }
}
