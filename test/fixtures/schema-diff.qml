import QtQuick
import QtTest
import "../../"

TestCase {
  id: suite
  name: "SchemaDiffSelection"
  when: false
  Timer {
    interval: 100; running: true
    onTriggered: {
      try {
        const tests = [suite.test_typeSelectionAndMixedSchemas, suite.test_filterBulkOnlyChangesMatches, suite.test_resultFiltersRetainHiddenSelectionAndInvalidateScript, suite.test_busySelectionCannotChangeInFlightScript, suite.test_mixedCheckboxClickSelectsThenClearsType, suite.test_compareAndScriptRequestsPreserveScope]
        tests.forEach(function(test) { suite.init(); test() })
        console.log("SCHEMA_DIFF_UI_PASSED")
      } catch (error) { console.error("SCHEMA_DIFF_UI_FAILED", error) }
      Qt.quit()
    }
  }
  width: 1000
  height: 800
  ConnectionWorkspace { id: panel }
  readonly property var objects: [{schema:"dbo",name:"customers",type:"table"}, {schema:"sales",name:"orders",type:"table"}, {schema:"sales",name:"open_orders",type:"view"}]
  function init() {
    panel.queuedRequests = []
    panel.pendingRequests = ({})
    panel.resetDiffResults()
    panel.diffCatalog = {source:{schemas:[{name:"dbo"},{name:"sales"}],objects:objects}}
    panel.selectAllDiff(true)
  }
  function test_typeSelectionAndMixedSchemas() {
    panel.setDiffObjects(panel.diffSelectionObjects("view"), false)
    compare(panel.diffSelectedCount(), 2)
    compare(panel.diffCheckState(panel.diffRowObjects({kind:"schema",name:"sales"}), panel.diffSelectedObjects), Qt.PartiallyChecked)
    panel.setDiffObjects(panel.diffSelectionObjects("table"), false)
    compare(panel.diffSelectedCount(), 0)
    compare(panel.diffSelectedSchemas.length, 0)
    panel.toggleDiffRow({kind:"object",object:objects[2]}, true)
    compare(panel.diffSelectedSchemas.join(","), "sales")
  }
  function test_filterBulkOnlyChangesMatches() {
    panel.diffFilter = "sales.orders"
    compare(panel.diffMatchingObjects().length, 1)
    compare(panel.diffRows().filter(row => row.kind === "object").length, 1)
    panel.setDiffObjects(panel.diffMatchingObjects(), false)
    compare(panel.diffSelectedCount(), 2)
    verify(panel.diffSelectedObjects[panel.diffObjectKey(objects[2])])
    panel.diffFilter = "no matches"
    panel.setDiffObjects(panel.diffMatchingObjects(), false)
    compare(panel.diffSelectedCount(), 2)
  }
  function test_resultFiltersRetainHiddenSelectionAndInvalidateScript() {
    panel.diffResult = {targetOnly:[], unchanged:0, changes:objects.map((object, i) => Object.assign({}, object, {status:i === 0 ? "create" : "alter",targetExists:i !== 0}))}
    panel.diffIncluded = panel.diffSelectedObjects
    panel.diffPhase = "results"
    panel.diffScript = "stale SQL"
    panel.diffResultType = "view"
    compare(panel.diffVisibleChanges().length, 1)
    panel.setDiffIncluded(panel.diffVisibleChanges(), false)
    compare(panel.diffIncludedCount(), 2)
    compare(panel.diffScript, "")
    panel.diffResultType = "all"
    panel.diffResultStatus = "missing"
    compare(panel.diffVisibleChanges()[0].name, "customers")
    panel.diffResultFilter = "sales"
    compare(panel.diffVisibleChanges().length, 0)
    compare(panel.diffIncludedCount(), 2)
  }
  function test_busySelectionCannotChangeInFlightScript() {
    panel.diffBusy = true
    panel.selectAllDiff(false)
    compare(panel.diffSelectedCount(), 3)
  }
  function test_mixedCheckboxClickSelectsThenClearsType() {
    let window = findChild(panel, "dbStudioWindow")
    window.visible = true
    panel.openDiffDialog()
    panel.diffCatalog = {source:{schemas:[{name:"dbo"},{name:"sales"}],objects:objects}}
    panel.selectAllDiff(true)
    panel.setDiffObjects([objects[0]], false)
    wait(50)
    let dialog = findChild(panel, "schemaDiffDialog")
    let check = findChild(dialog.contentItem, "diffCompareType_table")
    tryCompare(check, "checkState", Qt.PartiallyChecked)
    mouseClick(check)
    compare(panel.diffSelectedCount(), 3)
    mouseClick(check)
    compare(panel.diffSelectedCount(), 1)
    panel.close()
  }
  function test_compareAndScriptRequestsPreserveScope() {
    findChild(panel, "dbStudioWindow").visible = true
    panel.openDiffDialog()
    panel.diffCatalog = {source:{schemas:[{name:"dbo"},{name:"sales"}],objects:objects}}
    panel.selectAllDiff(true)
    panel.diffSourceProfileId = "source"
    panel.diffTargetProfileId = "target"
    panel.setDiffObjects(panel.diffSelectionObjects("view"), false)
    panel.compareDiff()
    let request = JSON.parse(panel.queuedRequests[0])
    compare(request.action, "schemaDiff.compare")
    compare(request.payload.selectedObjects.length, 2)
    panel.handleLine(JSON.stringify({id:request.id,ok:true,data:{comparisonId:"fixture",unchanged:0,targetOnly:[],changes:objects.slice(0,2).map(object => Object.assign({},object,{status:"create",notes:[],targetExists:false}))}}))
    compare(panel.diffPhase, "results")
    panel.toggleDiffIncluded(panel.diffObjectKey(objects[0]), false)
    panel.diffScriptOptions = {refreshDependentViews:false}
    panel.generateDiffScript()
    request = JSON.parse(panel.queuedRequests[panel.queuedRequests.length-1])
    compare(request.action, "schemaDiff.script")
    compare(request.payload.selectedKeys.length, 1)
    compare(request.payload.selectedKeys[0], panel.diffObjectKey(objects[1]))
    verify(!request.payload.scriptOptions.refreshDependentViews)
    panel.handleLine(JSON.stringify({id:request.id,ok:true,data:{sql:"fixture SQL",complete:true,manual:[],refreshedViews:[]}}))
    compare(panel.diffPhase, "script")
    compare(panel.diffScript, "fixture SQL")
    panel.close()
  }

}
