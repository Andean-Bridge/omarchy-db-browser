import QtQuick
import QtTest
import "../../" as App

TestCase {
  id: suite
  name: "Workbench"
  when: false
  App.DbStudioPanel { id: panel }
  readonly property var columns: [{name:"id",type:"integer",primaryKey:true}, {name:"name",type:"text",nullable:true}, {name:"amount",type:"numeric(20,4)",nullable:true}]
  Timer {
    interval: 150; running: true
    onTriggered: {
      try {
        [suite.test_tableScriptsFromDefinitionAndBrowser, suite.test_tableScriptErrorsAndConnectionChanges, suite.test_exportOptionsAndColumnSelection, suite.test_exportBooleanFilterAndCancellation, suite.test_exportLayoutAtSmallWindow, suite.test_cloudflareD1ConnectionAndWorkbench, suite.test_sqlCompletionKeyboardAndUndo, suite.test_sqlAliasCompletionMetadataAndRun, suite.test_sqlHighlightingAndStaleMetadata, suite.test_sortCycleAndPageReset, suite.test_filterPersistsThroughPagesAndEdits, suite.test_rowEditsAreStagedUntilSave, suite.test_rowEditValidationAndFailure, suite.test_rowEditSkipsShortenedValues, suite.test_literalEditorSearch, suite.test_openSaveAndUnsavedClose, suite.test_manyTabsStayReachable, suite.test_queryResultsHaveSpaceAtEveryWindowSize, suite.test_collapseKeepsRunAndResultsAvailable, suite.test_resultSpaceSurvivesSplitterDrag, suite.test_multipleQueryResults, suite.test_manyResultTabsStayReachable, suite.test_executionShowsMessagesForErrorsAndNonQueries, suite.test_shortWindowCollapsesEditorAfterExecution].forEach(function(test) { console.log("RUN", test); suite.init(); test() })
        console.log("WORKBENCH_UI_PASSED")
      } catch (error) { console.error("WORKBENCH_UI_FAILED", error, error.stack) }
      Qt.quit()
    }
  }
  function init() {
    for (let name of ["connectionDialog", "tableExportDialog", "exportSaveDialog", "tableFilterDialog", "editValueDialog", "unsavedQueryDialog"]) {
      let dialog = findChild(panel,name)
      if (dialog) dialog.close()
    }
    findChild(panel,"tableScriptMenu").close()
    panel.scriptBusy = false
    panel.exportBusy = false
    panel.exportCancelling = false
    panel.exportPendingId = 0
    panel.exportContext = null
    panel.exportOptions = null
    panel.editSaving = false
    panel.editError = ""
    panel.pendingRequests = ({})
    panel.queuedRequests = []
    panel.connectionId = "fixture"
    panel.activeProfile = null
    panel.resetCompletionMetadata()
    panel.objectsBySchema = ({})
    panel.editorFindVisible = false
    panel.notice = ""
    panel.resultPane = "results"
    panel.tabs = [{id:"table",kind:"table",title:"People",object:{schema:"public",name:"people",type:"table"},definition:{columns:columns},tablePane:"data",columns:columns,rows:[[1,"First", "1.23"],[2,"Second","2.34"]],cellRefs:[],editHandles:["first","second"],offset:40,pageOffsets:[0,20,40],hasMore:true,busy:false,error:""}]
    panel.activeTabId = "table"
    let window = findChild(panel,"dbStudioWindow")
    window.maximumSize = Qt.size(16777215,16777215)
    window.minimumSize = Qt.size(760,480)
    window.implicitWidth = 760
    window.implicitHeight = 480
    window.visible = true
    wait(40)
  }
  function rowField(index) { return findChild(panel,"rowEditFields").itemAt(index) }
  function lastRequest() { return JSON.parse(panel.queuedRequests[panel.queuedRequests.length - 1]) }
  function test_tableScriptsFromDefinitionAndBrowser() {
    panel.activeProfile = {name:"Fixture",type:"postgres"}
    panel.updateTab("table",{tablePane:"definition"})
    wait(20)
    const button = findChild(panel,"generateTableScriptButton")
    const menu = findChild(panel,"tableScriptMenu")
    verify(button.visible)
    mouseClick(button,button.width/2,button.height/2)
    wait(20)
    verify(menu.visible)
    const originalSql = "SELECT 'keep existing SQL';"
    const original = panel.newQuery(originalSql,"Existing query")
    menu.close()
    panel.activeTabId = "table"
    for (let action of ["create","alter","insert","update"]) {
      mouseClick(button,button.width/2,button.height/2)
      wait(20)
      verify(menu.visible)
      compare(menu.count,5)
      const item = menu.itemAt(["create","alter","insert","update"].indexOf(action) + 1)
      verify(item.visible)
      mouseClick(item,item.width/2,item.height/2)
      wait(20)
      compare(lastRequest().action,"table.script")
      compare(lastRequest().payload.schema,"public")
      compare(lastRequest().payload.name,"people")
      compare(lastRequest().payload.script,action)
      verify(panel.scriptBusy)
      const sql = action === "create" ? "CREATE TABLE public.people (id integer);" : action.toUpperCase() + " <placeholder>;"
      respond({sql:sql,action:action})
      compare(panel.activeTab.kind,"query")
      compare(panel.activeTab.sql,sql)
      verify(panel.activeTab.title.includes(action.toUpperCase()))
      verify(!panel.queryEditorCollapsed)
      compare(findChild(panel,"sqlEditor").text,sql)
      verify(panel.queryIsDirty(panel.activeTab))
      verify(!panel.activeTab.hasCompletedQuery)
      compare(panel.tabs.find(function(tab) { return tab.id === original }).sql,originalSql)
      panel.activeTabId = "table"
      wait(20)
    }
    findChild(panel,"dbStudioWindow").implicitWidth = 1200
    findChild(panel,"dbStudioWindow").implicitHeight = 800
    panel.sidebarVisible = true
    panel.schemas = [{name:"public"}]
    panel.objectsBySchema = ({public:[{schema:"public",name:"people",type:"table"},{schema:"public",name:"v_people",type:"view"}]})
    panel.expandedSchemas = ({public:true})
    wait(30)
    const list = findChild(panel,"schemaObjectList")
    compare(list.count,3)
    const table = list.itemAtIndex(1)
    verify(!!table)
    mouseClick(table,table.width/2,table.height/2,Qt.RightButton)
    wait(20)
    verify(menu.visible)
    compare(panel.scriptObject.name,"people")
    menu.close()
    const view = list.itemAtIndex(2)
    mouseClick(view,view.width/2,view.height/2,Qt.RightButton)
    wait(20)
    verify(!menu.visible)
  }
  function test_tableScriptErrorsAndConnectionChanges() {
    const count = panel.tabs.length
    panel.scriptObject = panel.activeTab.object
    panel.generateTableScript("create")
    const request = lastRequest()
    panel.handleLine(JSON.stringify({id:request.id,ok:false,error:"Could not read complete CREATE"}))
    verify(!panel.scriptBusy)
    compare(panel.tabs.length,count)
    verify(panel.notice.includes("complete CREATE"))
    panel.generateTableScript("create")
    const stale = lastRequest()
    panel.clearDatabaseState()
    verify(!panel.scriptBusy)
    const clearedCount = panel.tabs.length
    panel.notice = "Connection changed"
    panel.handleLine(JSON.stringify({id:stale.id,ok:true,data:{sql:"CREATE TABLE stale (id int);"}}))
    compare(panel.tabs.length,clearedCount)
    compare(panel.notice,"Connection changed")
  }
  function test_exportOptionsAndColumnSelection() {
    panel.activeProfile = {name:"Fixture",type:"postgres"}
    panel.tabs = [Object.assign({}, panel.activeTab, {filter:{column:"name",operator:"startsWith",value:"Fi%_"},sort:{column:"amount",direction:"desc"},
      definition:{columns:columns.concat([{name:"computed",type:"text",generated:true}])}})]
    panel.openTableExport()
    const dialog = findChild(panel,"tableExportDialog")
    verify(dialog.visible)
    verify(panel.editorDialogVisible)
    compare(panel.exportSelectedColumns,["id","name","amount","computed"])
    compare(findChild(panel,"exportFilterEnabled").checked,true)
    compare(findChild(panel,"exportFilterColumn").currentIndex,1)
    compare(findChild(panel,"exportFilterOperator").currentIndex,1)
    compare(findChild(panel,"exportFilterValue").text,"Fi%_")
    findChild(panel,"exportFormat").currentIndex = 1
    wait(20)
    compare(panel.exportFormat,"sql")
    compare(panel.exportSelectedColumns,["id","name","amount"])
    verify(!findChild(panel,"exportColumnChecks").itemAt(3).check.enabled)
    panel.toggleExportColumn("name",false)
    verify(!findChild(panel,"exportColumnChecks").itemAt(1).check.checked)
    findChild(panel,"exportFilterValue").text = "Other"
    panel.chooseExportFile()
    compare(panel.exportOptions.columns,["id","amount"])
    compare(panel.exportOptions.filter.value,"Other")
    compare(panel.activeTab.filter.value,"Fi%_")
    compare(panel.exportOptions.sort.column,"amount")
    const pendingOptions = panel.exportOptions
    findChild(panel,"exportSaveDialog").close()
    panel.exportOptions = pendingOptions
    panel.startTableExport("/tmp/people.sql")
    compare(lastRequest().action,"table.export")
    compare(lastRequest().payload.columns,["id","amount"])
    compare(lastRequest().payload.format,"sql")
    verify(lastRequest().payload.limit === undefined)
    verify(panel.exportBusy)
    verify(!findChild(panel,"saveTableExportButton").buttonEnabled)
    respond({rowCount:1505,filePath:"/tmp/people.sql"})
    verify(!panel.exportBusy)
    verify(!dialog.visible)
    verify(panel.notice.includes("1505"))
  }
  function test_exportBooleanFilterAndCancellation() {
    panel.tabs = [Object.assign({},panel.activeTab,{definition:{columns:columns.concat([{name:"enabled",type:"boolean"}])}})]
    panel.openTableExport()
    panel.selectExportColumns(false)
    verify(!findChild(panel,"saveTableExportButton").buttonEnabled)
    panel.selectExportColumns(true)
    findChild(panel,"exportFilterEnabled").checked = true
    findChild(panel,"exportFilterColumn").currentIndex = 3
    findChild(panel,"exportFilterValue").text = "maybe"
    panel.chooseExportFile()
    verify(panel.exportError.includes("true, false"))
    findChild(panel,"exportFilterValue").text = "false"
    panel.chooseExportFile()
    compare(panel.exportOptions.filter.value,false)
    let pendingOptions = panel.exportOptions
    findChild(panel,"exportSaveDialog").close()
    panel.exportOptions = pendingOptions
    panel.startTableExport("/tmp/people.csv")
    const exportRequest = lastRequest()
    panel.cancelTableExport()
    compare(lastRequest().action,"query.cancel")
    compare(lastRequest().payload.targetId,exportRequest.id)
    verify(panel.exportCancelling)
    panel.handleLine(JSON.stringify({id:exportRequest.id,ok:false,error:"Query cancelled."}))
    verify(!panel.exportBusy)
    verify(findChild(panel,"tableExportDialog").visible)
    verify(panel.exportError.includes("cancelled"))
    panel.chooseExportFile()
    pendingOptions = panel.exportOptions
    findChild(panel,"exportSaveDialog").close()
    panel.exportOptions = pendingOptions
    panel.startTableExport("/tmp/people.csv")
    const stale = lastRequest()
    panel.clearDatabaseState()
    verify(!panel.exportBusy)
    verify(!findChild(panel,"tableExportDialog").visible)
    panel.notice = "Keep this notice"
    panel.handleLine(JSON.stringify({id:stale.id,ok:true,data:{rowCount:3,filePath:"/tmp/people.csv"}}))
    compare(panel.notice,"Keep this notice")
  }
  function test_exportLayoutAtSmallWindow() {
    const window = findChild(panel,"dbStudioWindow")
    window.implicitWidth = 760; window.implicitHeight = 480
    panel.openTableExport()
    wait(30)
    const dialog = findChild(panel,"tableExportDialog")
    const button = findChild(panel,"saveTableExportButton")
    verify(dialog.height <= 440)
    verify(dialog.width <= 720)
    verify(button.visible)
    verify(button.mapToItem(window.contentItem,0,button.height).y <= window.height)
    verify(dialog.contentItem.height > 100)
    const viewport = dialog.contentItem.contentItem
    verify(viewport.contentHeight > viewport.height)
    viewport.contentY = viewport.contentHeight - viewport.height
    wait(20)
    const firstColumn = findChild(panel,"exportColumnChecks").itemAt(0).check
    verify(firstColumn.mapToItem(dialog.contentItem,0,0).y >= 0)
    verify(firstColumn.mapToItem(dialog.contentItem,0,firstColumn.height).y <= dialog.contentItem.height)
    window.minimumSize = Qt.size(1100,820); window.maximumSize = Qt.size(1100,820)
    wait(40)
    verify(dialog.height > 600)
    verify(dialog.contentItem.height > 500)
  }
  function test_cloudflareD1ConnectionAndWorkbench() {
    panel.addConnection()
    const dialog = findChild(panel,"connectionDialog")
    findChild(panel,"enginePicker").currentIndex = panel.engineOptions.findIndex(entry => entry.value === "cloudflare_d1")
    wait(30)
    verify(dialog.isD1)
    compare(findChild(panel,"passwordInput").placeholderText,"API token with D1 permission")
    compare(findChild(panel,"hostInput").placeholderText,"32-character account identifier")
    findChild(panel,"connectionName").text = "D1 fixture"
    findChild(panel,"hostInput").text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    findChild(panel,"databaseInput").text = "12345678-1234-1234-1234-123456789abc"
    findChild(panel,"passwordInput").text = "fixture-token"
    panel.saveConnection()
    compare(lastRequest().action,"profiles.save")
    compare(lastRequest().payload.profile.type,"cloudflare_d1")
    compare(lastRequest().payload.profile.accountId,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    compare(lastRequest().payload.profile.databaseId,"12345678-1234-1234-1234-123456789abc")
    compare(lastRequest().payload.password,"fixture-token")
    respond({profile:{id:"d1-fixture",name:"D1 fixture",type:"cloudflare_d1"}})
    compare(findChild(panel,"passwordInput").text,"")
    tryVerify(() => !dialog.visible)
    init()
    panel.activeProfile = {name:"D1 fixture",type:"cloudflare_d1"}
    compare(panel.tableEditableColumns().length,0)
    verify(panel.tableEditHint().includes("use SQL to edit"))
    compare(panel.quoteName('a"b'),'"a""b"')
    panel.queryTable({schema:"main",name:"people",type:"table"})
    verify(panel.activeTab.sql.includes('FROM "main"."people"'))
    verify(panel.activeTab.sql.includes('LIMIT'))
    wait(20)
    const editor = findChild(panel,"sqlEditor")
    editor.text = "PRAGMA table_info('people')"
    verify(editor.analysis.tokens.some(token => token.text === "PRAGMA" && token.kind === "keyword"))
    // An edit that leaves credentials blank keeps the saved definition.
    panel.editingProfileId = "d1-fixture"
    panel.prepareConnectionForm({name:"D1 fixture",type:"cloudflare_d1",hasStoredConnection:true})
    panel.saveConnection()
    compare(lastRequest().action,"profiles.save")
    verify(lastRequest().payload.password === undefined)
    panel.editingProfileId = ""
  }
  function respond(data) { let request = lastRequest(); panel.handleLine(JSON.stringify({id:request.id,ok:true,data:data})); wait(10) }
  function page() { return {columns:columns,rows:[[1,"First","1.23"],[2,"Second","2.34"]],cellRefs:[],editHandles:["first","second"],hasMore:true,offset:0,stableOrder:true} }
  function test_sortCycleAndPageReset() {
    panel.sortTable("name")
    compare(lastRequest().payload.sort.direction,"asc")
    compare(lastRequest().payload.offset,0)
    compare(panel.activeTab.rows.length,0)
    respond(page())
    panel.sortTable("name")
    compare(lastRequest().payload.sort.direction,"desc")
    respond(page())
    panel.sortTable("name")
    compare(lastRequest().payload.sort,null)
    respond(page())
  }
  function test_filterPersistsThroughPagesAndEdits() {
    panel.openTableFilter()
    let column = findChild(panel,"filterColumn")
    column.currentIndex = 1
    wait(10)
    let op = findChild(panel,"filterOperator")
    op.currentIndex = 0
    findChild(panel,"filterValue").text = "Fi%_"
    panel.applyTableFilter(false)
    compare(lastRequest().payload.filter.column,"name")
    compare(lastRequest().payload.filter.operator,"contains")
    compare(lastRequest().payload.filter.value,"Fi%_")
    compare(lastRequest().payload.offset,0)
    respond(page())
    panel.nextTablePage("table")
    compare(lastRequest().payload.offset,2)
    compare(lastRequest().payload.filter.value,"Fi%_")
    respond(page())
    panel.openCellEditor({row:0,column:1,columnName:"name",complete:true})
    wait(30)
    rowField(0).input.text = "Saved name"
    panel.saveCellEdit()
    compare(lastRequest().action,"table.updateRow")
    respond({updated:true})
    compare(lastRequest().action,"table.rows")
    compare(lastRequest().payload.filter.value,"Fi%_")
    respond(page())
    panel.openTableFilter()
    panel.applyTableFilter(true)
    compare(lastRequest().payload.filter,null)
    respond(page())
  }
  function test_rowEditsAreStagedUntilSave() {
    panel.openCellEditor({row:1,column:2,columnName:"amount",complete:true})
    wait(30)
    const dialog = findChild(panel,"editValueDialog")
    const name = rowField(0).input
    const amount = rowField(1).input
    verify(amount.activeFocus)
    compare(panel.editedCellCount,0)
    verify(!findChild(panel,"saveRowButton").buttonEnabled)
    const requests = panel.queuedRequests.length
    name.text = "Changed name"
    amount.text = "9007199254740993.1234"
    compare(panel.editedCellCount,2)
    compare(panel.queuedRequests.length,requests)
    verify(findChild(panel,"saveRowButton").buttonEnabled)
    name.text = "Second"
    compare(panel.editedCellCount,1)
    name.text = "Changed again"
    dialog.close()
    wait(20)
    compare(panel.queuedRequests.length,requests)
    panel.openCellEditor({row:1,column:0,columnName:"id",complete:true})
    wait(20)
    compare(rowField(0).input.text,"Second")
    compare(rowField(1).input.text,"2.34")
    compare(panel.editedCellCount,0)
    rowField(0).nullInput.checked = true
    rowField(1).input.text = "0"
    panel.saveCellEdit()
    compare(lastRequest().action,"table.updateRow")
    compare(lastRequest().payload.handle,"second")
    compare(lastRequest().payload.changes,[{column:"name",value:null},{column:"amount",value:"0"}])
    verify(panel.editSaving)
    const saves = panel.queuedRequests.length
    panel.saveCellEdit()
    compare(panel.queuedRequests.length,saves)
    respond({updated:true})
    verify(!dialog.visible)
    compare(lastRequest().payload.offset,40)
    respond(page())
    compare(panel.notice,"Row saved")
  }
  function test_rowEditValidationAndFailure() {
    panel.tabs = [Object.assign({},panel.activeTab,{columns:columns.concat([{name:"active",type:"boolean",nullable:false}]),definition:{columns:columns.concat([{name:"active",type:"boolean",nullable:false}])},rows:[[1,"First","1.23",true]]})]
    panel.openCellEditor({row:0,column:1,columnName:"name",complete:true})
    wait(20)
    const requests = panel.queuedRequests.length
    verify(!rowField(2).nullInput.enabled)
    rowField(2).input.text = "1"
    compare(panel.editedCellCount,0)
    rowField(0).input.text = "Staged"
    rowField(2).input.text = "invalid"
    panel.saveCellEdit()
    verify(panel.editError.includes("active"))
    compare(panel.queuedRequests.length,requests)
    rowField(2).input.text = "false"
    panel.saveCellEdit()
    compare(lastRequest().payload.changes,[{column:"name",value:"Staged"},{column:"active",value:false}])
    const request = lastRequest()
    panel.handleLine(JSON.stringify({id:request.id,ok:false,error:"The row changed or was deleted."}))
    wait(20)
    verify(findChild(panel,"editValueDialog").visible)
    verify(panel.editError.includes("refresh"))
    verify(!findChild(panel,"saveRowButton").buttonEnabled)
    compare(panel.activeTab.rows[0][1],"First")
    verify(!rowField(0).input.enabled)
  }
  function test_rowEditSkipsShortenedValues() {
    panel.tabs = [Object.assign({},panel.activeTab,{rows:[[1,"Preview…","1.23"]],cellRefs:[{row:0,column:1,complete:false}]})]
    panel.openCellEditor({row:0,column:2,columnName:"amount",complete:true})
    wait(20)
    verify(rowField(0).input.readOnly)
    rowField(1).input.text = "4.56"
    panel.saveCellEdit()
    compare(lastRequest().payload.changes,[{column:"amount",value:"4.56"}])
    respond({updated:true})
    respond(page())
  }
  function query(sql) {
    panel.tabs = [{id:"query",kind:"query",title:"Query",sql:sql,columns:[],rows:[],busy:false,error:""}]
    panel.activeTabId = "query"
    wait(30)
  }
  function test_sqlCompletionKeyboardAndUndo() {
    query("sel")
    let editor = findChild(panel,"sqlEditor")
    editor.cursorPosition = 3
    editor.forceActiveFocus()
    keyClick(Qt.Key_Space,Qt.ControlModifier)
    verify(editor.completionVisible)
    compare(editor.completion.items[0].label,"SELECT")
    let popup = findChild(panel,"sqlCompletionPopup")
    verify(popup.x >= 0 && popup.y >= 0)
    verify(popup.x+popup.width <= popup.parent.width)
    verify(popup.y+popup.height <= popup.parent.height)
    keyClick(Qt.Key_Tab)
    compare(editor.text,"SELECT")
    compare(panel.activeTab.sql,"SELECT")
    verify(!editor.completionVisible)
    editor.undo()
    compare(editor.text,"sel")
    editor.redo()
    compare(editor.text,"SELECT")
    editor.dismissCompletion()
    editor.text = "se"
    editor.cursorPosition = 2
    keyClick(Qt.Key_L)
    tryVerify(() => editor.completionVisible)
    keyClick(Qt.Key_Escape)
    verify(!editor.completionVisible)
    verify(findChild(panel,"dbStudioWindow").visible)
    editor.text = "su"
    editor.cursorPosition = editor.length
    editor.refreshCompletion(true)
    let suggestions = findChild(panel,"sqlCompletionList")
    const chosen = editor.completion.items[0].insertText
    mouseClick(suggestions,100,16)
    compare(editor.text,chosen)
    verify(!editor.completionVisible)
    editor.text = "SELECT 'sel"
    editor.cursorPosition = editor.length
    keyClick(Qt.Key_Space,Qt.ControlModifier)
    verify(!editor.completionVisible)
  }
  function test_sqlAliasCompletionMetadataAndRun() {
    panel.activeProfile = {name:"Fixture",type:"postgres"}
    panel.objectsBySchema = {public:[{schema:"public",name:"people",type:"table"}]}
    query("SELECT p.na FROM public.people AS p")
    let editor = findChild(panel,"sqlEditor")
    editor.cursorPosition = editor.text.indexOf("na")+2
    editor.forceActiveFocus()
    keyClick(Qt.Key_Space,Qt.ControlModifier)
    compare(lastRequest().action,"table.describe")
    compare(lastRequest().payload.schema,"public")
    compare(lastRequest().payload.name,"people")
    verify(editor.completion.loading)
    respond({columns:columns})
    tryVerify(() => editor.completion.items.some(item => item.label === "name"))
    keyClick(Qt.Key_Return)
    compare(editor.text,'SELECT p."name" FROM public.people AS p')
    compare(lastRequest().action,"table.describe")
    editor.undo()
    compare(editor.text,"SELECT p.na FROM public.people AS p")
    editor.cursorPosition = editor.text.indexOf("na")+2
    editor.refreshCompletion(true)
    keyClick(Qt.Key_Return,Qt.ControlModifier)
    compare(lastRequest().action,"query.run")
    compare(lastRequest().payload.sql,"SELECT p.na FROM public.people AS p")
    panel.newQuery("SELECT 2")
    wait(20)
    verify(!editor.completionVisible)
  }
  function test_sqlHighlightingAndStaleMetadata() {
    panel.activeProfile = {name:"Fixture",type:"sqlserver"}
    query("SELECT 1, '<b>&' -- comment\n\tFROM [public].[people];")
    let editor = findChild(panel,"sqlEditor")
    const original = editor.text
    verify(editor.analysis.tokens.some(t => t.kind === "keyword" && t.text === "SELECT"))
    verify(editor.analysis.tokens.some(t => t.kind === "string" && t.text === "'<b>&'"))
    verify(editor.analysis.tokens.some(t => t.kind === "comment"))
    verify(editor.highlightedSegments.length > 0)
    editor.select(0,6)
    compare(editor.selectedText,"SELECT")
    verify(!editor.highlightedSegments.some(segment => segment.start < 6))
    compare(editor.text,original)
    editor.deselect()
    panel.loadCompletionMetadata([{schema:"public",name:"people"}])
    compare(lastRequest().action,"table.describe")
    panel.resetCompletionMetadata()
    respond({columns:columns})
    compare(Object.keys(panel.completionDefinitions).length,0)
    // A long script only paints the visible lines, including after scrolling.
    editor.text = "SELECT 1;\n".repeat(999)
    editor.cursorPosition = editor.length
    wait(30)
    verify(editor.highlightedSegments.length < 100)
    verify(editor.highlightedSegments.some(segment => segment.start > 9000))
    compare(editor.text.length,9990)
  }
  function test_literalEditorSearch() {
    const sql = "SELECT 'İ';\nSELECT 'x';\nSELECT '[x]';"
    query(sql)
    let editor = findChild(panel,"sqlEditor")
    compare(editor.text,sql)
    panel.editorFindText = "SELECT"
    panel.showEditorFind()
    compare(panel.editorFindMatches.length,3)
    panel.findInEditor(false)
    compare(editor.selectionStart,0)
    panel.findInEditor(false)
    compare(editor.selectionStart,sql.indexOf("SELECT",1))
    panel.findInEditor(true)
    compare(editor.selectionStart,0)
    panel.editorFindText = "[x]"
    compare(panel.editorFindMatches.length,1)
    panel.findInEditor(false)
    compare(editor.selectedText,"[x]")
    panel.editorFindText = ".*"
    compare(panel.editorFindMatches.length,0)
    panel.updateTab("query", {sql: "-- filler\n".repeat(100) + "SELECT 'last match';"})
    panel.syncEditor()
    panel.editorFindText = "last match"
    editor.cursorPosition = 0
    panel.findInEditor(false)
    compare(editor.selectedText,"last match")
    verify(findChild(panel,"sqlEditorScroll").contentItem.contentY > 0)
    panel.editorFindVisible = false
  }
  function test_openSaveAndUnsavedClose() {
    panel.openSqlFile("/tmp/consulta #1.sql")
    compare(lastRequest().action,"sql.open")
    respond({filePath:"/tmp/consulta #1.sql",sql:"SELECT 1;",revision:"a".repeat(64)})
    compare(panel.activeTab.title,"consulta #1.sql")
    verify(!panel.queryIsDirty(panel.activeTab))
    let id = panel.activeTabId
    panel.updateTab(id,{sql:"SELECT 2;"})
    verify(panel.queryIsDirty(panel.activeTab))
    panel.closeTab(id)
    let dialog = findChild(panel,"unsavedQueryDialog")
    verify(dialog.visible)
    dialog.close()
    panel.saveQuery(id,false)
    compare(lastRequest().payload.sql,"SELECT 2;")
    compare(lastRequest().payload.revision,"a".repeat(64))
    respond({saved:true,filePath:"/tmp/consulta #1.sql",revision:"b".repeat(64)})
    verify(!panel.queryIsDirty(panel.activeTab))
    panel.closeTab(id)
    verify(!panel.tabs.some(tab => tab.id === id))
  }
  function test_manyTabsStayReachable() {
    for (let i = 0; i < 12; i++) panel.newQuery("", "Query " + i)
    wait(80)
    let strip = findChild(panel,"workTabs")
    verify(strip.contentWidth > strip.width)
    verify(strip.contentX > 0)
    panel.activeTabId = "table"
    wait(40)
    compare(strip.contentX,0)
  }
  function resultRows() {
    return {columns:columns.concat([{name:"status"},{name:"city"},{name:"notes"}]), rows:Array.from({length:100},(_,i)=>[i+1,"Job "+(i+1),"120.00","Active","Lima","Notes"]), cellRefs:[],durationMs:850,rowCount:100,hasMore:true}
  }
  function queryWithResults() {
    query("select * from job")
    panel.updateTab("query", Object.assign({message:"Query completed", hasCompletedQuery:true}, resultRows()))
    wait(40)
  }
  function test_queryResultsHaveSpaceAtEveryWindowSize() {
    let window = findChild(panel,"dbStudioWindow")
    for (let size of [[760,480],[980,640],[1024,768],[1348,1010]]) {
      queryWithResults()
      panel.notice = "Query completed"
      window.implicitWidth = size[0]
      window.implicitHeight = size[1]
      window.minimumSize = Qt.size(size[0],size[1])
      window.maximumSize = Qt.size(size[0],size[1])
      wait(50)
      compare(window.width,size[0])
      compare(window.height,size[1])
      let body = findChild(findChild(panel,"queryGrid"),"gridRowsViewport")
      verify(body.height >= 4 * 39, "Results must show at least four complete rows at " + size + "; actual body height: " + body.height)
      if (size[1] >= 1000) {
        verify(!panel.queryEditorCollapsed)
        verify(body.height >= 12 * 39, "Tall windows should prioritize results; actual body height: " + body.height)
      }
      compare(findChild(panel,"queryResultSummary").text,"100 rows · 850 ms · limit reached")
    }
  }
  function test_collapseKeepsRunAndResultsAvailable() {
    let window = findChild(panel,"dbStudioWindow")
    window.minimumSize = Qt.size(980,640)
    window.maximumSize = Qt.size(980,640)
    window.implicitWidth = 980
    window.implicitHeight = 640
    queryWithResults()
    let composer = findChild(panel,"queryComposer")
    let grid = findChild(panel,"queryGrid")
    let body = findChild(grid,"gridRowsViewport")
    let oldHeight = body.height
    let toggle = findChild(panel,"toggleSqlEditorButton")
    mouseClick(toggle)
    wait(30)
    verify(panel.queryEditorCollapsed)
    verify(!composer.visible)
    verify(body.height > oldHeight)
    compare(findChild(panel,"sqlEditor").text,"select * from job")
    mouseClick(findChild(panel,"runQueryButton"))
    compare(lastRequest().action,"query.run")
    compare(lastRequest().payload.sql,"select * from job")
    verify(findChild(panel,"cancelQueryButton").visible)
    respond(resultRows())
    compare(panel.resultPane,"results")
    verify(panel.queryEditorCollapsed)
    mouseClick(toggle)
    wait(30)
    verify(composer.visible)
    compare(findChild(panel,"sqlEditor").text,"select * from job")
    panel.setQueryEditorCollapsed(true)
    panel.showEditorFind()
    wait(20)
    verify(!panel.queryEditorCollapsed)
    verify(composer.visible)
    panel.setQueryEditorCollapsed(true)
    panel.editorFindVisible = false
    let oldTab = panel.activeTabId
    panel.newQuery("SELECT 2;")
    wait(20)
    verify(!panel.queryEditorCollapsed)
    panel.activeTabId = oldTab
    wait(20)
    verify(panel.queryEditorCollapsed)
  }
  function test_resultSpaceSurvivesSplitterDrag() {
    let window = findChild(panel,"dbStudioWindow")
    window.minimumSize = Qt.size(1348,1010)
    window.maximumSize = Qt.size(1348,1010)
    window.implicitWidth = 1348
    window.implicitHeight = 1010
    queryWithResults()
    panel.updateTab("query",{sql:"SELECT 1;\n".repeat(200)})
    panel.syncEditor()
    wait(40)
    let divider = findChild(panel,"queryPaneDivider")
    let split = findChild(panel,"querySplit")
    let point = divider.mapToItem(split,divider.width/2,divider.height/2)
    mousePress(split,point.x,point.y)
    mouseMove(split,point.x,split.height-5,50)
    mouseRelease(split,point.x,split.height-5)
    wait(40)
    let body = findChild(findChild(panel,"queryGrid"),"gridRowsViewport")
    verify(body.height >= 4*39,"Dragging the editor must not squeeze out results")
  }
  function test_multipleQueryResults() {
    query("SELECT * FROM people;\nGO\nSELECT * FROM job;")
    panel.runQuery()
    const sets = [
      {columns:columns, rows:[[1,"First","1.23"]], cellRefs:[],rowCount:1,hasMore:true},
      {columns:columns, rows:[[99,"Second","9.99"]], cellRefs:[{row:0,column:1,handle:"second-value",byteLength:5000}],rowCount:1,hasMore:false},
      {columns:[{name:"empty"}],rows:[],cellRefs:[],rowCount:0,hasMore:false}
    ]
    respond({resultSets:sets,durationMs:42,message:"3 result sets returned.\n4 rows affected."})
    const tabs = findChild(panel,"queryResultTabs")
    const grid = findChild(panel,"queryGrid")
    compare(tabs.count,3)
    compare(tabs.itemAt(0).label,"Result 1")
    compare(panel.activeTab.activeResultIndex,0)
    compare(grid.rows[0][0],1)
    verify(findChild(panel,"queryResultSummary").text.includes("limit reached"))
    const initialKey = grid.layoutKey
    grid.resizeColumn(0,211)
    tabs.itemAt(1).clicked()
    wait(20)
    compare(panel.activeTab.activeResultIndex,1)
    compare(grid.rows[0][0],99)
    verify(grid.layoutKey !== initialKey)
    compare(grid.selectedRow,-1)
    compare(grid.cellRefs[0].handle,"second-value")
    verify(!findChild(panel,"queryResultSummary").text.includes("limit reached"))
    grid.selectCell(0,1)
    panel.openCellViewer(grid.selectedCell())
    compare(lastRequest().action,"cell.get")
    compare(lastRequest().payload.handle,"second-value")
    const staleValue = lastRequest()
    tabs.itemAt(0).clicked()
    wait(20)
    verify(!findChild(panel,"cellViewerDialog").visible)
    compare(grid.columnWidths[0],211)
    panel.handleLine(JSON.stringify({id:staleValue.id,ok:true,data:{text:"stale full value"}}))
    verify(!findChild(panel,"cellViewerDialog").visible)
    tabs.itemAt(2).clicked()
    wait(20)
    compare(grid.columns[0].name,"empty")
    compare(grid.rows.length,0)
    verify(findChild(panel,"queryResultSummary").text.includes("0 rows"))
    tabs.itemAt(1).clicked()
    panel.newQuery("SELECT 1")
    panel.resultPane = "messages"
    panel.activeTabId = "query"
    wait(20)
    compare(panel.activeTab.activeResultIndex,1)
    compare(panel.resultPane,"results")
    compare(grid.rows[0][0],99)
    // A rerun replaces the old results and clears their selection.
    panel.runQuery()
    compare(panel.activeTab.resultSets.length,0)
    compare(panel.activeTab.activeResultIndex,0)
    respond({resultSets:[sets[0]],durationMs:12})
    compare(tabs.count,1)
    compare(tabs.itemAt(0).label,"Results")
    panel.clearDatabaseState()
    compare(panel.activeTab.resultSets.length,0)
    compare(panel.activeTab.rows.length,0)
  }
  function test_manyResultTabsStayReachable() {
    query("SELECT 1")
    panel.runQuery()
    respond({resultSets:Array.from({length:12},(_,i)=>({columns:[{name:"id"}],rows:[[i]],cellRefs:[],rowCount:1})),durationMs:1})
    const tabs = findChild(panel,"queryResultTabs")
    const strip = findChild(panel,"queryResultTabScroll")
    verify(strip.contentWidth > strip.width)
    tabs.itemAt(11).clicked()
    wait(30)
    verify(strip.contentX > 0)
    verify(tabs.itemAt(11).x >= strip.contentX)
    verify(tabs.itemAt(11).x + tabs.itemAt(11).width <= strip.contentX + strip.width + 1)
    panel.resultPane = "messages"
    wait(20)
    verify(findChild(panel,"queryMessages").visible)
    verify(panel.activeTab.message.includes("Result 12"))
    panel.newQuery("SELECT 2")
    panel.activeTabId = "query"
    wait(20)
    compare(panel.resultPane,"messages")
    tabs.itemAt(0).clicked()
    wait(20)
    compare(strip.contentX,0)
  }

  function test_executionShowsMessagesForErrorsAndNonQueries() {
    query("UPDATE fixture SET flag=1")
    panel.runQuery()
    respond({columns:[],rows:[],rowCount:3,durationMs:20})
    compare(panel.resultPane,"messages")
    verify(findChild(panel,"queryMessages").visible)
    compare(findChild(panel,"queryResultSummary").text,"3 rows affected")
    panel.runQuery()
    let request = lastRequest()
    panel.handleLine(JSON.stringify({id:request.id,ok:false,error:"Query failed: fixture error"}))
    wait(20)
    compare(panel.resultPane,"messages")
    verify(findChild(panel,"queryMessages").visible)
    compare(panel.notice,"")
  }

  function test_shortWindowCollapsesEditorAfterExecution() {
    let window = findChild(panel,"dbStudioWindow")
    window.minimumSize = Qt.size(760,480)
    window.maximumSize = Qt.size(760,480)
    query("SELECT * FROM job")
    verify(!panel.queryEditorCollapsed)
    panel.runQuery()
    respond(resultRows())
    verify(panel.queryEditorCollapsed)
    verify(findChild(panel,"runQueryButton").visible)
    let body = findChild(findChild(panel,"queryGrid"),"gridRowsViewport")
    verify(body.height >= 4*39)
  }

}
