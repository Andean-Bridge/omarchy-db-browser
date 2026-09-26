pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  property bool closingFromHost: false
  property bool workerReady: false
  property bool workerHasStarted: false
  property bool stoppingWorker: false
  property var queuedRequests: []
  property var pendingRequests: ({})
  property int nextRequestId: 1
  property string notice: ""
  property bool noticeError: false

  property var profiles: []
  property var activeProfile: null
  property string connectionId: ""
  property bool connecting: false
  property int connectionAttemptGeneration: 0
  property var databases: []
  property bool databasesLoading: false
  property bool databaseListLimited: false
  property bool databasePickerExpanded: false
  property string databaseSearch: ""
  property bool databaseSwitching: false
  property string databaseError: ""
  property int databaseLoadGeneration: 0
  property bool schemaLoading: false
  property string schemaError: ""
  property int schemaLoadGeneration: 0
  property var schemas: []
  property var objectsBySchema: Object.create(null)
  property var expandedSchemas: Object.create(null)
  property string objectSearch: ""
  property var selectedObject: null
  property var inspectorDefinition: null
  property int inspectorLoadGeneration: 0

  property var tabs: [{ id: "query-1", kind: "query", title: "Query 1", sql: "", columns: [], rows: [], durationMs: 0, rowCount: 0, hasMore: false, busy: false, error: "", message: "", pendingId: 0 }]
  property string activeTabId: "query-1"
  property int nextTabId: 2
  readonly property var activeTab: tabs.find(function(tab) { return tab.id === activeTabId }) || null
  property string resultPane: "results"
  property bool resultsExpanded: false
  property bool syncingEditor: false
  property int rowLimit: 100
  property int settingsVersion: 0
  property int timeoutMs: 30000
  property string editingProfileId: ""
  property bool editingHasStoredConnection: false
  property string deleteProfileId: ""

  readonly property color bg: Color.popups.background
  readonly property color ink: Color.popups.text
  readonly property color softInk: Qt.rgba(ink.r, ink.g, ink.b, 0.62)
  readonly property color faintInk: Qt.rgba(ink.r, ink.g, ink.b, 0.42)
  readonly property color accent: Color.accent
  readonly property color line: Qt.rgba(ink.r, ink.g, ink.b, 0.13)
  readonly property color surface: Qt.tint(bg, Qt.rgba(ink.r, ink.g, ink.b, 0.03))
  readonly property color raised: Qt.tint(bg, Qt.rgba(ink.r, ink.g, ink.b, 0.07))
  readonly property color selected: Qt.rgba(accent.r, accent.g, accent.b, 0.14)
  readonly property string uiFont: Style.font.family
  readonly property string codeFont: "monospace"
  readonly property string workerPath: decodeURIComponent(Qt.resolvedUrl("backend/worker.mjs").toString().replace(/^file:\/\//, ""))
  readonly property var engineOptions: [
    { label: "Azure SQL", value: "azure_sql", port: "1433" },
    { label: "SQL Server", value: "sqlserver", port: "1433" },
    { label: "PostgreSQL", value: "postgres", port: "5432" },
    { label: "MySQL", value: "mysql", port: "3306" }
  ]

  function engineName(type) {
    var found = engineOptions.find(function(entry) { return entry.value === type })
    return found ? found.label : String(type || "Database")
  }
  function supportsDatabaseSwitch() {
    return !!activeProfile && (activeProfile.type === "azure_sql" || activeProfile.type === "sqlserver")
  }
  function icon(name) { return Quickshell.iconPath(name) }
  function editorScrollY() {
    var viewport = sqlScroll.contentItem
    var position = viewport ? viewport["contentY"] : 0
    return typeof position === "number" ? position : 0
  }
  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    stoppingWorker = false
    if (!worker.running) worker.running = true
    else if (workerReady) refreshProfiles()
  }
  function close() {
    closingFromHost = true
    window.visible = false
    stoppingWorker = true
    connectionAttemptGeneration++
    worker.running = false
    workerReady = false
    connectionId = ""
    activeProfile = null
    clearDatabaseState()
    closingFromHost = false
  }
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("andean-bridge.db-browser")
    else close()
  }
  function request(action, payload, callback) {
    var id = nextRequestId++
    var next = Object.assign({}, pendingRequests)
    next[id] = { action: action, callback: callback }
    pendingRequests = next
    queuedRequests.push(JSON.stringify({ id: id, action: action, payload: payload || {} }))
    flushRequests()
    return id
  }
  function flushRequests() {
    if (!workerReady) return
    while (queuedRequests.length > 0) {
      var line = queuedRequests.shift()
      worker.write(line + "\n")
    }
  }
  function handleLine(line) {
    var response
    try {
      response = JSON.parse(String(line || "").trim())
      if (!response || typeof response !== "object" || typeof response.id !== "number") throw new Error("Invalid response")
    }
    catch (_) {
      var error = "Database worker returned an invalid response. Retry the operation."
      var waiting = pendingRequests
      pendingRequests = ({})
      queuedRequests = []
      Object.keys(waiting).forEach(function(id) {
        if (waiting[id].callback) waiting[id].callback(null, error)
      })
      showNotice(error, true)
      return
    }
    var entry = pendingRequests[response.id]
    if (!entry) return
    var next = Object.assign({}, pendingRequests)
    delete next[response.id]
    pendingRequests = next
    if (!response.ok) {
      var error = String(response.error || "Unknown database error")
      if (entry.action !== "table.rows" && entry.action !== "table.describe" && !/cancel/i.test(error)) showNotice(error, true)
      if (entry.callback) entry.callback(null, error)
      return
    }
    if (entry.callback) entry.callback(response.data || {}, "")
  }
  function showNotice(message, isError) {
    notice = String(message || "")
    noticeError = !!isError
  }
  function refreshProfiles() {
    request("profiles.list", {}, function(data, error) {
      if (error) return
      profiles = data.profiles || []
      if (activeProfile) {
        var found = profiles.find(function(profile) { return profile.id === activeProfile.id })
        if (found) activeProfile = Object.assign({}, activeProfile, found, {
          database: activeProfile.database,
          transportSecure: activeProfile.transportSecure,
          localConnection: activeProfile.localConnection
        })
      }
    })
  }
  function loadSettings() {
    var version = settingsVersion
    request("settings.get", {}, function(data, error) {
      if (error || version !== settingsVersion) return
      var value = Number(data.defaultLimit)
      if (Number.isInteger(value) && value >= 1 && value <= 1000) rowLimit = value
    })
  }
  function setRowLimit(value) {
    var nextLimit = Number(value)
    if (!Number.isInteger(nextLimit) || nextLimit < 1 || nextLimit > 1000 || nextLimit === rowLimit) return
    var previous = rowLimit
    var version = ++settingsVersion
    rowLimit = nextLimit
    request("settings.save", { defaultLimit: nextLimit }, function(data, error) {
      if (version !== settingsVersion) return
      if (error) {
        rowLimit = previous
        showNotice("Could not save the default row limit.", true)
        return
      }
      rowLimit = data.defaultLimit
      if (activeTab && activeTab.kind === "table") loadTableRows(activeTab.id, 0)
    })
  }
  function clearDatabaseState() {
    schemaLoadGeneration++
    databaseLoadGeneration++
    inspectorLoadGeneration++
    if (workerReady && !stoppingWorker) {
      tabs.forEach(function(tab) {
        if (tab.kind === "table" && tab.pendingRowsId) request("query.cancel", { targetId: tab.pendingRowsId }, function() {})
      })
    }
    schemaLoading = false
    schemaError = ""
    databases = []
    databasesLoading = false
    databaseListLimited = false
    databasePickerExpanded = false
    databaseSearch = ""
    databaseSwitching = false
    databaseError = ""
    schemas = []
    objectsBySchema = Object.create(null)
    expandedSchemas = Object.create(null)
    objectSearch = ""
    selectedObject = null
    inspectorDefinition = null
    tabs = tabs.filter(function(tab) { return tab.kind === "query" }).map(function(tab) {
      return Object.assign({}, tab, { columns: [], rows: [], rowCount: 0, hasMore: false, durationMs: 0, busy: false, error: "", message: "", pendingId: 0 })
    })
    if (tabs.length === 0) {
      var id = "query-" + nextTabId++
      tabs = [{ id: id, kind: "query", title: "Query " + (nextTabId - 1), sql: "", columns: [], rows: [], rowCount: 0, hasMore: false, durationMs: 0, busy: false, error: "", message: "", pendingId: 0 }]
    }
    if (!tabs.some(function(tab) { return tab.id === activeTabId })) activeTabId = tabs[0].id
    resultsExpanded = false
  }
  function disconnect() {
    connectionAttemptGeneration++
    if (!connectionId) return
    var oldId = connectionId
    connectionId = ""
    activeProfile = null
    clearDatabaseState()
    request("connection.close", { connectionId: oldId }, function() {})
    showNotice("Disconnected", false)
  }
  function openProfile(profile, password) {
    if (!profile) return
    var attempt = ++connectionAttemptGeneration
    var proceed = function() {
      if (attempt !== connectionAttemptGeneration) return
      connecting = true
      showNotice("Connecting to " + profile.name + "…", false)
      var payload = { profileId: profile.id }
      if (password) payload.password = password
      request("connection.open", payload, function(data, error) {
        if (attempt !== connectionAttemptGeneration) {
          if (data && data.connectionId) request("connection.close", { connectionId: data.connectionId }, function() {})
          return
        }
        connecting = false
        if (error) {
          if (!profile.hasStoredConnection && error.indexOf("Enter connection details") !== -1) {
            editingProfileId = profile.id || ""
            prepareConnectionForm(profile)
            formError.text = "Enter the connection details again to reconnect."
            connectionDialog.open()
          }
          return
        }
        connectionId = data.connectionId || ""
        activeProfile = Object.assign({}, profile, data.profile || {})
        showNotice("Connected to " + activeProfile.name, false)
        loadSchema()
      })
    }
    if (connectionId) {
      var oldId = connectionId
      connectionId = ""
      clearDatabaseState()
      request("connection.close", { connectionId: oldId }, function() { proceed() })
    } else proceed()
  }
  function loadDatabases() {
    if (!databasePickerExpanded || !connectionId || !supportsDatabaseSwitch()) return
    var currentConnectionId = connectionId
    var generation = ++databaseLoadGeneration
    databasesLoading = true
    databaseError = ""
    request("databases.list", { connectionId: currentConnectionId }, function(data, error) {
      if (generation !== databaseLoadGeneration || currentConnectionId !== connectionId) return
      databasesLoading = false
      if (error) { databaseError = error; return }
      if (!Array.isArray(data.databases)) { databaseError = "Could not read the database list."; return }
      databases = data.databases.filter(function(item) { return item && typeof item.name === "string" && item.name !== "" })
      databaseListLimited = !!data.limited
    })
  }
  function filteredDatabases() {
    var needle = databaseSearch.toLowerCase().trim()
    return needle ? databases.filter(function(item) { return item.name.toLowerCase().includes(needle) }) : databases
  }
  function toggleDatabasePicker() {
    if (!connectionId || !supportsDatabaseSwitch() || databaseSwitching) return
    databasePickerExpanded = !databasePickerExpanded
    if (databasePickerExpanded && databases.length === 0 && !databasesLoading) loadDatabases()
  }
  function switchDatabase(name) {
    var target = String(name || "").trim()
    if (!target || !connectionId || !supportsDatabaseSwitch() || databaseSwitching) return
    if (activeProfile && target.toLowerCase() === String(activeProfile.database || "").toLowerCase()) {
      databasePickerExpanded = false
      databaseSearch = ""
      return
    }
    var currentConnectionId = connectionId
    databaseSwitching = true
    databaseError = ""
    showNotice("Opening " + target + "…", false)
    request("connection.switchDatabase", { connectionId: currentConnectionId, database: target }, function(data, error) {
      if (currentConnectionId !== connectionId) {
        if (data && data.connectionId && data.connectionId !== currentConnectionId) request("connection.close", { connectionId: data.connectionId }, function() {})
        return
      }
      databaseSwitching = false
      if (error) { databaseError = error; return }
      if (!data.connectionId || !data.profile) { databaseError = "Could not open the selected database."; return }
      clearDatabaseState()
      connectionId = data.connectionId
      activeProfile = Object.assign({}, activeProfile, data.profile)
      databaseNameInput.text = ""
      showNotice("Connected to " + activeProfile.database, false)
      loadSchema()
    })
  }
  function loadSchema() {
    if (!connectionId) return
    var currentConnectionId = connectionId
    var generation = ++schemaLoadGeneration
    var previousExpanded = expandedSchemas
    schemaLoading = true
    schemaError = ""
    request("schemas.list", { connectionId: currentConnectionId }, function(data, error) {
      if (generation !== schemaLoadGeneration || currentConnectionId !== connectionId) return
      if (error) { schemaLoading = false; schemaError = error; return }
      if (!Array.isArray(data.schemas)) {
        schemaLoading = false
        schemaError = "Could not read the schema list."
        return
      }
      schemas = data.schemas
      request("objects.list", { connectionId: currentConnectionId }, function(objectsData, objectsError) {
        if (generation !== schemaLoadGeneration || currentConnectionId !== connectionId) return
        schemaLoading = false
        if (objectsError) { schemaError = objectsError; return }
        if (!Array.isArray(objectsData.objects)) {
          schemaError = "Could not read the table list."
          return
        }
        var grouped = Object.create(null)
        var all = objectsData.objects
        for (var i = 0; i < all.length; i++) {
          var object = all[i]
          var schema = String(object.schema || "")
          if (!grouped[schema]) grouped[schema] = []
          grouped[schema].push(object)
        }
        for (var key in grouped) grouped[key].sort(function(a, b) { return a.name.localeCompare(b.name) })
        objectsBySchema = grouped
        var expanded = Object.create(null)
        for (var name in previousExpanded) {
          if (previousExpanded[name] && schemas.some(function(schema) { return schema.name === name })) expanded[name] = true
        }
        var hasVisibleObjects = Object.keys(expanded).some(function(name) { return (grouped[name] || []).length > 0 })
        if (!hasVisibleObjects) {
          var preferred = schemas.find(function(schema) { return schema.name.toLowerCase() === "dbo" && (grouped[schema.name] || []).length > 0 })
            || schemas.find(function(schema) { return (grouped[schema.name] || []).length > 0 })
          if (preferred) expanded[preferred.name] = true
        }
        expandedSchemas = expanded
      })
    })
  }
  function filteredObjects(schemaName) {
    var list = objectsBySchema[schemaName] || []
    var needle = objectSearch.toLowerCase().trim()
    if (schemaName.toLowerCase().includes(needle)) return list
    return needle ? list.filter(function(object) { return object.name.toLowerCase().includes(needle) || object.type.toLowerCase().includes(needle) }) : list
  }
  function filteredSchemas() {
    var needle = objectSearch.toLowerCase().trim()
    return schemas.filter(function(schema) {
      if ((objectsBySchema[schema.name] || []).length === 0) return false
      return !needle || schema.name.toLowerCase().includes(needle) || filteredObjects(schema.name).length > 0
    })
  }
  function visibleSchemaEntries() {
    var entries = []
    var visible = filteredSchemas()
    for (var i = 0; i < visible.length; i++) {
      var name = visible[i].name
      entries.push({ kind: "schema", name: name, count: (objectsBySchema[name] || []).length })
      if (schemaExpanded(name)) {
        var children = filteredObjects(name)
        for (var j = 0; j < children.length; j++) entries.push({ kind: "object", object: children[j] })
      }
    }
    return entries
  }
  function schemaExpanded(name) { return !!expandedSchemas[name] || objectSearch.trim() !== "" }
  function toggleSchema(name) {
    var next = Object.assign(Object.create(null), expandedSchemas)
    next[name] = !next[name]
    expandedSchemas = next
  }
  function updateTab(id, patch) {
    tabs = tabs.map(function(tab) { return tab.id === id ? Object.assign({}, tab, patch) : tab })
  }
  function syncEditor() {
    if (!sqlEditor) return
    syncingEditor = true
    var desired = activeTab && activeTab.kind === "query" ? activeTab.sql : ""
    if (sqlEditor.text !== desired) sqlEditor.text = desired
    syncingEditor = false
  }
  onActiveTabIdChanged: { resultsExpanded = false; syncEditor() }
  function newQuery(sql, title) {
    var id = "query-" + nextTabId++
    tabs = tabs.concat([{ id: id, kind: "query", title: title || ("Query " + (nextTabId - 1)), sql: sql || "", columns: [], rows: [], durationMs: 0, rowCount: 0, hasMore: false, busy: false, error: "", message: "", pendingId: 0 }])
    activeTabId = id
    resultPane = "results"
  }
  function closeTab(id) {
    var tab = tabs.find(function(entry) { return entry.id === id })
    if (tab && tab.pendingId) request("query.cancel", { targetId: tab.pendingId }, function() {})
    if (tab && tab.pendingRowsId) request("query.cancel", { targetId: tab.pendingRowsId }, function() {})
    var currentIndex = tabs.findIndex(function(entry) { return entry.id === id })
    tabs = tabs.filter(function(entry) { return entry.id !== id })
    if (tabs.length === 0) { newQuery(); return }
    if (activeTabId === id) activeTabId = tabs[Math.max(0, currentIndex - 1)].id
  }
  function runQuery() {
    var tab = activeTab
    if (!tab || tab.kind !== "query" || tab.busy) return
    if (!connectionId) { showNotice("Connect to a database first", true); return }
    var sql = String(tab.sql || "").trim()
    if (!sql) { showNotice("Write a query before running it", true); return }
    var tabId = tab.id
    var queryConnectionId = connectionId
    updateTab(tabId, { busy: true, error: "", message: "Running query…", columns: [], rows: [] })
    resultPane = "results"
    var requestId = request("query.run", { connectionId: queryConnectionId, sql: sql, limit: rowLimit, timeoutMs: timeoutMs }, function(data, error) {
      if (queryConnectionId !== connectionId) return
      var currentTab = tabs.find(function(entry) { return entry.id === tabId })
      if (!currentTab || currentTab.pendingId !== requestId) return
      if (error) {
        var cancelled = /cancel/i.test(error)
        updateTab(tabId, { busy: false, pendingId: 0, error: cancelled ? "" : error, message: cancelled ? "Query cancelled" : error })
        if (cancelled) showNotice("Query cancelled", false)
        return
      }
      updateTab(tabId, { busy: false, pendingId: 0, columns: data.columns || [], rows: data.rows || [], rowCount: data.rowCount || 0, hasMore: !!data.hasMore, durationMs: data.durationMs || 0, message: data.message || "Query completed" })
      showNotice("Query completed", false)
    })
    updateTab(tabId, { pendingId: requestId })
  }
  function cancelQuery() {
    var tab = activeTab
    if (!tab || !tab.pendingId) return
    request("query.cancel", { targetId: tab.pendingId }, function(_, error) {
      if (!error) updateTab(tab.id, { message: "Cancelling query…" })
    })
  }
  function quoteName(name) {
    var type = activeProfile ? activeProfile.type : ""
    if (type === "postgres") return '"' + String(name).replace(/"/g, '""') + '"'
    if (type === "mysql") return '`' + String(name).replace(/`/g, '``') + '`'
    return '[' + String(name).replace(/\]/g, ']]') + ']'
  }
  function queryTable(table) {
    if (!table) return
    var path = quoteName(table.schema) + "." + quoteName(table.name)
    var sql = activeProfile && (activeProfile.type === "azure_sql" || activeProfile.type === "sqlserver")
      ? "SELECT TOP (" + rowLimit + ") *\nFROM " + path + ";"
      : "SELECT *\nFROM " + path + "\nLIMIT " + rowLimit + ";"
    newQuery(sql, table.name + " query")
  }
  function tableTabId(object) { return "table:" + JSON.stringify([object.schema, object.name]) }
  function openTable(object) {
    if (!connectionId) return
    selectedObject = object
    var id = tableTabId(object)
    if (!tabs.some(function(tab) { return tab.id === id })) {
      tabs = tabs.concat([{ id: id, kind: "table", title: object.name, object: object, tablePane: "data", columns: [], rows: [], hasMore: false, offset: 0, definition: null, busy: false, pendingRowsId: 0, definitionRequestId: 0, error: "" }])
    }
    activeTabId = id
    inspectObject(object)
    loadTableRows(id, 0)
  }
  function inspectObject(object) {
    if (!object || !connectionId) return
    var currentConnectionId = connectionId
    var generation = ++inspectorLoadGeneration
    selectedObject = object
    inspectorDefinition = null
    var tabId = tableTabId(object)
    var requestId = request("table.describe", { connectionId: currentConnectionId, schema: object.schema, name: object.name }, function(data, error) {
      if (currentConnectionId !== connectionId || generation !== inspectorLoadGeneration) return
      if (!selectedObject || tableTabId(selectedObject) !== tabId) return
      if (error) { showNotice(error, true); return }
      inspectorDefinition = data
      var currentTab = tabs.find(function(tab) { return tab.id === tabId })
      if (currentTab && currentTab.definitionRequestId === requestId) updateTab(tabId, { definition: data, definitionRequestId: 0 })
    })
    if (tabs.some(function(tab) { return tab.id === tabId })) updateTab(tabId, { definitionRequestId: requestId })
  }
  function loadTableRows(tabId, offset) {
    var tab = tabs.find(function(entry) { return entry.id === tabId })
    if (!tab || !tab.object || !connectionId) return
    var currentConnectionId = connectionId
    if (tab.pendingRowsId) request("query.cancel", { targetId: tab.pendingRowsId }, function() {})
    updateTab(tabId, { busy: true, error: "" })
    var requestId = request("table.rows", { connectionId: currentConnectionId, schema: tab.object.schema, name: tab.object.name, limit: rowLimit, offset: offset }, function(data, error) {
      if (currentConnectionId !== connectionId) return
      var currentTab = tabs.find(function(entry) { return entry.id === tabId })
      if (!currentTab || currentTab.pendingRowsId !== requestId) return
      if (error) {
        updateTab(tabId, { busy: false, pendingRowsId: 0, error: /cancel/i.test(error) ? "" : error })
        if (/cancel/i.test(error)) showNotice("Table load cancelled", false)
        return
      }
      updateTab(tabId, { busy: false, pendingRowsId: 0, columns: data.columns || [], rows: data.rows || [], hasMore: !!data.hasMore, offset: data.offset || 0 })
    })
    updateTab(tabId, { pendingRowsId: requestId })
  }
  function cancelTableRows(tabId) {
    var tab = tabs.find(function(entry) { return entry.id === tabId })
    if (tab && tab.pendingRowsId) request("query.cancel", { targetId: tab.pendingRowsId }, function() {})
  }
  function prepareConnectionForm(profile) {
    var candidate = profile || {}
    editingHasStoredConnection = !!candidate.hasStoredConnection
    connectionName.text = candidate.name || ""
    var index = engineOptions.findIndex(function(entry) { return entry.value === candidate.type })
    enginePicker.currentIndex = index >= 0 ? index : 0
    hostInput.text = ""
    portInput.text = profile ? "" : engineOptions[enginePicker.currentIndex].port
    databaseInput.text = ""
    userInput.text = ""
    passwordInput.text = ""
    connectionStringInput.text = ""
    rememberCheck.checked = profile ? !!profile.hasStoredConnection : true
    sslCheck.checked = true
    formError.text = ""
  }
  function addConnection() {
    editingProfileId = ""
    prepareConnectionForm(null)
    connectionDialog.open()
  }
  function saveConnection() {
    var name = connectionName.text.trim()
    var raw = connectionStringInput.text.trim()
    if (!name) { formError.text = "Give this connection a name"; return }
    var hasStructured = !!(hostInput.text.trim() || databaseInput.text.trim() || userInput.text.trim() || passwordInput.text)
    var renameOnly = !!editingProfileId && !raw && !hasStructured
    if (!raw && !renameOnly && !hostInput.text.trim()) { formError.text = "Enter a host or paste a connection string"; return }
    if (!raw && !renameOnly && !databaseInput.text.trim()) { formError.text = "Enter a database name"; return }
    if (raw && passwordInput.text) { formError.text = "Use either a complete connection string or the password field"; return }
    var type = engineOptions[enginePicker.currentIndex].value
    var secret = passwordInput.text
    var payload = {
      profile: { id: editingProfileId || undefined, name: name, type: type,
        host: hostInput.text.trim(), port: Number(portInput.text) || undefined,
        database: databaseInput.text.trim(), user: userInput.text.trim(),
        ssl: sslCheck.checked, encrypt: type === "azure_sql" ? true : sslCheck.checked,
        trustServerCertificate: false },
      savePassword: rememberCheck.checked
    }
    if (raw) payload.connectionString = raw
    if (secret) payload.password = secret
    formError.text = "Saving connection…"
    request("profiles.save", payload, function(data, error) {
      if (error) { formError.text = error; return }
      // Clear both masked inputs as soon as the worker accepts the profile.
      passwordInput.text = ""
      connectionStringInput.text = ""
      connectionDialog.close()
      editingProfileId = ""
      refreshProfiles()
      if (data.warning) showNotice(data.warning, false)
      if (data.profile) {
        if (renameOnly && activeProfile && activeProfile.id === data.profile.id) activeProfile = Object.assign({}, activeProfile, data.profile)
        else openProfile(data.profile, secret || undefined)
      }
    })
  }
  function deleteProfile(profile) {
    if (!profile) return
    deleteProfileId = profile.id
    deleteDialog.open()
  }
  function duplicateProfile(profile) {
    if (!profile) return
    request("profiles.duplicate", { profileId: profile.id }, function(data, error) {
      if (error) return
      refreshProfiles()
      showNotice("Duplicated as " + (data.profile ? data.profile.name : "a new connection"), false)
    })
  }
  function confirmDeleteProfile() {
    var id = deleteProfileId
    deleteDialog.close()
    deleteProfileId = ""
    if (!id) return
    if (activeProfile && activeProfile.id === id) disconnect()
    request("profiles.delete", { profileId: id }, function(_, error) {
      if (!error) { refreshProfiles(); showNotice("Connection removed", false) }
    })
  }

  Process {
    id: worker
    command: ["node", root.workerPath]
    stdinEnabled: true
    stdout: SplitParser { onRead: data => root.handleLine(data) }
    stderr: SplitParser { onRead: data => { /* Never echo worker output; it may contain connection details. */ } }
    onStarted: {
      root.workerHasStarted = true
      root.workerReady = true
      root.flushRequests()
      root.refreshProfiles()
      root.loadSettings()
    }
    onRunningChanged: {
      if (!running && root.workerHasStarted) {
        root.workerHasStarted = false
        root.workerReady = false
        root.pendingRequests = ({})
        root.queuedRequests = []
        root.connectionId = ""
        root.activeProfile = null
        root.clearDatabaseState()
        if (!root.stoppingWorker) root.showNotice("Database worker stopped. Reopen DB Studio to retry.", true)
      }
    }
  }

  component StudioIcon: Item {
    id: iconRoot
    required property string iconName
    readonly property color iconColor: root.softInk
    onIconNameChanged: iconCanvas.requestPaint()
    onIconColorChanged: iconCanvas.requestPaint()
    Canvas {
      id: iconCanvas
      anchors.fill: parent
      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (!width || !height) return
        ctx.save()
        ctx.translate((width - Math.min(width, height)) / 2, (height - Math.min(width, height)) / 2)
        ctx.scale(Math.min(width, height) / 20, Math.min(width, height) / 20)
        ctx.strokeStyle = iconRoot.iconColor
        ctx.fillStyle = iconRoot.iconColor
        ctx.lineWidth = 1.7
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        ctx.beginPath()
        switch (iconRoot.iconName) {
        case "server-database":
          ctx.moveTo(2, 5); ctx.bezierCurveTo(2, 2, 18, 2, 18, 5)
          ctx.bezierCurveTo(18, 8, 2, 8, 2, 5)
          ctx.moveTo(2, 5); ctx.lineTo(2, 15)
          ctx.bezierCurveTo(2, 18, 18, 18, 18, 15)
          ctx.lineTo(18, 5)
          ctx.moveTo(2, 10); ctx.bezierCurveTo(2, 13, 18, 13, 18, 10)
          break
        case "x-office-spreadsheet":
          ctx.rect(2, 3, 16, 14)
          ctx.moveTo(2, 8); ctx.lineTo(18, 8)
          ctx.moveTo(2, 12.5); ctx.lineTo(18, 12.5)
          ctx.moveTo(7.3, 3); ctx.lineTo(7.3, 17)
          ctx.moveTo(12.6, 3); ctx.lineTo(12.6, 17)
          break
        case "view-list-details":
          for (var y = 4; y <= 16; y += 6) {
            ctx.rect(2, y - 1, 2, 2)
            ctx.moveTo(7, y); ctx.lineTo(18, y)
          }
          break
        case "accessories-text-editor":
          ctx.moveTo(4, 4); ctx.lineTo(16, 4)
          ctx.moveTo(4, 9); ctx.lineTo(16, 9)
          ctx.moveTo(4, 14); ctx.lineTo(12, 14)
          break
        case "text-x-generic":
          ctx.moveTo(4, 2); ctx.lineTo(12, 2); ctx.lineTo(16, 6)
          ctx.lineTo(16, 18); ctx.lineTo(4, 18); ctx.closePath()
          ctx.moveTo(12, 2); ctx.lineTo(12, 6); ctx.lineTo(16, 6)
          ctx.moveTo(7, 10); ctx.lineTo(13, 10)
          ctx.moveTo(7, 13); ctx.lineTo(13, 13)
          break
        case "window-close":
          ctx.moveTo(4, 4); ctx.lineTo(16, 16)
          ctx.moveTo(16, 4); ctx.lineTo(4, 16)
          break
        case "list-add":
          ctx.moveTo(10, 3); ctx.lineTo(10, 17)
          ctx.moveTo(3, 10); ctx.lineTo(17, 10)
          break
        case "media-playback-start":
          ctx.moveTo(5, 3); ctx.lineTo(17, 10); ctx.lineTo(5, 17); ctx.closePath()
          ctx.fill()
          break
        case "process-stop":
          ctx.rect(4, 4, 12, 12); ctx.fill()
          break
        case "view-fullscreen":
          ctx.moveTo(8, 2); ctx.lineTo(2, 2); ctx.lineTo(2, 8)
          ctx.moveTo(12, 2); ctx.lineTo(18, 2); ctx.lineTo(18, 8)
          ctx.moveTo(2, 12); ctx.lineTo(2, 18); ctx.lineTo(8, 18)
          ctx.moveTo(18, 12); ctx.lineTo(18, 18); ctx.lineTo(12, 18)
          break
        case "view-restore":
          ctx.rect(2, 6, 12, 12)
          ctx.moveTo(6, 6); ctx.lineTo(6, 2); ctx.lineTo(18, 2)
          ctx.lineTo(18, 14); ctx.lineTo(14, 14)
          break
        default:
          ctx.arc(10, 10, 5, 0, Math.PI * 2)
        }
        ctx.stroke()
        ctx.restore()
      }
    }
  }
  component StudioButton: Rectangle {
    id: button
    property string label: ""
    property string iconName: ""
    property bool prominent: false
    property bool compact: false
    property bool buttonEnabled: true
    signal clicked()
    implicitWidth: content.implicitWidth + (compact ? 22 : 28)
    implicitHeight: compact ? 34 : 40
    activeFocusOnTab: buttonEnabled
    Accessible.role: Accessible.Button
    Accessible.name: label
    radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 7) : 5
    color: !buttonEnabled ? root.surface : prominent ? root.accent : hovered.hovered ? root.raised : root.surface
    border.width: activeFocus ? 2 : prominent ? 0 : 1
    border.color: activeFocus ? root.accent : root.line
    opacity: buttonEnabled ? 1 : 0.45
    Row {
      id: content
      anchors.centerIn: parent
      spacing: 9
      StudioIcon { width: 16; height: 16; iconName: button.iconName; visible: button.iconName !== "" }
      Text {
        text: button.label
        color: button.prominent ? root.bg : root.ink
        font.family: root.uiFont
        font.pixelSize: Math.max(14, Style.font.body)
        font.bold: button.prominent
      }
    }
    HoverHandler { id: hovered }
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()
    MouseArea { anchors.fill: parent; enabled: button.buttonEnabled; cursorShape: Qt.PointingHandCursor; onClicked: { button.forceActiveFocus(); button.clicked() } }
  }
  component StudioField: TextField {
    id: field
    color: root.ink
    placeholderTextColor: root.faintInk
    selectionColor: root.accent
    selectedTextColor: root.bg
    font.family: root.uiFont
    font.pixelSize: Math.max(14, Style.font.body)
    implicitHeight: 40
    selectByMouse: true
    background: Rectangle {
      color: root.surface
      radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 6) : 4
      border.width: field.activeFocus ? 2 : 1
      border.color: field.activeFocus ? root.accent : root.line
    }
  }
  component StudioCheck: CheckBox {
    id: check
    font.family: root.uiFont
    font.pixelSize: Math.max(14, Style.font.body)
    spacing: 9
    indicator: Rectangle {
      implicitWidth: 19
      implicitHeight: 19
      x: check.leftPadding
      y: (check.height - height) / 2
      radius: 4
      color: check.checked ? root.accent : root.surface
      border.width: 1
      border.color: check.checked ? root.accent : root.line
      Text {
        anchors.centerIn: parent
        text: "✓"
        visible: check.checked
        color: root.bg
        font.family: root.uiFont
        font.pixelSize: 14
        font.bold: true
      }
    }
    contentItem: Text {
      text: check.text
      color: root.ink
      font: check.font
      verticalAlignment: Text.AlignVCenter
      leftPadding: check.indicator.width + check.spacing
    }
  }
  component StudioTab: Rectangle {
    id: tabButton
    property string label: ""
    property string iconName: ""
    property bool selectedTab: false
    signal clicked()
    implicitWidth: tabContent.implicitWidth + 32
    height: 46
    activeFocusOnTab: true
    Accessible.role: Accessible.PageTab
    Accessible.name: label
    color: selectedTab || tabHover.hovered ? root.raised : "transparent"
    border.width: activeFocus ? 2 : 0
    border.color: root.accent
    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 2; visible: tabButton.selectedTab; color: root.accent }
    Row {
      id: tabContent
      anchors.centerIn: parent
      spacing: 9
      StudioIcon { width: 16; height: 16; iconName: tabButton.iconName; visible: tabButton.iconName !== "" }
      Text { text: tabButton.label; color: tabButton.selectedTab ? root.ink : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: tabButton.selectedTab }
    }
    HoverHandler { id: tabHover }
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { tabButton.forceActiveFocus(); tabButton.clicked() } }
  }

  FloatingWindow {
    id: window
    title: "DB Studio"
    color: root.bg
    implicitWidth: 1420
    implicitHeight: 920
    minimumSize: Qt.size(980, 640)
    visible: false
    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("andean-bridge.db-browser")
      else if (!visible && !root.closingFromHost) root.close()
    }

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.resultsExpanded) root.resultsExpanded = false
        else root.requestClose()
      }
      Shortcut { sequence: "Ctrl+N"; onActivated: root.newQuery() }
      Shortcut { sequence: "Ctrl+Return"; onActivated: root.runQuery() }
      Shortcut { sequence: "Ctrl+Enter"; onActivated: root.runQuery() }
      Shortcut { sequence: "Ctrl+F"; onActivated: root.databasePickerExpanded ? databaseSearchField.forceActiveFocus() : searchField.forceActiveFocus() }

      ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 68
          color: root.surface
          border.width: 1
          border.color: root.line
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            spacing: 22
            StudioIcon { Layout.preferredWidth: 27; Layout.preferredHeight: 27; iconName: "server-database" }
            Text { text: "DB Studio"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(22, Style.font.heading + 6); font.bold: true }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 28; color: root.line }
            StudioTab { label: "Workbench"; selectedTab: true; onClicked: {} }
            StudioTab { label: "Connections"; onClicked: connectionListDialog.open() }
            StudioTab { label: "Settings"; onClicked: settingsDialog.open() }
            Item { Layout.fillWidth: true }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.margins: 2
          spacing: 10

          Rectangle {
            Layout.preferredWidth: Math.max(282, Math.min(356, window.width * 0.255))
            Layout.fillHeight: true
            color: root.surface
            radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 9) : 6
            border.width: 1
            border.color: root.line
            clip: true
            ColumnLayout {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 15
              Text { text: "CONNECTION"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1 }
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 68
                color: root.raised
                radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 7) : 5
                border.width: 1
                border.color: root.line
                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 14
                  anchors.rightMargin: 9
                  spacing: 12
                  Rectangle { Layout.preferredWidth: 11; Layout.preferredHeight: 11; radius: 6; color: root.connectionId ? "#58c89a" : root.faintInk }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text { Layout.fillWidth: true; text: root.activeProfile ? root.activeProfile.name : "No connection"; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(15, Style.font.body); font.bold: true; elide: Text.ElideRight }
                    Text { Layout.fillWidth: true; text: root.activeProfile ? root.engineName(root.activeProfile.type) + (root.activeProfile.transportSecure === true ? " · Verified TLS" : root.activeProfile.transportSecure === false ? " · No TLS" : "") : "Choose or add a database"; textFormat: Text.PlainText; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); elide: Text.ElideRight }
                  }
                  StudioButton { label: "Choose"; compact: true; onClicked: connectionListDialog.open() }
                }
              }
              Text { Layout.fillWidth: true; visible: root.connectionId !== "" && !!root.activeProfile && root.activeProfile.transportSecure === false && !root.activeProfile.localConnection; text: "Unencrypted remote connection. Credentials and data may travel in plaintext."; textFormat: Text.PlainText; color: Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 54
                visible: root.connectionId !== "" && root.supportsDatabaseSwitch()
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: "Current database " + (root.activeProfile ? root.activeProfile.database || "" : "") + ". Select another database"
                color: root.databasePickerExpanded ? root.selected : databasePickerHover.hovered ? root.surface : root.raised
                radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 7) : 5
                border.width: activeFocus || root.databasePickerExpanded ? 2 : 1
                border.color: activeFocus || root.databasePickerExpanded ? root.accent : root.line
                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 12
                  anchors.rightMargin: 12
                  spacing: 10
                  StudioIcon { Layout.preferredWidth: 17; Layout.preferredHeight: 17; iconName: "server-database" }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text { text: "DATABASE"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(11, Style.font.caption); font.bold: true; font.letterSpacing: 1.0 }
                    Text { Layout.fillWidth: true; text: root.activeProfile ? root.activeProfile.database || "Select database" : "Select database"; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: true; elide: Text.ElideRight }
                  }
                  Text { text: root.databasePickerExpanded ? "⌃" : "⌄"; color: root.softInk; font.family: root.uiFont; font.pixelSize: 20 }
                }
                HoverHandler { id: databasePickerHover }
                Keys.onReturnPressed: root.toggleDatabasePicker()
                Keys.onSpacePressed: root.toggleDatabasePicker()
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleDatabasePicker() }
              }
              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.databasePickerExpanded && root.connectionId !== "" && root.supportsDatabaseSwitch()
                spacing: 8
                RowLayout {
                  Layout.fillWidth: true
                  Text { text: "DATABASES"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1 }
                  Item { Layout.fillWidth: true }
                  Text { text: root.databaseSwitching ? "Opening…" : root.databasesLoading ? "Loading…" : String(root.filteredDatabases().length); color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6
                  StudioField { id: databaseSearchField; Layout.fillWidth: true; placeholderText: "Search databases…"; text: root.databaseSearch; onTextChanged: root.databaseSearch = text }
                  StudioButton { label: "Refresh"; compact: true; buttonEnabled: !root.databasesLoading && !root.databaseSwitching; onClicked: root.loadDatabases() }
                }
                Item {
                  id: databaseScroll
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  clip: true
                  ListView {
                    anchors.fill: parent
                    anchors.rightMargin: 4
                    clip: true
                    model: root.filteredDatabases()
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    delegate: Rectangle {
                      id: databaseRow
                      required property var modelData
                      readonly property bool isCurrent: !!root.activeProfile && String(root.activeProfile.database || "").toLowerCase() === modelData.name.toLowerCase()
                      width: ListView.view.width
                      height: 34
                      radius: 5
                      color: isCurrent ? root.selected : databaseHover.hovered ? root.raised : "transparent"
                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 9
                        anchors.rightMargin: 7
                        spacing: 8
                        StudioIcon { Layout.preferredWidth: 16; Layout.preferredHeight: 16; iconName: "server-database" }
                        Text { Layout.fillWidth: true; text: databaseRow.modelData.name; textFormat: Text.PlainText; color: databaseRow.isCurrent ? root.ink : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); font.bold: databaseRow.isCurrent; elide: Text.ElideRight }
                        Text { visible: databaseRow.isCurrent; text: "Current"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(11, Style.font.caption) }
                      }
                      HoverHandler { id: databaseHover }
                      MouseArea { anchors.fill: parent; cursorShape: databaseRow.isCurrent || root.databaseSwitching ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: root.switchDatabase(databaseRow.modelData.name) }
                    }
                  }
                  Text { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; topPadding: 10; visible: !root.databasesLoading && root.filteredDatabases().length === 0; text: root.databaseSearch ? "No matching databases." : "No databases listed. Enter a name below."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
                }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6
                  StudioField { id: databaseNameInput; Layout.fillWidth: true; placeholderText: "Database name…"; onAccepted: root.switchDatabase(text) }
                  StudioButton { label: "Switch"; compact: true; buttonEnabled: databaseNameInput.text.trim() !== "" && !root.databaseSwitching; onClicked: root.switchDatabase(databaseNameInput.text) }
                }
                Text { Layout.fillWidth: true; visible: root.databaseListLimited; text: "Some databases may be hidden. Enter a name to switch directly."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
                Text { Layout.fillWidth: true; visible: root.databaseError !== ""; text: root.databaseError; textFormat: Text.PlainText; color: Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: !root.databasePickerExpanded
                StudioField { id: searchField; Layout.fillWidth: true; placeholderText: "Search objects…"; text: root.objectSearch; onTextChanged: root.objectSearch = text }
                StudioButton { label: "Refresh"; compact: true; buttonEnabled: root.connectionId !== "" && !root.schemaLoading; onClicked: root.loadSchema() }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: !root.databasePickerExpanded
                Text { text: "SCHEMAS"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1 }
                Item { Layout.fillWidth: true }
                Text { text: root.schemaLoading ? "Loading…" : String(root.filteredSchemas().length); color: root.faintInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
              }
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.schemaError ? Math.max(52, schemaErrorText.implicitHeight + 18) : 0
                visible: !root.databasePickerExpanded && root.schemaError !== ""
                radius: 5
                color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
                RowLayout {
                  anchors.fill: parent
                  anchors.margins: 8
                  spacing: 8
                  Text {
                    id: schemaErrorText
                    Layout.fillWidth: true
                    text: root.schemaError
                    textFormat: Text.PlainText
                    color: Color.urgent
                    font.family: root.uiFont
                    font.pixelSize: Math.max(12, Style.font.caption)
                    wrapMode: Text.WordWrap
                  }
                  StudioButton { label: "Retry"; compact: true; buttonEnabled: root.connectionId !== ""; onClicked: root.loadSchema() }
                }
              }
              Item {
                id: schemaScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !root.databasePickerExpanded
                clip: true
                ListView {
                  anchors.fill: parent
                  anchors.rightMargin: 4
                  clip: true
                  spacing: 2
                  model: root.visibleSchemaEntries()
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                  delegate: Rectangle {
                    id: browserRow
                    required property var modelData
                    readonly property bool isSchema: modelData.kind === "schema"
                    readonly property string schemaName: isSchema ? modelData.name : modelData.object.schema
                    width: ListView.view.width
                    height: isSchema ? 37 : 35
                    color: rowHover.hovered ? root.raised : "transparent"
                    radius: 5
                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: browserRow.isSchema ? 7 : 39
                      anchors.rightMargin: 8
                      spacing: 9
                      Text { visible: browserRow.isSchema; text: root.schemaExpanded(browserRow.schemaName) ? "⌄" : "›"; color: root.softInk; font.pixelSize: 19; Layout.preferredWidth: browserRow.isSchema ? 14 : 0 }
                      StudioIcon { Layout.preferredWidth: 16; Layout.preferredHeight: 16; iconName: browserRow.isSchema ? "server-database" : browserRow.modelData.object.type === "view" ? "view-list-details" : "x-office-spreadsheet" }
                      Text { Layout.fillWidth: true; text: browserRow.isSchema ? browserRow.schemaName : browserRow.modelData.object.name; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); elide: Text.ElideRight }
                      Text { text: browserRow.isSchema ? String(browserRow.modelData.count) : browserRow.modelData.object.type === "view" ? "view" : ""; color: root.faintInk; font.pixelSize: Math.max(12, Style.font.caption) }
                    }
                    HoverHandler { id: rowHover }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: browserRow.isSchema ? root.toggleSchema(browserRow.schemaName) : root.openTable(browserRow.modelData.object) }
                  }
                }
                Text {
                  anchors.top: parent.top
                  anchors.left: parent.left
                  anchors.right: parent.right
                  visible: !root.connectionId || (!root.schemaLoading && !root.schemaError && root.filteredSchemas().length === 0)
                  text: !root.connectionId ? "Connect to browse schemas and tables." : root.objectSearch ? "No matching objects." : "No tables or views found."
                  color: root.softInk
                  wrapMode: Text.WordWrap
                  font.family: root.uiFont
                  font.pixelSize: Math.max(14, Style.font.body)
                  topPadding: 12
                }
              }
              StudioButton { Layout.fillWidth: true; label: "Add connection"; iconName: "list-add"; onClicked: root.addConnection() }
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: root.surface
            radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 9) : 6
            border.width: 1
            border.color: root.line
            clip: true
            ColumnLayout {
              anchors.fill: parent
              spacing: 0

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 50
                color: root.surface
                border.width: 1
                border.color: root.line
                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 8
                  spacing: 4
                  Repeater {
                    model: root.tabs
                    delegate: Rectangle {
                      id: workTab
                      required property var modelData
                      Layout.preferredWidth: Math.min(210, Math.max(130, tabLabel.implicitWidth + 66))
                      Layout.preferredHeight: 48
                      color: root.activeTabId === workTab.modelData.id ? root.raised : "transparent"
                      border.width: 1
                      border.color: root.line
                      Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 2; visible: root.activeTabId === workTab.modelData.id; color: root.accent }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.activeTabId = workTab.modelData.id }
                      RowLayout {
                        z: 1
                        anchors.fill: parent
                        anchors.leftMargin: 11
                        anchors.rightMargin: 7
                        spacing: 8
                        StudioIcon { Layout.preferredWidth: 16; Layout.preferredHeight: 16; iconName: workTab.modelData.kind === "query" ? "accessories-text-editor" : "x-office-spreadsheet" }
                        Text { id: tabLabel; Layout.fillWidth: true; text: workTab.modelData.title; textFormat: Text.PlainText; color: root.activeTabId === workTab.modelData.id ? root.ink : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); elide: Text.ElideRight }
                        StudioIcon { Layout.preferredWidth: 13; Layout.preferredHeight: 13; iconName: "window-close"; opacity: 0.65; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.closeTab(workTab.modelData.id) } }
                      }
                    }
                  }
                  StudioButton { label: "New query"; iconName: "list-add"; compact: true; onClicked: root.newQuery() }
                  Item { Layout.fillWidth: true }
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                visible: root.activeTab && root.activeTab.kind === "query"
                SplitView {
                  id: querySplit
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  orientation: Qt.Vertical
                  handle: Rectangle {
                    implicitHeight: 10
                    color: splitterHover.hovered ? root.raised : root.surface
                    Rectangle { width: 44; height: 2; radius: 1; anchors.centerIn: parent; color: splitterHover.hovered ? root.accent : root.faintInk }
                    HoverHandler { id: splitterHover; cursorShape: Qt.SizeVerCursor }
                  }
                  ColumnLayout {
                    id: queryComposer
                    SplitView.minimumHeight: 185
                    SplitView.preferredHeight: Math.max(245, window.height * 0.46)
                    visible: !root.resultsExpanded
                    spacing: 0
                Rectangle {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.minimumHeight: 120
                  color: root.bg
                  RowLayout {
                    anchors.fill: parent
                    spacing: 0
                    Rectangle {
                      id: editorGutter
                      Layout.preferredWidth: 50
                      Layout.fillHeight: true
                      color: root.surface
                      clip: true
                      readonly property int lineHeight: Math.round(sqlEditor.font.pixelSize * 1.32)
                      readonly property int firstVisibleLine: Math.min(Math.max(0, sqlEditor.lineCount - 1), Math.max(0, Math.floor(root.editorScrollY() / lineHeight)))
                      Column {
                        y: 22 - (root.editorScrollY() - editorGutter.firstVisibleLine * editorGutter.lineHeight)
                        width: parent.width
                        Repeater {
                          model: Math.max(0, Math.min(sqlEditor.lineCount - editorGutter.firstVisibleLine, Math.ceil(editorGutter.height / editorGutter.lineHeight) + 2))
                          delegate: Text {
                            required property int index
                            width: 50
                            height: editorGutter.lineHeight
                            text: String(editorGutter.firstVisibleLine + index + 1)
                            horizontalAlignment: Text.AlignHCenter
                            color: root.faintInk
                            font.family: root.codeFont
                            font.pixelSize: sqlEditor.font.pixelSize
                          }
                        }
                      }
                    }
                    ScrollView {
                      id: sqlScroll
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      clip: true
                      TextArea {
                        id: sqlEditor
                        text: ""
                        onTextChanged: {
                          var limitedText = text.length > 200000 ? text.slice(0, 200000) : text
                          if (lineCount > 10000) limitedText = limitedText.split("\n").slice(0, 10000).join("\n")
                          var truncated = limitedText !== text
                          if (truncated) {
                            text = limitedText
                            root.showNotice("SQL text is limited to 200,000 characters or 10,000 lines.", true)
                          }
                          if ((!root.syncingEditor || truncated) && root.activeTab && root.activeTab.kind === "query" && text !== root.activeTab.sql)
                            root.updateTab(root.activeTab.id, { sql: text })
                        }
                        placeholderText: "Write a SQL query…"
                        color: root.ink
                        placeholderTextColor: root.faintInk
                        selectionColor: root.accent
                        selectedTextColor: root.bg
                        font.family: root.codeFont
                        font.pixelSize: Math.max(16, Style.font.body + 2)
                        padding: 22
                        textFormat: TextEdit.PlainText
                        wrapMode: TextEdit.NoWrap
                        background: Rectangle { color: root.bg }
                      }
                    }
                  }
                }
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 65
                  color: root.surface
                  border.width: 1
                  border.color: root.line
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 12
                    StudioButton { label: "Run query"; iconName: "media-playback-start"; prominent: true; buttonEnabled: root.connectionId !== "" && root.activeTab && !root.activeTab.busy; onClicked: root.runQuery() }
                    StudioButton { label: "Cancel"; iconName: "process-stop"; buttonEnabled: root.activeTab && root.activeTab.busy; onClicked: root.cancelQuery() }
                    Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 28; color: root.line }
                    Text { text: root.activeTab && root.activeTab.busy ? "Running…" : "Ctrl+Enter to run"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                    Item { Layout.fillWidth: true }
                    Text { text: root.activeProfile ? "Database: " + (root.activeProfile.database || root.activeProfile.name) : "No database selected"; textFormat: Text.PlainText; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); elide: Text.ElideRight }
                  }
                }
                  }
                Rectangle {
                  SplitView.minimumHeight: 150
                  SplitView.fillHeight: true
                  color: root.surface
                  ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    RowLayout {
                      Layout.fillWidth: true
                      Layout.preferredHeight: 47
                      spacing: 0
                      StudioTab { label: "Results"; iconName: "x-office-spreadsheet"; selectedTab: root.resultPane === "results"; onClicked: root.resultPane = "results" }
                      StudioTab { label: "Messages"; iconName: "text-x-generic"; selectedTab: root.resultPane === "messages"; onClicked: root.resultPane = "messages" }
                      Item { Layout.fillWidth: true }
                      Text { text: root.activeTab ? (root.activeTab.rows.length + " rows  |  " + root.activeTab.durationMs + " ms" + (root.activeTab.hasMore ? "  |  capped" : "")) : ""; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                      StudioButton {
                        label: root.resultsExpanded ? "Restore" : "Expand"
                        iconName: root.resultsExpanded ? "view-restore" : "view-fullscreen"
                        compact: true
                        Layout.rightMargin: 12
                        onClicked: {
                          if (!root.resultsExpanded) root.resultPane = "results"
                          root.resultsExpanded = !root.resultsExpanded
                        }
                      }
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
                    DbGrid {
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      Layout.margins: 11
                      visible: root.resultPane === "results"
                      columns: root.activeTab ? root.activeTab.columns : []
                      rows: root.activeTab ? root.activeTab.rows : []
                      busy: root.activeTab ? root.activeTab.busy : false
                      error: root.activeTab ? root.activeTab.error : ""
                      hasMore: root.activeTab ? root.activeTab.hasMore : false
                      emptyText: "The query returned no rows"
                    }
                    Text {
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      Layout.margins: 20
                      visible: root.resultPane === "messages"
                      text: root.activeTab ? (root.activeTab.message || "") : ""
                      textFormat: Text.PlainText
                      color: root.activeTab && root.activeTab.error ? Color.urgent : root.ink
                      font.family: root.codeFont
                      font.pixelSize: Math.max(14, Style.font.body)
                      wrapMode: Text.WordWrap
                    }
                  }
                }
                }
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.max(148, window.height * 0.19)
                  Layout.minimumHeight: 120
                  visible: !root.resultsExpanded
                  color: root.surface
                  border.width: 1
                  border.color: root.line
                  ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    RowLayout {
                      Layout.fillWidth: true
                      Layout.preferredHeight: 46
                      Layout.leftMargin: 16
                      spacing: 8
                      StudioIcon { Layout.preferredWidth: 16; Layout.preferredHeight: 16; iconName: "text-x-generic" }
                      Text { text: "Selected object"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: true }
                      Item { Layout.fillWidth: true }
                      StudioButton { label: "Open table"; compact: true; buttonEnabled: root.selectedObject !== null; onClicked: root.openTable(root.selectedObject); Layout.rightMargin: 12 }
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
                    Text { Layout.fillWidth: true; Layout.fillHeight: true; Layout.margins: 22; visible: root.selectedObject === null; text: "Select a table or view from the schema browser to inspect it."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) }
                    ColumnLayout {
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      Layout.margins: 18
                      visible: root.selectedObject !== null
                      spacing: 7
                      Text { text: root.selectedObject ? root.selectedObject.schema + "." + root.selectedObject.name : ""; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(16, Style.font.title); font.bold: true }
                      Text { text: root.selectedObject ? (root.selectedObject.type === "view" ? "View" : "Table") + (root.inspectorDefinition && root.inspectorDefinition.columns ? " · " + root.inspectorDefinition.columns.length + " columns" : "") : ""; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
                      Text { Layout.fillWidth: true; text: "Open the table to view data, columns, and indexes."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) }
                    }
                  }
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.activeTab && root.activeTab.kind === "table"
                spacing: 0
                RowLayout {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 63
                  Layout.leftMargin: 20
                  Layout.rightMargin: 20
                  spacing: 12
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text { text: root.activeTab && root.activeTab.object ? root.activeTab.object.schema + "." + root.activeTab.object.name : ""; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(18, Style.font.heading); font.bold: true }
                    Text { text: root.activeTab && root.activeTab.object && root.activeTab.object.type === "view" ? "View data" : "Table · view data"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
                  }
                  StudioButton { label: "Query table"; iconName: "accessories-text-editor"; onClicked: root.queryTable(root.activeTab.object) }
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
                RowLayout {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 48
                  spacing: 0
                  StudioTab { label: "Data"; iconName: "x-office-spreadsheet"; selectedTab: root.activeTab && root.activeTab.tablePane === "data"; onClicked: root.updateTab(root.activeTab.id, { tablePane: "data" }) }
                  StudioTab { label: "Definition"; iconName: "text-x-generic"; selectedTab: root.activeTab && root.activeTab.tablePane === "definition"; onClicked: root.updateTab(root.activeTab.id, { tablePane: "definition" }) }
                  Item { Layout.fillWidth: true }
                  StudioButton { label: "Cancel"; compact: true; visible: !!root.activeTab && root.activeTab.busy && root.activeTab.tablePane === "data"; onClicked: root.cancelTableRows(root.activeTab.id) }
                  StudioButton { label: "Refresh"; compact: true; buttonEnabled: root.connectionId !== "" && !!root.activeTab && !root.activeTab.busy; onClicked: { if (root.activeTab) { root.inspectObject(root.activeTab.object); root.loadTableRows(root.activeTab.id, root.activeTab.offset || 0) } } Layout.rightMargin: 12 }
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
                DbGrid {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.margins: 12
                  visible: root.activeTab && root.activeTab.tablePane === "data"
                  columns: root.activeTab ? root.activeTab.columns : []
                  rows: root.activeTab ? root.activeTab.rows : []
                  busy: root.activeTab ? root.activeTab.busy : false
                  error: root.activeTab ? root.activeTab.error : ""
                  paged: true
                  offset: root.activeTab ? root.activeTab.offset || 0 : 0
                  hasMore: root.activeTab ? root.activeTab.hasMore : false
                  limit: root.rowLimit
                  onNextPage: root.loadTableRows(root.activeTab.id, root.activeTab.offset + root.rowLimit)
                  onPreviousPage: root.loadTableRows(root.activeTab.id, Math.max(0, root.activeTab.offset - root.rowLimit))
                }
                ScrollView {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.margins: 20
                  visible: root.activeTab && root.activeTab.tablePane === "definition"
                  clip: true
                  ColumnLayout {
                    width: parent.width - 24
                    spacing: 12
                    Text { text: "COLUMNS"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1 }
                    Repeater {
                      model: root.activeTab && root.activeTab.definition ? root.activeTab.definition.columns || [] : []
                      delegate: Rectangle {
                        id: columnRow
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: columnRow.modelData.default === null || columnRow.modelData.default === undefined ? 45 : 58
                        color: root.raised
                        radius: 5
                        RowLayout {
                          anchors.fill: parent
                          anchors.leftMargin: 14
                          anchors.rightMargin: 14
                          spacing: 12
                          Text { Layout.preferredWidth: 200; text: columnRow.modelData.name; textFormat: Text.PlainText; color: root.ink; font.family: root.codeFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: true; elide: Text.ElideRight }
                          ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text { Layout.fillWidth: true; text: columnRow.modelData.type; textFormat: Text.PlainText; color: root.softInk; font.family: root.codeFont; font.pixelSize: Math.max(14, Style.font.body); elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; visible: columnRow.modelData.default !== null && columnRow.modelData.default !== undefined; text: "Default: " + columnRow.modelData.default; textFormat: Text.PlainText; color: root.faintInk; font.family: root.codeFont; font.pixelSize: Math.max(12, Style.font.caption); elide: Text.ElideRight }
                          }
                          Text { text: columnRow.modelData.primaryKey ? "PRIMARY KEY" : columnRow.modelData.nullable ? "NULL" : "NOT NULL"; color: columnRow.modelData.primaryKey ? root.accent : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                        }
                      }
                    }
                    Text { visible: !root.activeTab || !root.activeTab.definition; text: "Loading definition…"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) }
                    Text { text: "INDEXES"; visible: !!(root.activeTab && root.activeTab.definition && (root.activeTab.definition.indexes || []).length > 0); color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1; topPadding: 16 }
                    Repeater {
                      model: root.activeTab && root.activeTab.definition ? root.activeTab.definition.indexes || [] : []
                      delegate: Text {
                        required property var modelData
                        text: typeof modelData === "string" ? modelData : modelData.name || JSON.stringify(modelData)
                        textFormat: Text.PlainText
                        color: root.ink
                        font.family: root.codeFont
                        font.pixelSize: Math.max(14, Style.font.body)
                      }
                    }
                  }
                }
              }
            }
          }
        }
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: root.notice ? 30 : 0
          visible: root.notice !== ""
          color: root.noticeError ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.13) : root.surface
          Text { anchors.fill: parent; anchors.leftMargin: 16; verticalAlignment: Text.AlignVCenter; text: root.notice; textFormat: Text.PlainText; color: root.noticeError ? Color.urgent : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); elide: Text.ElideRight }
        }
      }
    }

    Dialog {
      id: connectionDialog
      parent: window.contentItem
      modal: true
      title: root.editingProfileId ? "Edit connection" : "Add connection"
      anchors.centerIn: parent
      width: Math.min(620, window.width - 60)
      height: Math.min(760, window.height - 70)
      padding: 0
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.line; radius: 9 }
      header: Rectangle {
        implicitHeight: 67
        color: root.raised
        radius: 9
        Text { anchors.left: parent.left; anchors.leftMargin: 22; anchors.verticalCenter: parent.verticalCenter; text: connectionDialog.title; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(19, Style.font.heading); font.bold: true }
      }
      contentItem: ScrollView {
        id: connectionFormScroll
        clip: true
        leftPadding: 22
        rightPadding: 22
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
          width: Math.max(0, connectionFormScroll.availableWidth)
          spacing: 10
          Text { text: "CONNECTION DETAILS"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1; Layout.topMargin: 18 }
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: storedConnectionText.implicitHeight + 24
            visible: root.editingProfileId !== ""
            color: root.selected
            radius: 6
            border.width: 1
            border.color: root.line
            Text {
              id: storedConnectionText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              text: root.editingHasStoredConnection
                ? "Connection string saved in system keyring. Leave the string and fields blank to keep it, or enter new details to replace it."
                : "Connection details available for this session. Leave the string and fields blank to keep them, or enter new details to replace them."
              textFormat: Text.PlainText
              color: root.ink
              font.family: root.uiFont
              font.pixelSize: Math.max(13, Style.font.bodySmall)
              wrapMode: Text.WordWrap
            }
          }
          Text { text: "Name"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
          StudioField { id: connectionName; Layout.fillWidth: true; placeholderText: "Production reporting" }
          Text { text: "Database type"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
          ComboBox {
            id: enginePicker
            Layout.fillWidth: true
            implicitHeight: 40
            model: root.engineOptions
            textRole: "label"
            onActivated: { portInput.text = root.engineOptions[currentIndex].port; sslCheck.checked = true }
            contentItem: Text {
              text: enginePicker.displayText
              color: root.ink
              font.family: root.uiFont
              font.pixelSize: Math.max(14, Style.font.body)
              verticalAlignment: Text.AlignVCenter
              leftPadding: 13
              rightPadding: 36
            }
            indicator: Text {
              x: enginePicker.width - width - 14
              y: (enginePicker.height - height) / 2
              text: "⌄"
              color: root.softInk
              font.family: root.uiFont
              font.pixelSize: 18
            }
            background: Rectangle {
              color: root.surface
              radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 6) : 4
              border.width: enginePicker.activeFocus ? 2 : 1
              border.color: enginePicker.activeFocus ? root.accent : root.line
            }
            delegate: ItemDelegate {
              id: engineOption
              required property int index
              width: enginePicker.width - 4
              height: 40
              text: root.engineOptions[index].label
              contentItem: Text {
                text: engineOption.text
                color: root.ink
                font.family: root.uiFont
                font.pixelSize: Math.max(14, Style.font.body)
                verticalAlignment: Text.AlignVCenter
                leftPadding: 11
              }
              background: Rectangle {
                color: enginePicker.highlightedIndex === index ? root.selected : root.raised
              }
              onClicked: {
                enginePicker.currentIndex = index
                portInput.text = root.engineOptions[index].port
                sslCheck.checked = true
                enginePicker.popup.close()
              }
            }
            popup: Popup {
              y: enginePicker.height + 4
              width: enginePicker.width
              height: Math.min(180, enginePicker.count * 40 + 4)
              padding: 2
              background: Rectangle {
                color: root.raised
                radius: 5
                border.width: 1
                border.color: root.line
              }
              contentItem: ListView {
                clip: true
                model: enginePicker.popup.visible ? enginePicker.delegateModel : null
                currentIndex: enginePicker.highlightedIndex
                ScrollIndicator.vertical: ScrollIndicator { }
              }
            }
          }
          Text { text: root.editingProfileId ? "New connection string (optional)" : "Paste connection string (optional)"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); Layout.topMargin: 5 }
          StudioField { id: connectionStringInput; Layout.fillWidth: true; placeholderText: root.editingProfileId ? "Blank keeps the existing connection" : "Paste a URL or driver connection string"; echoMode: TextInput.Password }
          Text { Layout.fillWidth: true; text: "The full string is passed to the local worker, then cleared from this form. If remembered, it is stored in the system keyring."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          Text { text: "OR ENTER FIELDS"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1; Layout.topMargin: 8 }
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            ColumnLayout { Layout.fillWidth: true; Text { text: "Host"; color: root.softInk; font.pixelSize: Math.max(13, Style.font.bodySmall) } StudioField { id: hostInput; Layout.fillWidth: true; placeholderText: "server.example.com" } }
            ColumnLayout { Layout.preferredWidth: 100; Text { text: "Port"; color: root.softInk; font.pixelSize: Math.max(13, Style.font.bodySmall) } StudioField { id: portInput; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly } }
          }
          Text { text: "Database"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
          StudioField { id: databaseInput; Layout.fillWidth: true; placeholderText: "Database name" }
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            ColumnLayout { Layout.fillWidth: true; Text { text: "User"; color: root.softInk; font.pixelSize: Math.max(13, Style.font.bodySmall) } StudioField { id: userInput; Layout.fillWidth: true; placeholderText: "User name" } }
            ColumnLayout {
              Layout.fillWidth: true
              Text {
                text: enginePicker.currentIndex >= 0 && root.engineOptions[enginePicker.currentIndex].value === "mysql" ? "Password (optional)" : "Password"
                color: root.softInk
                font.pixelSize: Math.max(13, Style.font.bodySmall)
              }
              StudioField {
                id: passwordInput
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: enginePicker.currentIndex >= 0 && root.engineOptions[enginePicker.currentIndex].value === "mysql" ? "Leave blank if none" : "Password"
              }
            }
          }
          StudioCheck { id: sslCheck; text: "Use verified TLS"; checked: true; visible: connectionStringInput.text.trim() === ""; enabled: root.engineOptions[enginePicker.currentIndex].value !== "azure_sql" }
          Text { Layout.fillWidth: true; visible: root.engineOptions[enginePicker.currentIndex].value === "azure_sql" && connectionStringInput.text.trim() === ""; text: "Azure SQL always uses verified TLS."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          Text {
            Layout.fillWidth: true
            visible: connectionStringInput.text.trim() !== ""
            text: root.engineOptions[enginePicker.currentIndex].value === "postgres"
              ? "The URL controls TLS. Verified TLS is on unless sslmode=disable or ssl=false explicitly turns it off."
              : root.engineOptions[enginePicker.currentIndex].value === "mysql"
              ? "The string controls TLS. Remote hosts default to verified TLS; local MySQL may use plaintext. sslmode=disable or ssl=false turns it off."
              : root.engineOptions[enginePicker.currentIndex].value === "sqlserver"
              ? "The string controls TLS. Encrypt=false explicitly turns it off; credentials and data may then travel in plaintext."
              : "Azure SQL always uses verified TLS, including with a connection string."
            textFormat: Text.PlainText
            color: root.softInk
            font.family: root.uiFont
            font.pixelSize: Math.max(12, Style.font.caption)
            wrapMode: Text.WordWrap
          }
          Text { Layout.fillWidth: true; visible: connectionStringInput.text.trim() === "" && !sslCheck.checked; text: "TLS is off. Credentials and data may travel in plaintext."; textFormat: Text.PlainText; color: Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          StudioCheck { id: rememberCheck; text: "Remember connection in system keyring"; checked: true }
          Text { Layout.fillWidth: true; text: "Without Remember, this connection works for this session and disappears when DB Studio closes."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          Text { id: formError; Layout.fillWidth: true; color: Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
          RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 9
            Item { Layout.fillWidth: true }
            StudioButton { label: "Cancel"; onClicked: { passwordInput.text = ""; connectionStringInput.text = ""; connectionDialog.close() } }
            StudioButton { label: root.editingProfileId ? "Save changes" : "Save and connect"; prominent: true; onClicked: root.saveConnection() }
          }
          Item { Layout.preferredHeight: 14 }
        }
      }
      onClosed: { passwordInput.text = ""; connectionStringInput.text = "" }
    }

    Dialog {
      id: connectionListDialog
      parent: window.contentItem
      modal: true
      title: "Connections"
      anchors.centerIn: parent
      width: Math.min(640, window.width - 60)
      height: Math.min(610, window.height - 80)
      padding: 22
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.line; radius: 9 }
      contentItem: ColumnLayout {
        spacing: 13
        Text { text: "Connections"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(21, Style.font.heading + 3); font.bold: true }
        Text { Layout.fillWidth: true; text: "Connection details are stored in the system keyring when Remember is on."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
        ScrollView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          ColumnLayout {
            width: Math.max(0, connectionListDialog.width - 56)
            spacing: 8
            Repeater {
              model: root.profiles
              delegate: Rectangle {
                id: profileRow
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredHeight: 62
                color: root.raised
                radius: 6
                border.width: 1
                border.color: root.line
                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 13
                  anchors.rightMargin: 10
                  spacing: 8
                  Rectangle { Layout.preferredWidth: 9; Layout.preferredHeight: 9; radius: 5; color: root.activeProfile && root.activeProfile.id === profileRow.modelData.id ? "#58c89a" : root.faintInk }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text { Layout.fillWidth: true; text: profileRow.modelData.name; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(15, Style.font.body); font.bold: true; elide: Text.ElideRight }
                    Text { text: root.engineName(profileRow.modelData.type); color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                  }
                  StudioButton { label: "Connect"; compact: true; onClicked: { connectionListDialog.close(); root.openProfile(profileRow.modelData) } }
                  StudioButton { label: "Duplicate"; compact: true; onClicked: root.duplicateProfile(profileRow.modelData) }
                  StudioButton { label: "Edit"; compact: true; onClicked: { connectionListDialog.close(); root.editingProfileId = profileRow.modelData.id; root.prepareConnectionForm(profileRow.modelData); connectionDialog.open() } }
                  StudioButton { label: "Remove"; compact: true; onClicked: { connectionListDialog.close(); root.deleteProfile(profileRow.modelData) } }
                }
              }
            }
            Text { visible: root.profiles.length === 0; text: "No saved connections yet."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) }
          }
        }
        RowLayout {
          Layout.fillWidth: true
          StudioButton { label: "Add connection"; iconName: "list-add"; prominent: true; onClicked: { connectionListDialog.close(); root.addConnection() } }
          Item { Layout.fillWidth: true }
          StudioButton { label: "Disconnect"; buttonEnabled: root.connectionId !== ""; onClicked: { root.disconnect(); connectionListDialog.close() } }
          StudioButton { label: "Close"; onClicked: connectionListDialog.close() }
        }
      }
    }

    Dialog {
      id: deleteDialog
      parent: window.contentItem
      modal: true
      title: "Remove connection?"
      anchors.centerIn: parent
      width: 430
      padding: 22
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.line; radius: 9 }
      contentItem: ColumnLayout {
        spacing: 18
        Text { text: "Remove this connection?"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(18, Style.font.heading); font.bold: true }
        Text { Layout.fillWidth: true; text: "Its saved keyring entry will also be removed."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); wrapMode: Text.WordWrap }
        RowLayout { Layout.fillWidth: true; Item { Layout.fillWidth: true } StudioButton { label: "Cancel"; onClicked: deleteDialog.close() } StudioButton { label: "Remove"; prominent: true; onClicked: root.confirmDeleteProfile() } }
      }
    }

    Dialog {
      id: settingsDialog
      parent: window.contentItem
      modal: true
      title: "Settings"
      anchors.centerIn: parent
      width: 440
      padding: 22
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.line; radius: 9 }
      contentItem: ColumnLayout {
        spacing: 14
        Text { text: "Settings"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(21, Style.font.heading + 3); font.bold: true }
        RowLayout { Layout.fillWidth: true; Text { text: "Default result limit"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) } Item { Layout.fillWidth: true } SpinBox { from: 1; to: 1000; stepSize: 25; editable: true; value: root.rowLimit; onValueModified: root.setRowLimit(value) } }
        Text { Layout.fillWidth: true; text: "Every SQL result and table page stops at this many rows (1–1000). The default is 100."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
        RowLayout { Layout.fillWidth: true; Text { text: "Query timeout (seconds)"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) } Item { Layout.fillWidth: true } SpinBox { from: 5; to: 120; value: root.timeoutMs / 1000; onValueModified: root.timeoutMs = value * 1000 } }
        Text { Layout.fillWidth: true; text: "Data browsing is view only in v1. Row editing will be added later."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
        RowLayout { Layout.fillWidth: true; Item { Layout.fillWidth: true } StudioButton { label: "Done"; prominent: true; onClicked: settingsDialog.close() } }
      }
    }
  }
}
