import QtQuick
import QtTest
import "../../" as App

TestCase {
  id: suite
  name: "ConnectionWorkspaces"
  when: false
  App.DbStudioPanel { id: app }
  function visualFind(item,name) {
    if (item.objectName === name) return item
    const children=item.children || []
    for (let i=0;i<children.length;i++) { const found=visualFind(children[i],name); if(found) return found }
    return null
  }
  Timer {
    interval: 100; running: true
    onTriggered: {
      try {
        const window = findChild(app,"dbStudioWindow")
        window.implicitWidth=1200
        window.implicitHeight=800
        app.open("{}")
        suite.tryCompare(app,"workerReady",true,3000)
        const first=app.activeWorkspace
        suite.tryCompare(first,"profilesLoaded",true,3000)
        const profiles=first.profiles
        suite.compare(profiles.length,2)
        suite.mouseClick(findChild(app,"newConnectionButton"))
        suite.wait(30)
        suite.verify(findChild(first,"connectionListDialog").visible)
        suite.tryVerify(function() { return !!suite.visualFind(findChild(first,"connectionListDialog").contentItem,"openConnection_staging") },2000)
        suite.mouseClick(suite.visualFind(findChild(first,"connectionListDialog").contentItem,"openConnection_staging"))
        suite.tryCompare(first,"connectionId","staging-1",3000)
        suite.tryCompare(first,"schemaLoading",false,3000)
        first.sidebarVisible=true
        first.objectTypeFilter="table"
        first.objectSearch="Jobs"
        first.expandedSchemas=({dbo:true})
        first.openTable({schema:"dbo",name:"Jobs",type:"table"})
        suite.tryVerify(function() { return !first.activeTab.busy },3000)
        suite.compare(first.activeTab.rows[0][0],"staging")
        const firstTableId=first.activeTabId
        const queryA=first.newQuery("SELECT 'SLOW staging';","Staging SQL")
        suite.wait(30)
        first.runQuery()
        suite.verify(first.activeTab.busy)
        suite.mouseClick(findChild(app,"newConnectionButton"))
        suite.wait(30)
        suite.tryVerify(function() { return !!suite.visualFind(findChild(first,"connectionListDialog").contentItem,"openConnection_production") },2000)
        suite.mouseClick(suite.visualFind(findChild(first,"connectionListDialog").contentItem,"openConnection_production"))
        const second=app.activeWorkspace
        suite.verify(second !== first)
        suite.tryCompare(second,"connectionId","production-2",3000)
        suite.tryCompare(second,"schemaLoading",false,3000)
        second.sidebarVisible=true
        suite.compare(app.workspaces.length,2)
        suite.compare(second.objectSearch,"")
        suite.compare(second.objectTypeFilter,"all")
        second.openTable({schema:"dbo",name:"Jobs",type:"table"})
        suite.tryVerify(function() { return !second.activeTab.busy },3000)
        suite.compare(second.activeTab.rows[0][0],"production")
        // Table tab IDs may match, but their controllers, grids and results never do.
        suite.compare(second.activeTabId,firstTableId)
        const queryB=second.newQuery("SELECT 'production';","Production SQL")
        suite.wait(30)
        second.runQuery()
        suite.tryVerify(function() { return !first.tabs.find(function(t) { return t.id===queryA }).busy && !second.activeTab.busy },3000)
        suite.compare(app.activeWorkspace,second)
        suite.compare(first.tabs.find(function(t) { return t.id===queryA }).rows[0][0],"staging-1")
        suite.compare(second.activeTab.rows[0][0],"production-2")
        suite.verify(!first.visible && second.visible)
        // Window shortcuts go only to the visible workspace.
        const firstCount=first.tabs.length
        const secondCount=second.tabs.length
        suite.keyClick(Qt.Key_N,Qt.ControlModifier)
        suite.wait(30)
        suite.compare(first.tabs.length,firstCount)
        suite.compare(second.tabs.length,secondCount+1)
        second.activeTabId=queryB
        suite.mouseClick(suite.visualFind(window.contentItem,"connectionTab_"+first.workspaceId))
        suite.wait(30)
        suite.compare(first.objectSearch,"Jobs")
        suite.compare(first.objectTypeFilter,"table")
        suite.compare(first.activeTabId,queryA)
        suite.compare(findChild(first,"sqlEditor").text,"SELECT 'SLOW staging';")
        suite.compare(first.activeTab.rows[0][0],"staging-1")
        suite.compare(app.openProfile(profiles[0]),first)
        suite.compare(app.workspaces.length,2)
        first.updateTab(queryA,{fileSaving:true})
        app.closeWorkspace(first.workspaceId)
        suite.compare(app.workspaces.length,2)
        suite.verify(first.notice.includes("save"))
        first.updateTab(queryA,{fileSaving:false})
        // Closing unsaved SQL offers review/cancel before releasing this connection.
        app.closeWorkspace(first.workspaceId)
        const closeDialog=findChild(app,"closeConnectionDialog")
        suite.wait(20)
        suite.verify(closeDialog.visible)
        suite.mouseClick(findChild(app,"cancelConnectionClose"))
        suite.wait(20)
        suite.compare(app.workspaces.length,2)
        app.closeWorkspace(first.workspaceId)
        suite.wait(20)
        suite.mouseClick(findChild(app,"reviewConnectionClose"))
        suite.wait(20)
        suite.compare(app.activeWorkspace,first)
        suite.compare(first.activeTabId,queryA)
        // Overlapping queries reuse LOCAL request numbers. Cancellation must translate
        // to the owning workspace's global worker request, never another connection.
        first.runQuery()
        app.activateWorkspace(second.workspaceId)
        second.updateTab(queryB,{sql:"SELECT 'SLOW production';"})
        second.syncEditor()
        second.runQuery()
        suite.verify(first.activeTab.busy && second.activeTab.busy)
        app.closeWorkspace(first.workspaceId,true)
        suite.tryCompare(app,"retiringWorkspaces",[],3000)
        suite.tryVerify(function() { return !second.activeTab.busy },3000)
        suite.compare(app.workspaces.length,1)
        suite.compare(second.activeTab.rows[0][0],"production-2")
        suite.compare(second.activeTab.error,"")
        // An explicit new session can use the same profile independently.
        const tab=suite.visualFind(window.contentItem,"connectionTab_"+second.workspaceId)
        suite.mouseClick(tab,tab.width/2,tab.height/2,Qt.RightButton)
        suite.wait(20)
        const tabMenu=findChild(app,"connectionTabMenu")
        suite.verify(tabMenu.visible)
        suite.mouseClick(tabMenu.itemAt(0))
        const third=app.activeWorkspace
        suite.verify(third !== second)
        suite.tryCompare(third,"connectionId","production-3",3000)
        suite.compare(second.connectionId,"production-2")
        suite.compare(third.unsavedQueries().length,0)
        suite.verify(!second.visible && third.visible)
        suite.verify(findChild(app,"connectionTabStrip").color !== third.bg)
        // Changing databases affects this session, not the other open session.
        third.switchDatabase("OtherDatabase")
        suite.tryVerify(function() { return third.activeProfile.database === "OtherDatabase" },3000)
        suite.compare(second.activeProfile.database,"JobReporting")
        // AI cancellation uses the same owner-to-global request translation.
        let aiCancelled=false
        const aiRequest=third.request("ai.generate",{connectionId:third.connectionId},function(data,error) { aiCancelled=!!error })
        third.request("ai.cancel",{targetId:aiRequest},function() {})
        suite.tryVerify(function() { return aiCancelled },3000)
        third.timeoutMs=120000
        suite.compare(second.timeoutMs,120000)
        second.setRowLimit(250)
        suite.tryCompare(third,"rowLimit",250,3000)
        app.activateWorkspace(second.workspaceId)
        suite.wait(30)
        // Overflowing connection tabs scroll to the selected connection.
        const scratch=[]
        for (let i=0;i<7;i++) scratch.push(app.createWorkspace())
        app.activateWorkspace(scratch[6].workspaceId)
        suite.wait(50)
        suite.verify(findChild(app,"connectionTabScroll").contentX>0)
        scratch.forEach(function(item) { app.closeWorkspace(item.workspaceId,true) })
        suite.tryCompare(app,"retiringWorkspaces",[],3000)
        app.activateWorkspace(second.workspaceId)
        suite.wait(30)
        suite.grabImage(window.contentItem).save("connection-workspaces.png")
        // Editing a profile cannot change the dialect or target of open SQL tabs.
        second.editingProfileId=profiles[1].id
        second.prepareConnectionForm(profiles[1])
        findChild(second,"enginePicker").currentIndex=second.engineOptions.findIndex(function(item) { return item.value==="postgres" })
        findChild(second,"hostInput").text="localhost"
        findChild(second,"databaseInput").text="fixture"
        findChild(second,"userInput").text="fixture"
        findChild(second,"passwordInput").text="fixture"
        second.saveConnection()
        suite.tryVerify(function() { return app.workspaces.length===3 && app.activeWorkspace.connectionId!=="" },3000)
        suite.compare(app.activeWorkspace.activeProfile.type,"postgres")
        suite.compare(second.activeProfile.type,"sqlserver")
        suite.compare(third.activeProfile.type,"sqlserver")
        // Application close checks unsaved work across inactive workspaces, too.
        app.close()
        suite.wait(20)
        suite.verify(closeDialog.visible && window.visible)
        suite.mouseClick(findChild(app,"cancelConnectionClose"))
        suite.wait(20)
        app.close(true)
        suite.tryCompare(app,"retiringWorkspaces",[],3000)
        suite.verify(!window.visible)
        // Reopening while the old worker drains must restart it and preserve queued requests.
        app.open("{}")
        suite.tryCompare(app,"workerReady",true,3000)
        suite.tryCompare(app.activeWorkspace,"profilesLoaded",true,3000)
        const reopened=app.openProfile(app.activeWorkspace.profiles[1])
        suite.tryVerify(function() { return !!reopened.connectionId },3000)
        reopened.request("settings.save",{reopenLastConnection:true,lastProfileId:"production"},function() {})
        suite.tryCompare(reopened,"reopenLastConnection",true,3000)
        // Closing the last connection leaves a blank workspace rather than reopening it.
        app.closeWorkspace(reopened.workspaceId,true)
        suite.wait(120)
        suite.compare(app.workspaces.length,1)
        suite.compare(app.activeWorkspace.connectionId,"")
        suite.compare(app.activeWorkspace.requestedProfile,null)
        app.close(true)
        suite.tryCompare(app,"retiringWorkspaces",[],3000)
        console.log("CONNECTIONS_UI_PASSED")
      } catch(error) { console.error("CONNECTIONS_UI_FAILED",error,error.stack) }
      Qt.quit()
    }
  }
}
