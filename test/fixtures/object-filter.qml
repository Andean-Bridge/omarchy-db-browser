import QtQuick
import QtTest
import "../../" as App

TestCase {
  id: suite
  name: "ObjectFilter"
  when: false
  App.DbStudioPanel { id: panel }
  readonly property var catalog: ({
    dbo: [{schema:"dbo",name:"CompletedJobs",type:"table"}, {schema:"dbo",name:"JobSummary",type:"view"}],
    reports: [{schema:"reports",name:"DailyJobs",type:"view"}],
    archive: [{schema:"archive",name:"OldJobs",type:"table"}]
  })
  function names() { return panel.filteredSchemas().map(function(schema) { return schema.name }).join(",") }
  function selectType(button, index) {
    mouseClick(button, button.width / 2, button.height / 2)
    wait(20)
    const menu = findChild(panel,"objectTypeMenu")
    verify(menu.visible)
    compare(menu.count,3)
    compare(menu.itemAt(0).text,"All")
    compare(menu.itemAt(1).text,"Tables")
    compare(menu.itemAt(2).text,"Views")
    compare(menu.itemAt(["all","table","view"].indexOf(panel.objectTypeFilter)).checked,true)
    const item = menu.itemAt(index)
    mouseClick(item,item.width / 2,item.height / 2)
    wait(30)
    verify(!menu.visible)
    verify(menu.itemAt(index).checked)
    compare([0,1,2].filter(function(i) { return menu.itemAt(i).checked }).length,1)
  }
  Timer {
    interval: 150; running: true
    onTriggered: {
      try {
        const window = findChild(panel,"dbStudioWindow")
        window.implicitWidth = 760
        window.implicitHeight = 480
        window.visible = true
        if ("sidebarVisible" in panel) panel.sidebarVisible = true
        panel.connectionId = "fixture"
        panel.activeProfile = {name:"Staging fixture",type:"sqlserver",database:"JobReporting"}
        panel.schemas = [{name:"dbo"},{name:"reports"},{name:"archive"},{name:"empty"}]
        panel.objectsBySchema = suite.catalog
        panel.expandedSchemas = ({dbo:true,reports:true,archive:true})
        suite.wait(40)
        const choice = findChild(panel,"objectTypeFilterButton")
        const menu = findChild(panel,"objectTypeMenu")
        const list = findChild(panel,"schemaBrowserArea").children[0]
        const connectionButton = findChild(panel,"connectionMenuButton")
        const connectionDialog = findChild(panel,"connectionListDialog")
        const database = findChild(panel,"databaseSelector")
        suite.compare(connectionButton.text,"Staging fixture")
        suite.compare(findChild(panel,"connectionStatusDot").color,Qt.color("#58c89a"))
        suite.compare(database.height,40)
        suite.compare(database.y,0)
        suite.mouseClick(connectionButton,connectionButton.width / 2,connectionButton.height / 2)
        suite.wait(20)
        suite.verify(connectionDialog.visible)
        const addConnection = findChild(panel,"connectionMenuAddButton")
        suite.verify(addConnection.visible)
        suite.mouseClick(addConnection,addConnection.width / 2,addConnection.height / 2)
        suite.wait(20)
        suite.verify(!connectionDialog.visible)
        suite.verify(findChild(panel,"connectionDialog").visible)
        findChild(panel,"connectionDialog").close()
        suite.wait(20)
        panel.connectionId = ""
        suite.compare(connectionButton.text,"Connections")
        suite.verify(!database.visible)
        suite.verify(findChild(panel,"connectionStatusDot").color !== Qt.color("#58c89a"))
        panel.connecting = true
        suite.compare(connectionButton.text,"Connecting…")
        panel.connecting = false
        panel.connectionId = "fixture"
        panel.activeProfile = {name:"A very long <b>connection</b> name for staging",type:"sqlserver",database:"JobReporting"}
        suite.wait(20)
        suite.verify(connectionButton.width <= 180)
        suite.compare(findChild(panel,"connectionMenuName").textFormat,Text.PlainText)
        panel.activeProfile = {name:"Staging fixture",type:"sqlserver",database:"JobReporting"}
        suite.mouseClick(database,database.width / 2,database.height / 2)
        suite.wait(20)
        suite.verify(panel.databasePickerExpanded)
        suite.verify(!choice.visible)
        suite.mouseClick(database,database.width / 2,database.height / 2)
        suite.wait(20)
        suite.verify(!panel.databasePickerExpanded)
        suite.verify(choice.visible)
        suite.compare(panel.objectTypeFilter,"all")
        // Keyboard access and dismissal leave the filter unchanged.
        choice.forceActiveFocus()
        suite.keyClick(Qt.Key_Space)
        suite.wait(20)
        suite.verify(menu.visible)
        suite.keyClick(Qt.Key_Escape)
        suite.wait(20)
        suite.verify(!menu.visible)
        suite.verify(window.visible)
        suite.compare(panel.objectTypeFilter,"all")
        suite.compare(list.count,7)
        suite.compare(suite.names(),"dbo,reports,archive")
        suite.selectType(choice,1)
        suite.compare(panel.objectTypeFilter,"table")
        suite.compare(suite.names(),"dbo,archive")
        suite.compare(list.count,4)
        suite.compare(panel.visibleSchemaEntries()[0].count,1)
        panel.objectSearch = " dbo "
        suite.compare(panel.filteredObjects("dbo").length,1)
        suite.compare(panel.filteredObjects("dbo")[0].type,"table")
        panel.objectSearch = "JobSummary"
        suite.wait(20)
        suite.compare(list.count,0)
        suite.verify(findChild(panel,"schemaEmptyMessage").visible)
        suite.compare(findChild(panel,"schemaEmptyMessage").text,"No matching objects.")
        panel.objectSearch = "jobs"
        suite.compare(suite.names(),"dbo,archive")
        panel.objectSearch = "view"
        suite.compare(suite.names(),"")
        suite.selectType(choice,2)
        suite.compare(panel.objectTypeFilter,"view")
        suite.compare(suite.names(),"dbo,reports")
        panel.objectSearch = "reports"
        suite.compare(panel.filteredObjects("reports").length,1)
        panel.objectSearch = ""
        panel.objectsBySchema = ({archive:suite.catalog.archive})
        suite.wait(20)
        suite.compare(findChild(panel,"schemaEmptyMessage").text,"No views found.")
        suite.selectType(choice,1)
        panel.objectsBySchema = ({reports:suite.catalog.reports})
        suite.wait(20)
        suite.compare(findChild(panel,"schemaEmptyMessage").text,"No tables found.")
        // Refreshing metadata and switching databases keep the chosen type.
        panel.objectsBySchema = suite.catalog
        panel.loadSchema()
        let request = JSON.parse(panel.queuedRequests[panel.queuedRequests.length - 1])
        panel.handleLine(JSON.stringify({id:request.id,ok:true,data:{schemas:[{name:"dbo"},{name:"reports"}]}}))
        request = JSON.parse(panel.queuedRequests[panel.queuedRequests.length - 1])
        panel.handleLine(JSON.stringify({id:request.id,ok:true,data:{objects:suite.catalog.dbo.concat(suite.catalog.reports)}}))
        suite.compare(panel.objectTypeFilter,"table")
        suite.compare(suite.names(),"dbo")
        panel.clearDatabaseState()
        suite.compare(panel.objectTypeFilter,"table")
        panel.connectionId = "second-fixture"
        panel.schemas = [{name:"dbo"},{name:"reports"},{name:"archive"}]
        panel.objectsBySchema = suite.catalog
        panel.expandedSchemas = ({dbo:true,reports:true,archive:true})
        suite.selectType(choice,0)
        suite.compare(panel.objectTypeFilter,"all")
        suite.compare(list.count,7)
        // Keep the browser usable at the minimum window size with the sidebar shown.
        suite.wait(40)
        suite.compare(window.width,760)
        suite.compare(window.height,480)
        suite.verify(choice.visible && choice.width >= 28)
        suite.verify(list.height > 40)
        suite.selectType(choice,1)
        suite.compare(list.count,4)
        panel.activeProfile = {name:"Staging fixture",type:"sqlserver",database:"JobReporting"}
        suite.wait(20)
        suite.grabImage(window.contentItem).save("browser-layout.png")
        suite.mouseClick(choice,choice.width / 2,choice.height / 2)
        suite.wait(20)
        suite.verify(menu.visible)
        suite.grabImage(window.contentItem).save("object-filter.png")
        console.log("OBJECT_FILTER_UI_PASSED")
      } catch (error) { console.error("OBJECT_FILTER_UI_FAILED",error,error.stack) }
      Qt.quit()
    }
  }
}
