import QtQuick
import QtTest
import "../.." as App

TestCase {
  id: test
  name: "ResultGrid"
  visible: true
  width: 520; height: 300
  when: windowShown
  App.DbGrid { id: grid; anchors.fill: parent }
  SignalSpy { id: sortSpy; target: grid; signalName: "sortRequested" }
  SignalSpy { id: editSpy; target: grid; signalName: "editCell" }
  function init() {
    grid.savedColumnWidths = ({})
    grid.layoutKey = "query-1"
    grid.columns = ["id", "name", "email", "status", "city", "notes"]
    grid.rows = Array.from({length: 100}, (_, i) => [i, "Name " + i, "test@example.test", "Active", "Lima", "Note"])
    grid.editableColumns = ["name"]
    grid.sortableColumns = ["name"]
    grid.sort = null
    grid.busy = false
    grid.selectCell(0, 0)
    grid.scrollHorizontally(-100000)
    editSpy.clear()
    sortSpy.clear()
    wait(50)
  }
  function dragColumn(index, delta) {
    let horizontal = findChild(grid, "gridHorizontalViewport")
    let edge = grid.columnOffset(index + 1) - horizontal.contentX - 2
    mousePress(grid, edge, 20)
    mouseMove(grid, edge + delta, 20, 80)
    mouseRelease(grid, edge + delta, 20)
    wait(20)
  }
  function test_resizeByDraggingAndKeepCellsAligned() {
    let oldWidth = grid.columnWidth(1)
    dragColumn(1, 120)
    compare(grid.columnWidth(1), oldWidth + 120)
    compare(sortSpy.count, 0)
    let header = findChild(grid, "gridHeader_1")
    let cell = findChild(grid, "gridCell_0_1")
    compare(header.width, oldWidth + 120)
    compare(cell.width, header.width)
    compare(cell.mapToItem(grid, 0, 0).x, header.mapToItem(grid, 0, 0).x)
    // Releasing the resize grab restores normal sorting.
    mouseClick(grid, grid.columnOffset(1) + 20, 20)
    compare(sortSpy.count, 1)
    // Shrink below the supported minimum without losing the pointer grab.
    dragColumn(1, -400)
    compare(grid.columnWidth(1), 72)
    compare(sortSpy.count, 1)
  }
  function test_resizeAfterHorizontalScrollAndNavigate() {
    grid.scrollHorizontally(300)
    let horizontal = findChild(grid, "gridHorizontalViewport")
    let oldWidth = grid.columnWidth(3)
    dragColumn(3, 90)
    compare(grid.columnWidth(3), oldWidth + 90)
    grid.resizeColumn(4, 420)
    grid.selectCell(0, 0)
    keyClick(Qt.Key_End)
    compare(grid.selectedColumn, 5)
    verify(grid.columnOffset(6) <= horizontal.contentX + horizontal.width + 1)
    keyClick(Qt.Key_Home)
    compare(horizontal.contentX, 0)
    grid.scrollHorizontally(100000)
    for (let i = 0; i < grid.columns.length; i++) grid.resizeColumn(i, 72)
    tryVerify(() => horizontal.contentX <= Math.max(0, horizontal.contentWidth - horizontal.width))
  }
  function test_fitColumnAndRetainWidthsPerTabAndResult() {
    let rows = grid.rows.slice()
    rows[0][1] = "A name that needs a wider result column"
    grid.rows = rows
    mouseDoubleClickSequence(grid, grid.columnOffset(2) - 2, 20)
    verify(grid.columnWidth(1) > grid.cellWidth)
    compare(sortSpy.count, 0)
    let fitted = grid.columnWidth(1)
    grid.rows = [[1, "Refreshed"]]
    compare(grid.columnWidth(1), fitted)
    grid.columns = grid.columns.slice()
    compare(grid.columnWidth(1), fitted)
    grid.layoutKey = "query-2"
    compare(grid.columnWidth(1), grid.cellWidth)
    grid.resizeColumn(1, 300)
    grid.layoutKey = "query-1"
    compare(grid.columnWidth(1), fitted)
    grid.columns = ["different", "result"]
    compare(grid.columnWidth(1), grid.cellWidth)
  }
  function test_wheelAndVisibleScrollBar() {
    let body = findChild(grid, "gridRowsViewport")
    let bar = findChild(grid, "gridVerticalScrollBar")
    verify(bar.x >= 0 && bar.x + bar.width <= grid.width)
    mouseWheel(grid, 200, 110, 0, -240)
    tryVerify(() => body.contentY > 0)
    let horizontal = findChild(grid, "gridHorizontalViewport")
    mouseWheel(grid, 200, 110, 0, -240, Qt.NoButton, Qt.ShiftModifier)
    tryVerify(() => horizontal.contentX > 0)
    let oldY = body.contentY
    mousePress(bar, bar.width / 2, bar.height * 0.5)
    mouseMove(bar, bar.width / 2, bar.height * 0.8, 50)
    mouseRelease(bar, bar.width / 2, bar.height * 0.8)
    verify(body.contentY > oldY)
  }
  function test_keyboardNavigationAndEdit() {
    keyClick(Qt.Key_End, Qt.ControlModifier)
    compare(grid.selectedRow, 99)
    compare(grid.selectedColumn, 5)
    let body = findChild(grid, "gridRowsViewport")
    verify(body.contentY > 0)
    let horizontal = findChild(grid, "gridHorizontalViewport")
    verify(horizontal.contentX > 0)
    keyClick(Qt.Key_Home, Qt.ControlModifier)
    compare(grid.selectedRow, 0)
    compare(grid.selectedColumn, 0)
    keyClick(Qt.Key_Right)
    keyClick(Qt.Key_F2)
    compare(editSpy.count, 1)
    compare(editSpy.signalArguments[0][0].columnName, "name")
    grid.selectCell(0, 0)
    keyClick(Qt.Key_F2)
    compare(editSpy.count, 2)
    compare(editSpy.signalArguments[1][0].columnName, "id")
    grid.busy = true
    keyClick(Qt.Key_F2)
    compare(editSpy.count, 2)
  }
  function test_sortableHeaderAndBusyGuard() {
    mouseClick(grid, 240, 20)
    compare(sortSpy.count, 1)
    compare(sortSpy.signalArguments[0][0], "name")
    grid.busy = true
    mouseClick(grid, 240, 20)
    compare(sortSpy.count, 1)
    grid.busy = false
    mouseClick(grid, 30, 20)
    compare(sortSpy.count, 1)
  }
  function test_replacingRowsResetsScroll() {
    keyClick(Qt.Key_End, Qt.ControlModifier)
    grid.rows = [[1, "Only row"]]
    let body = findChild(grid, "gridRowsViewport")
    tryCompare(body, "contentY", 0)
    compare(grid.selectedRow, -1)
  }
}
