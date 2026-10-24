pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Theme

Item {
  id: root
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  // Native tests can exercise the real controllers with fixture responses.
  property bool startWorkers: true
  property bool workerReady: false
  property bool workerStarted: false
  property bool workerStopping: false
  property bool restartWorkerRequested: false
  property bool didInitialOpen: false
  property int timeoutMs: 30000
  onTimeoutMsChanged: workspaces.forEach(function(item) { if (item.timeoutMs !== root.timeoutMs) item.timeoutMs = root.timeoutMs })
  property int nextRequestId: 1
  property var requestOwners: ({})
  property var requestIds: ({})
  property var workspaces: []
  property var retiringWorkspaces: []
  property string activeWorkspaceId: ""
  property int nextWorkspaceId: 1
  property bool shuttingDown: false
  property bool closingFromHost: false
  property var closeTargets: []
  property bool closeWholeApp: false
  property string contextWorkspaceId: ""
  readonly property var activeWorkspace: workspace(activeWorkspaceId)
  readonly property bool modalOpen: closeDialog.visible || (!!activeWorkspace && activeWorkspace.editorDialogVisible)
  readonly property color bg: Theme.Color.popups.background
  readonly property color ink: Theme.Color.popups.text
  readonly property color softInk: Qt.rgba(ink.r, ink.g, ink.b, 0.65)
  readonly property color line: Qt.rgba(ink.r, ink.g, ink.b, 0.15)
  readonly property color accent: Theme.Color.accent
  readonly property color raised: Qt.tint(bg, Qt.rgba(ink.r, ink.g, ink.b, 0.07))
  readonly property bool darkTheme: bg.r * 0.299 + bg.g * 0.587 + bg.b * 0.114 < 0.5
  readonly property color connectionStrip: Qt.tint(bg, Qt.rgba(0.22, 0.36, 0.58, darkTheme ? 0.30 : 0.13))
  readonly property color activeConnection: Qt.tint(connectionStrip, Qt.rgba(accent.r, accent.g, accent.b, darkTheme ? 0.34 : 0.20))

  function startWorker() {
    if (!startWorkers) return
    if (workerStopping) { restartWorkerRequested = true; return }
    worker.stdinEnabled = true
    if (!worker.running) worker.running = true
    else if (workerReady && activeWorkspace) activeWorkspace.refreshProfiles()
  }
  function sendRequest(owner, line) {
    var request = JSON.parse(line)
    var localId = request.id
    if (request.action === "query.cancel" || request.action === "ai.cancel") {
      var target = requestIds[owner.workspaceId + ":" + request.payload.targetId]
      if (target === undefined) {
        owner.handleLine(JSON.stringify({id: localId, ok: true, data: {cancelled: false}}))
        return
      }
      request.payload.targetId = target
    }
    var globalId = nextRequestId++
    request.id = globalId
    var owners = Object.assign({}, requestOwners)
    owners[globalId] = { owner: owner, localId: localId, action: request.action }
    requestOwners = owners
    var ids = Object.assign({}, requestIds)
    ids[owner.workspaceId + ":" + localId] = globalId
    requestIds = ids
    worker.write(JSON.stringify(request) + "\n")
  }
  function receiveWorkerLine(line) {
    var response
    try {
      response = JSON.parse(String(line))
      if (!response || typeof response !== "object" || typeof response.id !== "number") throw new Error("Invalid response")
    } catch (_) {
      var owners = requestOwners
      requestOwners = ({}); requestIds = ({})
      Object.keys(owners).forEach(function(id) {
        var entry = owners[id]
        entry.owner.handleLine(JSON.stringify({id:entry.localId,ok:false,error:"Database worker returned an invalid response. Retry the operation."}))
      })
      retiringWorkspaces.slice().forEach(checkRetiredWorkspace)
      return
    }
    var entry = requestOwners[response.id]
    if (!entry) return
    var next = Object.assign({}, requestOwners)
    delete next[response.id]
    requestOwners = next
    var ids = Object.assign({}, requestIds)
    delete ids[entry.owner.workspaceId + ":" + entry.localId]
    requestIds = ids
    response.id = entry.localId
    entry.owner.handleLine(JSON.stringify(response))
    if (response.ok && ["profiles.save", "profiles.delete", "profiles.duplicate"].indexOf(entry.action) >= 0)
      workspaces.forEach(function(item) { if (!item.stoppingWorker) item.refreshProfiles() })
    if (response.ok && entry.action === "settings.save" && response.data) {
      workspaces.forEach(function(item) {
        if (Number.isInteger(response.data.defaultLimit)) item.rowLimit = response.data.defaultLimit
        item.reopenLastConnection = !!response.data.reopenLastConnection
        item.lastProfileId = response.data.lastProfileId || ""
      })
    }
    checkRetiredWorkspace(entry.owner)
  }
  function shutdownWorkspace(item) {
    // The worker is shared, but cancellation and disconnect target only this owner.
    var pending = Object.keys(item.pendingRequests)
    pending.forEach(function(id) {
      var action = item.pendingRequests[id].action
      if (["query.run", "table.rows", "table.export"].indexOf(action) >= 0)
        item.request("query.cancel", {targetId:Number(id)}, function() {})
    })
    if (item.connectionId) item.request("connection.close", {connectionId:item.connectionId}, function() {})
    if (!workerReady) { item.pendingRequests = ({}); item.queuedRequests = [] }
    checkRetiredWorkspace(item)
  }
  function checkRetiredWorkspace(item) {
    if (retiringWorkspaces.indexOf(item) >= 0 && Object.keys(item.pendingRequests).length === 0) finishRetirement(item)
  }
  function workspace(id) { return workspaces.find(function(item) { return item.workspaceId === id }) || null }
  function connectionLabel(item) {
    var profile = item.activeProfile || item.requestedProfile
    if (!profile) return "New connection"
    return profile.name + (profile.database ? " · " + profile.database : "")
  }
  function profileIsOpen(id) {
    return workspaces.some(function(item) { var profile = item.activeProfile || item.requestedProfile; return profile && profile.id === id })
  }
  function createWorkspace() {
    var item = workspaceComponent.createObject(workspaceContainer, { workspaceId: "connection-" + nextWorkspaceId++, allowAutomaticReconnect: false })
    if (!item) return null
    workspaces = workspaces.concat([item])
    if (workerReady) item.hostedWorkerStarted()
    if (!activeWorkspaceId) activeWorkspaceId = item.workspaceId
    return item
  }
  function ensureWorkspace() { return activeWorkspace || createWorkspace() }
  function activateWorkspace(id) {
    var item = workspace(id)
    if (!item || (modalOpen && activeWorkspaceId !== id)) return false
    var changed = activeWorkspaceId !== id
    activeWorkspaceId = id
    if (changed && item.connectionId) item.rememberLastProfile(item.activeProfile)
    Qt.callLater(ensureActiveConnectionVisible)
    return true
  }
  function ensureActiveConnectionVisible() {
    var index = workspaces.findIndex(function(item) { return item.workspaceId === activeWorkspaceId })
    var tab = connectionRepeater.itemAt(index)
    if (!tab) return
    if (tab.x < connectionScroll.contentX) connectionScroll.contentX = tab.x
    else if (tab.x + tab.width > connectionScroll.contentX + connectionScroll.width)
      connectionScroll.contentX = Math.max(0, tab.x + tab.width - connectionScroll.width)
  }
  function openProfile(profile, password, automatic, newSession) {
    if (!profile || shuttingDown) return null
    var existing = !newSession && workspaces.find(function(item) {
      var current = item.activeProfile || item.requestedProfile
      return current && current.id === profile.id
    })
    if (existing) {
      if (!activateWorkspace(existing.workspaceId)) return null
      if (!existing.connectionId && !existing.connecting) connectWorkspace(existing, profile, password, automatic)
      return existing
    }
    if (modalOpen) return null
    var item = workspaces.find(function(candidate) { return !candidate.activeProfile && !candidate.requestedProfile && !candidate.connecting }) || createWorkspace()
    if (!item) return null
    activateWorkspace(item.workspaceId)
    connectWorkspace(item, profile, password, automatic)
    return item
  }
  function connectWorkspace(item, profile, password, automatic) {
    item.allowAutomaticReconnect = false
    item.requestedProfile = profile
    // Credentials stay in the shared worker; tab models contain only public metadata.
    item.connectProfile(profile, password, automatic)
    if (startWorkers) item.startWorker()
  }
  function manageConnections() {
    var item = ensureWorkspace()
    if (startWorkers) item.startWorker()
    item.openConnections()
  }
  function newSession(id) {
    var item = workspace(id)
    if (item) openProfile(item.activeProfile || item.requestedProfile, undefined, false, true)
  }
  function reconnectWorkspace(id) {
    var item = workspace(id)
    if (!item || !activateWorkspace(id)) return
    item.connectProfile(item.activeProfile || item.requestedProfile)
    if (startWorkers) item.startWorker()
  }
  function closeWorkspace(id, discard) {
    var item = workspace(id)
    if (!item) return
    if (item.hasSavingSql() || item.editSaving) {
      item.showNotice("Wait for the save to finish before closing this connection.", true)
      return
    }
    if (!discard && (item.unsavedQueries().length || item.hasStagedEdits() || item.hasRunningWork())) {
      closeTargets = [id]
      closeWholeApp = false
      closeDialog.open()
      return
    }
    var index = workspaces.indexOf(item)
    var profile = item.activeProfile || item.requestedProfile
    if (!shuttingDown && profile && item.lastProfileId === profile.id) {
      var remaining = workspaces.find(function(candidate) { return candidate !== item && candidate.connectionId })
      item.rememberLastProfile(remaining ? remaining.activeProfile : null)
    }
    workspaces = workspaces.filter(function(candidate) { return candidate !== item })
    if (activeWorkspaceId === id) activeWorkspaceId = workspaces.length ? workspaces[Math.max(0, index - 1)].workspaceId : ""
    retiringWorkspaces = retiringWorkspaces.concat([item])
    item.visible = false
    item.shutdown()
    if (!workspaces.length && !shuttingDown) createWorkspace()
    Qt.callLater(ensureActiveConnectionVisible)
  }
  function finishRetirement(item) {
    if (retiringWorkspaces.indexOf(item) < 0) return
    retiringWorkspaces = retiringWorkspaces.filter(function(candidate) { return candidate !== item })
    item.destroy()
    if (!workspaces.length && !retiringWorkspaces.length) stopIdleWorker()
  }
  function stopIdleWorker() {
    if (worker.running) { workerStopping = true; workerReady = false; worker.stdinEnabled = false }
  }
  function close(discard) {
    if (closingFromHost) return
    var saving = workspaces.find(function(item) { return item.hasSavingSql() || item.editSaving })
    if (saving) {
      activateWorkspace(saving.workspaceId)
      saving.showNotice("Wait for the save to finish before closing DB Studio.", true)
      return
    }
    var needsReview = workspaces.some(function(item) { return item.unsavedQueries().length || item.hasStagedEdits() || item.hasRunningWork() })
    if (!discard && needsReview) {
      closeTargets = workspaces.map(function(item) { return item.workspaceId })
      closeWholeApp = true
      studioWindow.visible = true
      closeDialog.open()
      return
    }
    shuttingDown = true
    workspaces.slice().forEach(function(item) { root.closeWorkspace(item.workspaceId, true) })
    closingFromHost = true
    studioWindow.visible = false
    shuttingDown = false
    didInitialOpen = false
    if (!retiringWorkspaces.length) stopIdleWorker()
    if (shell && typeof shell.hide === "function") shell.hide("andean-bridge.db-browser")
    closingFromHost = false
  }
  function requestClose() { close() }
  function open(payloadJson) {
    closingFromHost = false
    var alreadyVisible = studioWindow.visible
    studioWindow.visible = true
    var item = ensureWorkspace()
    if (!didInitialOpen) {
      item.allowAutomaticReconnect = true
      item.automaticOpenAttempted = false
      didInitialOpen = true
    }
    if (startWorkers) item.startWorker()
    item.maybeReopenLastConnection()
    if (alreadyVisible) {
      var target = "title:^DB Studio$"
      Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.focus({ window = " + JSON.stringify(target) + " })" : "focuswindow " + target)
    }
  }
  function reviewBeforeClose() {
    var ids = closeTargets.slice()
    closeDialog.close()
    var item = workspaces.find(function(candidate) { return ids.indexOf(candidate.workspaceId) >= 0 && (candidate.unsavedQueries().length || candidate.hasStagedEdits()) })
    if (!item) return
    activateWorkspace(item.workspaceId)
    var dirty = item.unsavedQueries()
    if (dirty.length) item.activeTabId = dirty[0].id
  }
  function confirmClose() {
    var ids = closeTargets.slice()
    var all = closeWholeApp
    closeDialog.close()
    if (all) close(true)
    else ids.forEach(function(id) { root.closeWorkspace(id, true) })
  }

  Component {
    id: workspaceComponent
    ConnectionWorkspace {
      anchors.fill: parent
      workspaceHost: root
      hostWindow: studioWindow
      visible: root.activeWorkspaceId === workspaceId
      timeoutMs: root.timeoutMs
      onShutdownFinished: root.finishRetirement(this)
    }
  }
  Component.onCompleted: ensureWorkspace()
  Process {
    id: worker
    command: ["node", decodeURIComponent(Qt.resolvedUrl("backend/worker.mjs").toString().replace(/^file:\/\//, ""))]
    stdinEnabled: true
    stdout: SplitParser { onRead: data => root.receiveWorkerLine(data) }
    stderr: SplitParser { onRead: data => {} }
    onStarted: {
      root.workerStarted = true
      root.workerReady = true
      root.workspaces.forEach(function(item) { item.hostedWorkerStarted() })
    }
    onRunningChanged: if (!running && root.workerStarted) {
      root.workerStarted = false; root.workerReady = false
      root.requestOwners = ({}); root.requestIds = ({})
      if (!root.workerStopping) root.workspaces.forEach(function(item) { item.hostedWorkerStopped() })
      root.retiringWorkspaces.slice().forEach(function(item) { root.finishRetirement(item) })
      root.workerStopping = false
      if (root.restartWorkerRequested) { root.restartWorkerRequested = false; root.startWorker() }
    }
  }

  component DatabaseIcon: Canvas {
    property color ink: root.ink
    onInkChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      ctx.save(); ctx.scale(width / 20, height / 20)
      ctx.strokeStyle = ink; ctx.lineWidth = 1.5
      ctx.beginPath()
      ctx.moveTo(2, 5); ctx.bezierCurveTo(2, 1, 18, 1, 18, 5)
      ctx.bezierCurveTo(18, 9, 2, 9, 2, 5)
      ctx.moveTo(2, 5); ctx.lineTo(2, 16); ctx.bezierCurveTo(2, 20, 18, 20, 18, 16); ctx.lineTo(18, 5)
      ctx.moveTo(2, 10); ctx.bezierCurveTo(2, 14, 18, 14, 18, 10)
      ctx.stroke(); ctx.restore()
    }
  }
  component HeaderButton: Button {
    id: button
    implicitHeight: 38
    font.family: Style.font.family
    font.pixelSize: Math.max(13, Style.font.bodySmall)
    contentItem: Text { text: button.text; color: root.ink; font: button.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
    background: Rectangle { color: button.hovered ? root.raised : "transparent"; radius: 5; border.width: button.activeFocus ? 2 : 0; border.color: root.accent }
  }
  component PlainMenuItem: MenuItem {
    id: action
    implicitHeight: 36
    contentItem: Text { text: action.text; textFormat: Text.PlainText; color: action.enabled ? root.ink : root.softInk; font.family: Style.font.family; font.pixelSize: Math.max(13, Style.font.bodySmall); verticalAlignment: Text.AlignVCenter }
    background: Rectangle { color: action.highlighted ? root.raised : root.bg; radius: 3 }
  }

  FloatingWindow {
    id: studioWindow
    objectName: "dbStudioWindow"
    title: "DB Studio"
    color: root.bg
    implicitWidth: 1420
    implicitHeight: 920
    minimumSize: Qt.size(760, 480)
    visible: false
    onVisibleChanged: if (!visible && !root.closingFromHost) root.close()

    ColumnLayout {
      anchors.fill: parent
      spacing: 0
      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 56
        color: root.bg
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 16
          spacing: studioWindow.width < 1000 ? 8 : 18
          DatabaseIcon { Layout.preferredWidth: 26; Layout.preferredHeight: 26 }
          Text { text: "DB Studio"; color: root.ink; font.family: Style.font.family; font.pixelSize: Math.max(21, Style.font.heading + 4); font.bold: true }
          HeaderButton {
            objectName: "toggleBrowserButton"
            implicitWidth: 36
            contentItem: Canvas {
              implicitWidth: 18; implicitHeight: 18
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.strokeStyle = root.ink; ctx.lineWidth = 1.5
                var left = (width - 18) / 2, top = (height - 16) / 2
                ctx.beginPath(); ctx.rect(left, top, 18, 16)
                ctx.moveTo(left + 6, top); ctx.lineTo(left + 6, top + 16); ctx.stroke()
              }
            }
            Accessible.name: root.activeWorkspace && root.activeWorkspace.sidebarVisible ? "Hide schema browser" : "Show schema browser"
            ToolTip.visible: hovered
            ToolTip.text: "Toggle schema browser (Ctrl+B)"
            onClicked: if (root.activeWorkspace) root.activeWorkspace.sidebarVisible = !root.activeWorkspace.sidebarVisible
          }
          Item { Layout.fillWidth: true }
          HeaderButton { objectName: "manageConnectionsButton"; text: "Connections"; onClicked: root.manageConnections() }
          HeaderButton { text: "Schema diff"; onClicked: { var item = root.ensureWorkspace(); if (root.startWorkers) item.startWorker(); item.openDiffDialog() } }
          HeaderButton { text: "Settings"; onClicked: root.ensureWorkspace().openSettings() }
        }
      }
      Rectangle {
        objectName: "connectionTabStrip"
        Layout.fillWidth: true
        Layout.preferredHeight: 50
        color: root.connectionStrip
        border.color: root.line
        border.width: 1
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 6
          anchors.rightMargin: 6
          spacing: 6
          Flickable {
            id: connectionScroll
            objectName: "connectionTabScroll"
            Layout.preferredWidth: Math.max(0, Math.min(contentWidth, parent.width - 48))
            Layout.minimumWidth: 0
            Layout.fillHeight: true
            contentWidth: connectionRow.implicitWidth
            contentHeight: height
            onWidthChanged: Qt.callLater(root.ensureActiveConnectionVisible)
            onContentWidthChanged: Qt.callLater(root.ensureActiveConnectionVisible)
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
            Row {
              id: connectionRow
              height: parent.height
              spacing: 6
              Repeater {
                id: connectionRepeater
                model: root.workspaces
                delegate: Rectangle {
                  id: connectionTab
                  objectName: "connectionTab_" + modelData.workspaceId
                  required property var modelData
                  readonly property bool selectedConnection: root.activeWorkspaceId === modelData.workspaceId
                  onXChanged: if (selectedConnection) Qt.callLater(root.ensureActiveConnectionVisible)
                  onWidthChanged: if (selectedConnection) Qt.callLater(root.ensureActiveConnectionVisible)
                  width: Math.min(350, Math.max(180, connectionName.implicitWidth + 88))
                  height: connectionRow.height - 6
                  y: 3
                  radius: 5
                  color: selectedConnection ? root.activeConnection : Qt.tint(root.connectionStrip, Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.035))
                  border.width: 1
                  border.color: selectedConnection ? root.accent : root.line
                  activeFocusOnTab: true
                  Accessible.role: Accessible.PageTab
                  Accessible.name: root.connectionLabel(modelData)
                  Accessible.selected: selectedConnection
                  Keys.onReturnPressed: root.activateWorkspace(modelData.workspaceId)
                  Keys.onSpacePressed: root.activateWorkspace(modelData.workspaceId)
                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) { root.contextWorkspaceId = connectionTab.modelData.workspaceId; connectionMenu.popup(this, mouse.x, mouse.y) }
                      else root.activateWorkspace(connectionTab.modelData.workspaceId)
                    }
                  }
                  HoverHandler { id: connectionHover }
                  ToolTip {
                    id: connectionTip
                    visible: connectionHover.hovered && !browserToggle.hovered
                    delay: 600
                    text: root.connectionLabel(connectionTab.modelData)
                    contentItem: Text { text: connectionTip.text; textFormat: Text.PlainText; color: root.ink; font.family: Style.font.family }
                    background: Rectangle { color: root.raised; border.color: root.line; border.width: 1; radius: 4 }
                  }
                  Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 3; color: root.accent; visible: connectionTab.selectedConnection }
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 34
                    spacing: 6
                    ToolButton {
                      id: browserToggle
                      objectName: "toggleConnectionBrowser_" + connectionTab.modelData.workspaceId
                      Layout.preferredWidth: 28
                      Layout.preferredHeight: 30
                      hoverEnabled: true
                      checkable: true
                      checked: connectionTab.modelData.sidebarVisible
                      Accessible.name: (checked ? "Hide browser for " : "Show browser for ") + root.connectionLabel(connectionTab.modelData)
                      ToolTip.visible: hovered
                      ToolTip.delay: 300
                      ToolTip.text: (checked ? "Hide browser" : "Show browser") + " (Ctrl+B)"
                      HoverHandler { cursorShape: Qt.PointingHandCursor }
                      contentItem: Item {
                        Rectangle {
                          anchors.centerIn: parent
                          width: 10; height: 10; radius: 5
                          color: connectionTab.modelData.connectionId ? "#58c89a" : connectionTab.modelData.connecting ? "#e3bb73" : root.softInk
                        }
                      }
                      background: Rectangle {
                        radius: 5
                        color: browserToggle.hovered ? root.raised : browserToggle.checked ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : "transparent"
                        border.width: browserToggle.activeFocus ? 2 : browserToggle.hovered || browserToggle.checked ? 1 : 0
                        border.color: browserToggle.activeFocus ? root.accent : root.line
                      }
                      onClicked: {
                        if (root.activateWorkspace(connectionTab.modelData.workspaceId))
                          connectionTab.modelData.sidebarVisible = !connectionTab.modelData.sidebarVisible
                      }
                    }
                    Text { id: connectionName; Layout.fillWidth: true; text: root.connectionLabel(connectionTab.modelData); textFormat: Text.PlainText; color: root.ink; font.family: Style.font.family; font.pixelSize: Math.max(13, Style.font.bodySmall); font.bold: connectionTab.selectedConnection; elide: Text.ElideRight }
                    BusyIndicator { Layout.preferredWidth: 16; Layout.preferredHeight: 16; running: connectionTab.modelData.hasRunningWork(); visible: running }
                  }
                  ToolButton {
                    objectName: "closeConnection_" + connectionTab.modelData.workspaceId
                    anchors.right: parent.right
                    anchors.rightMargin: 3
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28; height: 30
                    text: "×"
                    Accessible.name: "Close connection " + root.connectionLabel(connectionTab.modelData)
                    contentItem: Text { text: "×"; color: root.softInk; font.pixelSize: 20; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { radius: 4; color: parent.hovered ? root.raised : "transparent"; border.width: parent.activeFocus ? 1 : 0; border.color: root.accent }
                    onClicked: root.closeWorkspace(connectionTab.modelData.workspaceId)
                  }
                }
              }
            }
          }
          HeaderButton { objectName: "newConnectionButton"; implicitWidth: 36; font.pixelSize: 24; text: "+"; Accessible.name: "Open connection"; onClicked: root.manageConnections() }
          Item { Layout.fillWidth: true }
        }
      }
      Item { id: workspaceContainer; objectName: "connectionWorkspaceContainer"; Layout.fillWidth: true; Layout.fillHeight: true }
      Rectangle {
        objectName: "connectionStatusBar"
        Layout.fillWidth: true
        Layout.preferredHeight: 28
        color: root.activeWorkspace && root.activeWorkspace.noticeError ? Qt.rgba(Theme.Color.urgent.r, Theme.Color.urgent.g, Theme.Color.urgent.b, 0.12) : root.bg
        border.width: 1
        border.color: root.line
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 14
          anchors.rightMargin: 14
          spacing: 10
          Rectangle { Layout.preferredWidth: 8; Layout.preferredHeight: 8; radius: 4; color: root.activeWorkspace && root.activeWorkspace.connectionId ? "#58c89a" : root.softInk }
          Text {
            Layout.maximumWidth: studioWindow.width * 0.5
            text: root.activeWorkspace && root.activeWorkspace.connectionId ? root.connectionLabel(root.activeWorkspace) : "Not connected"
            textFormat: Text.PlainText
            color: root.softInk; font.family: Style.font.family; font.pixelSize: Math.max(11, Style.font.caption); elide: Text.ElideRight
          }
          Item { Layout.fillWidth: true }
          Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: root.activeWorkspace ? root.activeWorkspace.notice : ""
            textFormat: Text.PlainText
            color: root.activeWorkspace && root.activeWorkspace.noticeError ? Theme.Color.urgent : root.softInk
            font.family: Style.font.family; font.pixelSize: Math.max(11, Style.font.caption); elide: Text.ElideRight
          }
        }
      }
    }
    Menu {
      id: connectionMenu
      objectName: "connectionTabMenu"
      parent: studioWindow.contentItem
      width: 200
      background: Rectangle { color: root.bg; border.color: root.line; border.width: 1; radius: 5 }
      PlainMenuItem { text: "New session"; enabled: { var item = root.workspace(root.contextWorkspaceId); return !!item && !!(item.activeProfile || item.requestedProfile) } onTriggered: root.newSession(root.contextWorkspaceId) }
      PlainMenuItem { text: "Reconnect"; enabled: { var item = root.workspace(root.contextWorkspaceId); return !!item && !item.connecting && !!(item.activeProfile || item.requestedProfile) } onTriggered: root.reconnectWorkspace(root.contextWorkspaceId) }
      PlainMenuItem { text: "Manage connections…"; onTriggered: root.manageConnections() }
      PlainMenuItem { text: "Close connection"; onTriggered: root.closeWorkspace(root.contextWorkspaceId) }
    }
    Dialog {
      id: closeDialog
      objectName: "closeConnectionDialog"
      parent: studioWindow.contentItem
      anchors.centerIn: parent
      width: Math.min(560, studioWindow.width - 40)
      modal: true
      padding: 20
      title: root.closeWholeApp ? "Close DB Studio?" : "Close connection?"
      background: Rectangle { color: root.bg; border.color: root.accent; border.width: 1; radius: 7 }
      contentItem: ColumnLayout {
        spacing: 18
        Text { Layout.fillWidth: true; text: "Review unsaved SQL and row changes before closing. Running operations for the closed connections will be cancelled."; color: root.ink; font.family: Style.font.family; wrapMode: Text.WordWrap }
        RowLayout {
          Layout.fillWidth: true
          HeaderButton { objectName: "cancelConnectionClose"; text: "Cancel"; onClicked: closeDialog.close() }
          Item { Layout.fillWidth: true }
          HeaderButton { objectName: "reviewConnectionClose"; text: "Review changes"; onClicked: root.reviewBeforeClose() }
          HeaderButton { objectName: "discardConnectionClose"; text: "Close and discard"; onClicked: root.confirmClose() }
        }
      }
    }
  }
}
