import QtQuick
import QtTest
import "../../" as App

TestCase {
  id: suite
  name: "CloudflareD1"
  when: false
  App.DbStudioPanel { id: panel }
  function lastRequest() { return JSON.parse(panel.queuedRequests[panel.queuedRequests.length - 1]) }
  Timer {
    interval: 150; running: true
    onTriggered: {
      try {
        let window = findChild(panel, "dbStudioWindow")
        window.visible = true
        panel.addConnection()
        const dialog = findChild(panel, "connectionDialog")
        const picker = findChild(panel, "enginePicker")
        picker.currentIndex = panel.engineOptions.findIndex(entry => entry.value === "cloudflare_d1")
        suite.wait(30)
        suite.verify(dialog.isD1)
        suite.compare(findChild(panel,"passwordInput").placeholderText,"API token with D1 permission")
        suite.compare(findChild(panel,"hostInput").placeholderText,"32-character account identifier")
        findChild(panel,"connectionName").text = "D1 fixture"
        findChild(panel,"hostInput").text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        findChild(panel,"databaseInput").text = "12345678-1234-1234-1234-123456789abc"
        findChild(panel,"passwordInput").text = "fixture-token"
        suite.grabImage(window.contentItem).save("d1-connection.png")
        panel.saveConnection()
        let request = suite.lastRequest()
        suite.compare(request.action,"profiles.save")
        suite.compare(request.payload.profile.type,"cloudflare_d1")
        suite.compare(request.payload.profile.accountId,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        suite.compare(request.payload.profile.databaseId,"12345678-1234-1234-1234-123456789abc")
        suite.compare(request.payload.password,"fixture-token")
        panel.handleLine(JSON.stringify({id:request.id,ok:true,data:{profile:{id:"d1-fixture",name:"D1 fixture",type:"cloudflare_d1"}}}))
        suite.compare(findChild(panel,"passwordInput").text,"")
        panel.activeProfile = {name:"D1 fixture",type:"cloudflare_d1"}
        suite.compare(panel.quoteName('a"b'),'"a""b"')
        panel.queryTable({schema:"main",name:"people",type:"table"})
        suite.verify(panel.activeTab.sql.includes('FROM "main"."people"'))
        suite.verify(panel.activeTab.sql.includes('LIMIT'))
        panel.editingProfileId = "d1-fixture"
        panel.prepareConnectionForm({name:"D1 fixture",type:"cloudflare_d1",hasStoredConnection:true})
        panel.saveConnection()
        suite.compare(suite.lastRequest().action,"profiles.save")
        suite.verify(suite.lastRequest().payload.password === undefined)
        picker.currentIndex = panel.engineOptions.findIndex(entry => entry.value === "postgres")
        suite.verify(!dialog.isD1)
        suite.compare(findChild(panel,"hostInput").placeholderText,"server.example.com")
        console.log("D1_UI_PASSED")
      } catch (error) { console.error("D1_UI_FAILED", error, error.stack) }
      Qt.quit()
    }
  }
}
