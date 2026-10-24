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
  function selectType(choice, index) {
    mouseClick(choice, choice.width / 2, choice.height / 2)
    wait(20)
    keyClick(Qt.Key_Home)
    for (let i = 0; i < index; i++) keyClick(Qt.Key_Down)
    keyClick(Qt.Key_Return)
    wait(30)
  }
  Timer {
    interval: 150; running: true
    onTriggered: {
      try {
        const window = findChild(panel,"dbStudioWindow")
        window.implicitWidth = 980
        window.implicitHeight = 640
        window.visible = true
        if ("sidebarVisible" in panel) panel.sidebarVisible = true
        panel.connectionId = "fixture"
        panel.activeProfile = {name:"Staging fixture",type:"sqlserver",database:"JobReporting"}
        panel.schemas = [{name:"dbo"},{name:"reports"},{name:"archive"},{name:"empty"}]
        panel.objectsBySchema = suite.catalog
        panel.expandedSchemas = ({dbo:true,reports:true,archive:true})
        suite.wait(40)
        const choice = findChild(panel,"objectTypeFilterChoice")
        const list = findChild(panel,"schemaBrowserArea").children[0]
        suite.verify(choice.visible)
        suite.compare(choice.currentIndex,0)
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
        // Keep the browser usable in a compact window with the sidebar shown.
        suite.wait(40)
        suite.compare(window.width,980)
        suite.compare(window.height,640)
        suite.verify(choice.visible && choice.width > 120)
        suite.verify(list.height > 40)
        suite.selectType(choice,1)
        suite.compare(list.count,4)
        suite.grabImage(window.contentItem).save("object-filter.png")
        console.log("OBJECT_FILTER_UI_PASSED")
      } catch (error) { console.error("OBJECT_FILTER_UI_FAILED",error,error.stack) }
      Qt.quit()
    }
  }
}
