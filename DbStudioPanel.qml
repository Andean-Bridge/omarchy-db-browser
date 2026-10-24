pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Theme

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
  property string objectTypeFilter: "all"
  property var selectedObject: null
  property var inspectorDefinition: null
  property int inspectorLoadGeneration: 0

  property var tabs: [{ id: "query-1", kind: "query", title: "Query 1", sql: "", columns: [], rows: [], cellRefs: [], durationMs: 0, rowCount: 0, hasMore: false, busy: false, error: "", message: "", pendingId: 0 }]
  property string activeTabId: "query-1"
  property int nextTabId: 2
  readonly property var activeTab: tabs.find(function(tab) { return tab.id === activeTabId }) || null
  property string resultPane: "results"
  property bool resultsExpanded: false
  property bool syncingEditor: false
  property int rowLimit: 100
  property int settingsVersion: 0
  property bool reopenLastConnection: false
  property string lastProfileId: ""
  property bool profilesLoaded: false
  property bool settingsLoaded: false
  property bool automaticOpenAttempted: false
  property int timeoutMs: 30000
  property string editingProfileId: ""
  property bool editingHasStoredConnection: false
  property string deleteProfileId: ""
  property var viewedCell: null
  property var viewedSnapshot: null
  property string viewerText: ""
  property string viewerError: ""
  property bool viewerLoading: false
  property bool viewerComplete: false
  property string viewerMode: "text"
  property string viewerJsonText: ""
  property int viewerGeneration: 0
  property real viewerWidth: 900
  property real viewerHeight: 630
  property string aiTabId: ""
  property string aiConnectionId: ""
  property string aiOriginalSql: ""
  property string aiLastError: ""
  property string aiDraft: ""
  property string aiExplanation: ""
  property string aiError: ""
  property bool aiBusy: false
  property bool aiAvailable: false
  property int aiStatusVersion: 0
  property int aiRequestId: 0
  property int aiGeneration: 0
  property string diffSourceProfileId: ""
  property string diffTargetProfileId: ""
  property var diffCatalog: null
  property var diffSelectedSchemas: []
  property var diffSelectedObjects: ({})
  property var diffExpandedSchemas: ({})
  property string diffFilter: ""
  property string diffPhase: "setup"
  property bool diffBusy: false
  property string diffError: ""
  property var diffResult: null
  property var diffIncluded: ({})
  property string diffFocusedKey: ""
  property var diffPreview: null
  property bool diffPreviewBusy: false
  property int diffPreviewGeneration: 0
  property string diffViewSide: "changes"
  property string diffDetailTab: "difference"
  property string diffScript: ""
  property bool diffScriptComplete: false
  property var diffManual: []
  property int diffGeneration: 0

  readonly property color bg: Theme.Color.popups.background
  readonly property color ink: Theme.Color.popups.text
  readonly property color softInk: Qt.rgba(ink.r, ink.g, ink.b, 0.62)
  readonly property color faintInk: Qt.rgba(ink.r, ink.g, ink.b, 0.42)
  readonly property color accent: Theme.Color.accent
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
    { label: "MySQL", value: "mysql", port: "3306" },
    { label: "Cloudflare D1", value: "cloudflare_d1", port: "" }
  ]

  function engineName(type) {
    var found = engineOptions.find(function(entry) { return entry.value === type })
    return found ? found.label : String(type || "Database")
  }
  function diffProfiles() {
    return profiles.filter(function(profile) { return profile.type === "sqlserver" || profile.type === "azure_sql" })
  }
  function diffProfileIndex(id) {
    return id ? diffProfiles().findIndex(function(profile) { return profile.id === id }) + 1 : 0
  }
  function resetDiffResults() {
    diffGeneration++
    diffCatalog = null
    diffSelectedSchemas = []
    diffSelectedObjects = ({})
    diffExpandedSchemas = ({})
    diffFilter = ""
    diffPhase = "setup"
    diffBusy = false
    diffError = ""
    diffResult = null
    diffIncluded = ({})
    diffFocusedKey = ""
    diffPreview = null
    diffPreviewBusy = false
    diffPreviewGeneration++
    diffScript = ""
    diffManual = []
    diffScriptComplete = false
  }
  function openDiffDialog() {
    resetDiffResults()
    diffSourceProfileId = ""
    diffTargetProfileId = ""
    diffDialog.open()
  }
  function loadDiffCatalog() {
    if (!diffSourceProfileId || !diffTargetProfileId || diffSourceProfileId === diffTargetProfileId || diffBusy) return
    var generation = ++diffGeneration
    diffBusy = true
    diffError = ""
    request("schemaDiff.catalog", { sourceProfileId: diffSourceProfileId, targetProfileId: diffTargetProfileId }, function(data, error) {
      if (generation !== diffGeneration || !diffDialog.visible) return
      diffBusy = false
      if (error) { diffError = error; return }
      diffCatalog = data
      diffSelectedSchemas = (data.source.schemas || []).map(function(item) { return item.name })
      var selected = ({})
      ;(data.source.objects || []).forEach(function(object) { selected[JSON.stringify([object.schema, object.name])] = true })
      diffSelectedObjects = selected
      diffExpandedSchemas = ({})
      diffPhase = "select"
    })
  }
  function diffRows() {
    if (!diffCatalog) return []
    var rows = []
    var needle = diffFilter.toLocaleLowerCase().trim()
    var objects = diffCatalog.source.objects || []
    ;(diffCatalog.source.schemas || []).forEach(function(schema) {
      var children = objects.filter(function(object) { return object.schema === schema.name })
      var matches = children.filter(function(object) { return object.name.toLocaleLowerCase().includes(needle) || object.schema.toLocaleLowerCase().includes(needle) })
      if (needle && !matches.length && !schema.name.toLocaleLowerCase().includes(needle)) return
      rows.push({ kind: "schema", name: schema.name, count: children.length })
      if (diffExpandedSchemas[schema.name] || needle) {
        ;(needle ? matches : children).forEach(function(object) { rows.push({ kind: "object", object: object }) })
      }
    })
    return rows
  }
  function diffObjectKey(object) { return JSON.stringify([object.schema, object.name]) }
  function diffChecked(row) {
    return row.kind === "schema" ? diffSelectedSchemas.indexOf(row.name) >= 0 : !!diffSelectedObjects[diffObjectKey(row.object)]
  }
  function toggleDiffRow(row, checked) {
    if (!diffCatalog) return
    var selected = Object.assign({}, diffSelectedObjects)
    var schemas = diffSelectedSchemas.slice()
    if (row.kind === "schema") {
      schemas = checked ? schemas.concat([row.name]).filter(function(name, index, list) { return list.indexOf(name) === index })
        : schemas.filter(function(name) { return name !== row.name })
      ;(diffCatalog.source.objects || []).forEach(function(object) {
        if (object.schema === row.name) selected[diffObjectKey(object)] = checked
      })
    } else {
      selected[diffObjectKey(row.object)] = checked
      if (checked && schemas.indexOf(row.object.schema) < 0) schemas.push(row.object.schema)
    }
    diffSelectedObjects = selected
    diffSelectedSchemas = schemas
    diffResult = null
    diffScript = ""
    diffPhase = "select"
  }
  function selectAllDiff(checked) {
    if (!diffCatalog) return
    diffSelectedSchemas = checked ? diffCatalog.source.schemas.map(function(schema) { return schema.name }) : []
    var selected = ({})
    ;(diffCatalog.source.objects || []).forEach(function(object) { selected[diffObjectKey(object)] = checked })
    diffSelectedObjects = selected
    diffResult = null
    diffScript = ""
    diffPhase = "select"
  }
  function diffSelectedCount() {
    if (!diffCatalog) return 0
    return (diffCatalog.source.objects || []).filter(function(object) { return !!diffSelectedObjects[diffObjectKey(object)] }).length
  }
  function compareDiff() {
    if (!diffCatalog || !diffSelectedSchemas.length || diffBusy) return
    var generation = ++diffGeneration
    diffBusy = true
    diffError = ""
    var selectedObjects = (diffCatalog.source.objects || []).filter(function(object) { return !!diffSelectedObjects[diffObjectKey(object)] })
      .map(function(object) { return diffObjectKey(object) })
    request("schemaDiff.compare", { sourceProfileId: diffSourceProfileId, targetProfileId: diffTargetProfileId,
      selectedSchemas: diffSelectedSchemas, selectedObjects: selectedObjects }, function(data, error) {
      if (generation !== diffGeneration || !diffDialog.visible) return
      diffBusy = false
      if (error) { diffError = error; return }
      diffResult = data
      var included = ({})
      ;(data.changes || []).forEach(function(change) { included[diffObjectKey(change)] = true })
      diffIncluded = included
      diffFocusedKey = ""
      diffPreview = null
      diffPhase = "results"
      var first = diffResultRows().find(function(row) { return row.kind === "object" })
      if (first) focusDiffChange(first.key)
    })
  }
  function diffResultRows() {
    if (!diffResult) return []
    var rows = []
    var changes = diffResult.changes || []
    ;[{ status: "missing", title: "Missing in Target" }, { status: "different", title: "Diff in Target" }].forEach(function(section) {
      var sectionChanges = changes.filter(function(change) { return section.status === "missing" ? !change.targetExists : change.targetExists })
      if (!sectionChanges.length) return
      rows.push({ kind: "section", label: section.title, count: sectionChanges.length })
      ;[{ type: "table", title: "Tables" }, { type: "view", title: "Views" }].forEach(function(group) {
        var items = sectionChanges.filter(function(change) { return change.type === group.type }).sort(function(a, b) {
          return (a.schema + "." + a.name).localeCompare(b.schema + "." + b.name, undefined, { sensitivity: "base" })
        })
        if (!items.length) return
        var groupKey = section.status + ":" + group.type
        rows.push({ kind: "group", label: group.title, groupKey: groupKey, count: items.length })
        items.forEach(function(change) { rows.push({ kind: "object", key: diffObjectKey(change), groupKey: groupKey, change: change }) })
      })
    })
    return rows
  }
  function diffGroupChanges(groupKey) {
    if (!diffResult) return []
    var parts = groupKey.split(":")
    return (diffResult.changes || []).filter(function(change) {
      return change.type === parts[1] && (parts[0] === "missing" ? !change.targetExists : change.targetExists)
    })
  }
  function diffIncludedCount(groupKey) {
    var changes = groupKey ? diffGroupChanges(groupKey) : diffResult ? diffResult.changes || [] : []
    return changes.filter(function(change) { return !!diffIncluded[diffObjectKey(change)] }).length
  }
  function toggleDiffIncluded(key, checked) {
    diffIncluded = Object.assign({}, diffIncluded, { [key]: checked })
    diffScript = ""
  }
  function toggleDiffGroup(groupKey, checked) {
    var included = Object.assign({}, diffIncluded)
    diffGroupChanges(groupKey).forEach(function(change) { included[diffObjectKey(change)] = checked })
    diffIncluded = included
    diffScript = ""
  }
  function focusDiffChange(key) {
    if (!diffResult || key === diffFocusedKey) return
    diffFocusedKey = key
    diffPreview = null
    diffError = ""
    diffViewSide = "changes"
    diffDetailTab = "difference"
    diffPreviewBusy = true
    var generation = ++diffPreviewGeneration
    request("schemaDiff.preview", { comparisonId: diffResult.comparisonId, objectKey: key }, function(data, error) {
      if (generation !== diffPreviewGeneration || !diffDialog.visible) return
      diffPreviewBusy = false
      if (error) { diffError = error; return }
      diffPreview = data
    })
  }
  function generateDiffScript() {
    if (!diffResult || diffBusy || diffIncludedCount() === 0) return
    var generation = ++diffGeneration
    diffBusy = true
    diffError = ""
    var selectedKeys = (diffResult.changes || []).filter(function(change) { return !!diffIncluded[diffObjectKey(change)] }).map(function(change) { return diffObjectKey(change) })
    request("schemaDiff.script", { comparisonId: diffResult.comparisonId, selectedKeys: selectedKeys }, function(data, error) {
      if (generation !== diffGeneration || !diffDialog.visible) return
      diffBusy = false
      if (error) { diffError = error; return }
      diffScript = String(data.sql || "")
      diffScriptComplete = data.complete === true
      diffManual = data.manual || []
      diffPhase = "script"
    })
  }
  function saveDiffScript(filePath) {
    if (!diffResult || !diffScript) return
    request("schemaDiff.save", { comparisonId: diffResult.comparisonId, filePath: filePath }, function(_, error) {
      if (!error) showNotice("Schema diff script saved", false)
    })
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
    else if (workerReady) {
      refreshProfiles()
      refreshAiAvailability()
    }
  }
  function close() {
    aiDialog.close()
    closingFromHost = true
    window.visible = false
    stoppingWorker = true
    connectionAttemptGeneration++
    worker.running = false
    workerReady = false
    ++aiStatusVersion
    aiAvailable = false
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
      if (entry.action !== "table.rows" && entry.action !== "table.describe" && entry.action !== "cell.get" && !/cancel/i.test(error)) showNotice(error, true)
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
      profilesLoaded = true
      if (activeProfile) {
        var found = profiles.find(function(profile) { return profile.id === activeProfile.id })
        if (found) activeProfile = Object.assign({}, activeProfile, found, {
          database: activeProfile.database,
          transportSecure: activeProfile.transportSecure,
          localConnection: activeProfile.localConnection
        })
      }
      maybeReopenLastConnection()
    })
  }
  function loadSettings() {
    var version = settingsVersion
    request("settings.get", {}, function(data, error) {
      if (error || version !== settingsVersion) return
      var value = Number(data.defaultLimit)
      if (Number.isInteger(value) && value >= 1 && value <= 1000) rowLimit = value
      reopenLastConnection = !!data.reopenLastConnection
      lastProfileId = data.lastProfileId || ""
      settingsLoaded = true
      maybeReopenLastConnection()
    })
  }
  function refreshAiAvailability() {
    var version = ++aiStatusVersion
    aiAvailable = false
    request("ai.status", {}, function(data, error) {
      if (version !== aiStatusVersion) return
      aiAvailable = !error && data.available === true
      if (!aiAvailable && aiDialog.visible && !aiError) aiDialog.close()
    })
  }
  function maybeReopenLastConnection() {
    if (automaticOpenAttempted || !workerReady || !settingsLoaded || !profilesLoaded ||
        !reopenLastConnection || !lastProfileId || connectionId || connecting) return
    automaticOpenAttempted = true
    var profile = profiles.find(function(item) { return item.id === lastProfileId })
    if (!profile || !profile.hasStoredConnection) {
      showNotice("The last connection is no longer available. Choose a connection.", true)
      return
    }
    openProfile(profile, undefined, true)
  }
  function rememberLastProfile(profile) {
    var id = profile && profile.hasStoredConnection ? profile.id : null
    lastProfileId = id || ""
    request("settings.save", { lastProfileId: id }, function(_, error) {
      if (error) showNotice("Could not remember the last connection.", true)
    })
  }
  function setReopenLastConnection(enabled) {
    var next = !!enabled
    if (next === reopenLastConnection) return
    var previous = reopenLastConnection
    var version = ++settingsVersion
    reopenLastConnection = next
    request("settings.save", { reopenLastConnection: next }, function(data, error) {
      if (version !== settingsVersion) return
      if (error) {
        reopenLastConnection = previous
        reopenCheck.checked = previous
        showNotice("Could not save the reconnect setting.", true)
        return
      }
      reopenLastConnection = !!data.reopenLastConnection
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
    closeCellViewer()
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
      return Object.assign({}, tab, { columns: [], rows: [], cellRefs: [], rowCount: 0, hasMore: false, durationMs: 0, busy: false, error: "", message: "", pendingId: 0 })
    })
    if (tabs.length === 0) {
      var id = "query-" + nextTabId++
      tabs = [{ id: id, kind: "query", title: "Query " + (nextTabId - 1), sql: "", columns: [], rows: [], cellRefs: [], rowCount: 0, hasMore: false, durationMs: 0, busy: false, error: "", message: "", pendingId: 0 }]
    }
    if (!tabs.some(function(tab) { return tab.id === activeTabId })) activeTabId = tabs[0].id
    resultsExpanded = false
  }
  function disconnect() {
    connectionAttemptGeneration++
    automaticOpenAttempted = true
    if (lastProfileId) rememberLastProfile(null)
    if (!connectionId) return
    var oldId = connectionId
    connectionId = ""
    activeProfile = null
    clearDatabaseState()
    request("connection.close", { connectionId: oldId }, function() {})
    showNotice("Disconnected", false)
  }
  function openProfile(profile, password, automatic) {
    if (!profile) return
    if (!automatic) automaticOpenAttempted = true
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
        rememberLastProfile(activeProfile)
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
    var schemaMatches = schemaName.toLowerCase().includes(needle)
    return list.filter(function(object) {
      return (objectTypeFilter === "all" || object.type === objectTypeFilter)
        && (schemaMatches || object.name.toLowerCase().includes(needle) || object.type.toLowerCase().includes(needle))
    })
  }
  function filteredSchemas() {
    return schemas.filter(function(schema) {
      return filteredObjects(schema.name).length > 0
    })
  }
  function visibleSchemaEntries() {
    var entries = []
    var visible = filteredSchemas()
    for (var i = 0; i < visible.length; i++) {
      var name = visible[i].name
      entries.push({ kind: "schema", name: name, count: filteredObjects(name).length })
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
  function captureCell(cell) {
    if (!cell || !activeTab || !connectionId) return null
    return { connectionId: connectionId, tabId: activeTabId, rows: activeTab.rows, cell: cell }
  }
  function cellSnapshotCurrent(snapshot) {
    if (!snapshot || snapshot.connectionId !== connectionId || snapshot.tabId !== activeTabId || !activeTab || activeTab.rows !== snapshot.rows) return false
    var row = activeTab.rows[snapshot.cell.row]
    var grid = activeTab.kind === "query" ? queryGrid : tableGrid
    if (!row || snapshot.cell.column < 0 || snapshot.cell.column >= row.length || !grid
        || grid.selectedRow !== snapshot.cell.row || grid.selectedColumn !== snapshot.cell.column) return false
    var selected = grid.selectedCell()
    return !!selected && selected.handle === snapshot.cell.handle && selected.preview === snapshot.cell.preview
  }
  function copyPlainText(value) {
    clipboardBuffer.text = String(value)
    clipboardBuffer.selectAll()
    clipboardBuffer.copy()
    clipboardBuffer.deselect()
    clipboardBuffer.text = ""
    showNotice("Copied to clipboard", false)
  }
  function copyCellValue(cell) {
    var snapshot = captureCell(cell)
    if (!snapshot) return
    if (cell.complete) { copyPlainText(cell.preview); return }
    if (!cell.handle) { showNotice("The full value is unavailable; the preview was not copied.", true); return }
    request("cell.get", { connectionId: snapshot.connectionId, handle: cell.handle }, function(data, error) {
      if (!cellSnapshotCurrent(snapshot)) return
      if (error || !data || typeof data.text !== "string") {
        showNotice("Could not copy the full value. Reload the results and try again.", true)
        return
      }
      copyPlainText(data.text)
    })
  }
  function closeCellViewer() {
    viewerGeneration++
    cellViewerDialog.close()
  }
  function openCellViewer(cell) {
    var snapshot = captureCell(cell)
    if (!snapshot) return
    var generation = ++viewerGeneration
    viewedCell = cell
    viewedSnapshot = snapshot
    viewerText = cell.preview
    viewerError = ""
    viewerLoading = !cell.complete && !!cell.handle
    viewerComplete = !!cell.complete
    viewerMode = "text"
    viewerJsonText = ""
    cellViewerDialog.open()
    if (cell.complete) return
    if (!cell.handle) {
      viewerError = "Full value unavailable. This is only a preview."
      return
    }
    request("cell.get", { connectionId: snapshot.connectionId, handle: cell.handle }, function(data, error) {
      if (generation !== viewerGeneration || !cellViewerDialog.visible || !cellSnapshotCurrent(snapshot)) return
      viewerLoading = false
      if (error || !data || typeof data.text !== "string") {
        viewerError = "Full value unavailable. Reload the results and try again."
        return
      }
      viewerText = data.text
      viewerComplete = true
      viewedCell = Object.assign({}, cell, { byteLength: data.byteLength })
    })
  }
  function setViewerMode(mode) {
    if (mode === "json") {
      if (!viewerComplete) return
      if (!viewerJsonText) {
        try { viewerJsonText = JSON.stringify(JSON.parse(viewerText), null, 2) }
        catch (_) { viewerError = "This value is not valid JSON."; return }
      }
    }
    if (viewerComplete) viewerError = ""
    viewerMode = mode
  }
  function findInViewer() {
    var needle = viewerSearch.text.toLocaleLowerCase()
    if (!needle) return
    var haystack = viewerTextArea.text.toLocaleLowerCase()
    var start = Math.max(0, viewerTextArea.selectionEnd)
    var match = haystack.indexOf(needle, start)
    if (match < 0) match = haystack.indexOf(needle)
    if (match < 0) { viewerError = "No match for “" + viewerSearch.text + "”."; return }
    viewerError = ""
    viewerTextArea.select(match, match + needle.length)
    viewerTextArea.forceActiveFocus()
  }
  function syncEditor() {
    if (!sqlEditor) return
    syncingEditor = true
    var desired = activeTab && activeTab.kind === "query" ? activeTab.sql : ""
    if (sqlEditor.text !== desired) sqlEditor.text = desired
    syncingEditor = false
  }
  onActiveTabIdChanged: { closeCellViewer(); resultsExpanded = false; syncEditor() }
  onTabsChanged: {
    if (cellViewerDialog.visible && !cellSnapshotCurrent(viewedSnapshot)) closeCellViewer()
  }
  function newQuery(sql, title) {
    var id = "query-" + nextTabId++
    tabs = tabs.concat([{ id: id, kind: "query", title: title || ("Query " + (nextTabId - 1)), sql: sql || "", columns: [], rows: [], cellRefs: [], durationMs: 0, rowCount: 0, hasMore: false, busy: false, error: "", message: "", pendingId: 0 }])
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
    updateTab(tabId, { busy: true, error: "", message: "Running query…", columns: [], rows: [], cellRefs: [] })
    resultPane = "results"
    var requestId = request("query.run", { connectionId: queryConnectionId, sql: sql, limit: rowLimit, timeoutMs: timeoutMs }, function(data, error) {
      if (queryConnectionId !== connectionId) return
      var currentTab = tabs.find(function(entry) { return entry.id === tabId })
      if (!currentTab || currentTab.pendingId !== requestId) return
      if (error) {
        var cancelled = /cancel/i.test(error)
        updateTab(tabId, { busy: false, pendingId: 0, error: cancelled ? "" : error, message: cancelled ? (activeProfile && activeProfile.type === "cloudflare_d1" ? "Stopped waiting. Cloudflare may still finish the query." : "Query cancelled") : error })
        if (cancelled) showNotice(activeProfile && activeProfile.type === "cloudflare_d1" ? "Stopped waiting. Cloudflare may still finish the query." : "Query cancelled", false)
        return
      }
      updateTab(tabId, { busy: false, pendingId: 0, columns: data.columns || [], rows: data.rows || [], cellRefs: data.cellRefs || [], rowCount: data.rowCount || 0, hasMore: !!data.hasMore, durationMs: data.durationMs || 0, message: data.message || "Query completed" })
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
  function openAiDialog() {
    if (!aiAvailable) return
    var tab = activeTab
    if (!tab || tab.kind !== "query") return
    aiTabId = tab.id
    aiConnectionId = connectionId
    aiOriginalSql = String(tab.sql || "")
    aiLastError = String(tab.error || "")
    aiDraft = ""
    aiExplanation = ""
    aiError = ""
    aiPromptField.text = aiLastError ? "Fix this query" : ""
    aiDialog.open()
    aiPromptField.forceActiveFocus()
  }
  function generateAiQuery() {
    if (!aiAvailable || aiBusy || !aiPromptField.text.trim()) return
    if (!aiConnectionId || aiConnectionId !== connectionId) {
      aiError = "Connect to a database before asking AI to write SQL."
      return
    }
    aiError = ""
    aiDraft = ""
    aiExplanation = ""
    aiBusy = true
    var generation = ++aiGeneration
    var targetConnection = aiConnectionId
    aiRequestId = request("ai.generate", {
      connectionId: targetConnection,
      instruction: aiPromptField.text.trim(),
      sql: aiOriginalSql,
      error: aiLastError,
      selected: selectedObject ? { schema: selectedObject.schema, name: selectedObject.name } : null
    }, function(data, error) {
      if (generation !== aiGeneration) return
      aiBusy = false
      aiRequestId = 0
      if (targetConnection !== connectionId) {
        aiError = "The database connection changed. Open Ask AI again."
        return
      }
      if (error) {
        aiError = error
        if (/not installed or signed in|not configured|not available yet/.test(error)) refreshAiAvailability()
        return
      }
      aiDraft = String(data.sql || "")
      aiExplanation = String(data.explanation || "")
      if (!aiDraft && !aiExplanation) aiError = "AI did not return a query. Try a more specific request."
    })
  }
  function cancelAiQuery() {
    ++aiGeneration
    if (aiRequestId) request("ai.cancel", { targetId: aiRequestId }, function() {})
    aiRequestId = 0
    aiBusy = false
  }
  function useAiQuery() {
    if (!aiDraft || aiConnectionId !== connectionId) {
      aiError = "The database connection changed. Open Ask AI again."
      return
    }
    var tab = tabs.find(function(entry) { return entry.id === aiTabId })
    if (!tab || tab.kind !== "query") {
      aiError = "The query tab is no longer open."
      return
    }
    activeTabId = aiTabId
    updateTab(aiTabId, { sql: aiDraft, error: "", message: "AI draft ready to review" })
    syncEditor()
    aiDialog.close()
    sqlEditor.forceActiveFocus()
  }
  function quoteName(name) {
    var type = activeProfile ? activeProfile.type : ""
    if (type === "postgres" || type === "cloudflare_d1") return '"' + String(name).replace(/"/g, '""') + '"'
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
      tabs = tabs.concat([{ id: id, kind: "table", title: object.name, object: object, tablePane: "data", columns: [], rows: [], cellRefs: [], hasMore: false, offset: 0, pageOffsets: [0], definition: null, busy: false, pendingRowsId: 0, definitionRequestId: 0, error: "" }])
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
        if (/cancel/i.test(error)) showNotice(activeProfile && activeProfile.type === "cloudflare_d1" ? "Stopped waiting. Cloudflare may still finish the table query." : "Table load cancelled", false)
        return
      }
      var pageOffset = Number.isInteger(data.offset) ? data.offset : offset
      var pageOffsets = currentTab.pageOffsets || [0]
      if (pageOffset === 0) pageOffsets = [0]
      else {
        var priorIndex = pageOffsets.indexOf(pageOffset)
        if (priorIndex >= 0) pageOffsets = pageOffsets.slice(0, priorIndex + 1)
        else if (pageOffset > currentTab.offset) pageOffsets = pageOffsets.concat([pageOffset])
      }
      updateTab(tabId, { busy: false, pendingRowsId: 0, columns: data.columns || [], rows: data.rows || [], cellRefs: data.cellRefs || [], hasMore: !!data.hasMore, offset: pageOffset, pageOffsets: pageOffsets })
    })
    updateTab(tabId, { pendingRowsId: requestId })
  }
  function nextTablePage(tabId) {
    var tab = tabs.find(function(entry) { return entry.id === tabId })
    if (!tab || !tab.hasMore || tab.rows.length === 0) return
    loadTableRows(tabId, tab.offset + tab.rows.length)
  }
  function previousTablePage(tabId) {
    var tab = tabs.find(function(entry) { return entry.id === tabId })
    if (!tab) return
    var offsets = tab.pageOffsets || [0]
    var index = offsets.indexOf(tab.offset)
    if (index > 0) loadTableRows(tabId, offsets[index - 1])
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
    agentAccessCheck.checked = !!candidate.agentAccess
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
    var isD1 = engineOptions[enginePicker.currentIndex].value === "cloudflare_d1"
    var raw = isD1 ? "" : connectionStringInput.text.trim()
    if (!name) { formError.text = "Give this connection a name"; return }
    var hasStructured = !!(hostInput.text.trim() || databaseInput.text.trim() || userInput.text.trim() || passwordInput.text)
    var renameOnly = !!editingProfileId && !raw && !hasStructured
    if (!raw && !renameOnly && !hostInput.text.trim()) { formError.text = isD1 ? "Enter a Cloudflare Account ID" : "Enter a host or paste a connection string"; return }
    if (!raw && !renameOnly && !databaseInput.text.trim()) { formError.text = isD1 ? "Enter a Cloudflare Database ID" : "Enter a database name"; return }
    if (isD1 && !renameOnly && !passwordInput.text) { formError.text = "Enter a Cloudflare API token"; return }
    if (raw && passwordInput.text) { formError.text = "Use either a complete connection string or the password field"; return }
    var type = engineOptions[enginePicker.currentIndex].value
    var secret = passwordInput.text
    var payload = {
      profile: { id: editingProfileId || undefined, name: name, type: type,
        host: hostInput.text.trim(), port: Number(portInput.text) || undefined,
        database: databaseInput.text.trim(), user: userInput.text.trim(),
        accountId: isD1 ? hostInput.text.trim() : undefined, databaseId: isD1 ? databaseInput.text.trim() : undefined,
        ssl: sslCheck.checked, encrypt: type === "azure_sql" ? true : sslCheck.checked,
        trustServerCertificate: false },
      savePassword: rememberCheck.checked,
      agentAccess: rememberCheck.checked && agentAccessCheck.checked
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
      if (!error) {
        if (lastProfileId === id) rememberLastProfile(null)
        refreshProfiles()
        showNotice("Connection removed", false)
      }
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
      root.profilesLoaded = false
      root.settingsLoaded = false
      root.automaticOpenAttempted = false
      root.workerReady = true
      root.flushRequests()
      root.refreshProfiles()
      root.loadSettings()
      root.refreshAiAvailability()
    }
    onRunningChanged: {
      if (!running && root.workerHasStarted) {
        root.workerHasStarted = false
        root.workerReady = false
        ++root.aiStatusVersion
        root.aiAvailable = false
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
    property string helpText: ""
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
    opacity: buttonEnabled ? 1 : 0.65
    Row {
      id: content
      anchors.centerIn: parent
      spacing: 9
      StudioIcon { width: 16; height: 16; iconName: button.iconName; visible: button.iconName !== "" }
      Text {
        text: button.label
        color: button.prominent && button.buttonEnabled ? root.bg : root.ink
        font.family: root.uiFont
        font.pixelSize: Math.max(14, Style.font.body)
        font.bold: button.prominent
      }
    }
    HoverHandler { id: hovered }
    ToolTip.visible: hovered.hovered && button.helpText !== ""
    ToolTip.text: button.helpText
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
    objectName: "dbStudioWindow"
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
            StudioTab { label: "Schema diff"; onClicked: root.openDiffDialog() }
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
              Text { Layout.fillWidth: true; visible: root.connectionId !== "" && !!root.activeProfile && root.activeProfile.transportSecure === false && !root.activeProfile.localConnection; text: "Unencrypted remote connection. Credentials and data may travel in plaintext."; textFormat: Text.PlainText; color: Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
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
                Text { Layout.fillWidth: true; visible: root.databaseError !== ""; text: root.databaseError; textFormat: Text.PlainText; color: Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
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
                spacing: 8
                Text { text: "Show"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
                ComboBox {
                  id: objectTypeChoice
                  objectName: "objectTypeFilterChoice"
                  Layout.fillWidth: true
                  implicitHeight: 38
                  font.family: root.uiFont
                  font.pixelSize: Math.max(13, Style.font.bodySmall)
                  model: ["All objects", "Tables only", "Views only"]
                  currentIndex: ["all", "table", "view"].indexOf(root.objectTypeFilter)
                  Accessible.name: "Show object types"
                  onActivated: root.objectTypeFilter = ["all", "table", "view"][currentIndex]
                  contentItem: Text { text: objectTypeChoice.displayText; color: root.ink; font: objectTypeChoice.font; verticalAlignment: Text.AlignVCenter; leftPadding: 10; rightPadding: 24; elide: Text.ElideRight }
                  indicator: Text { x: objectTypeChoice.width - width - 9; anchors.verticalCenter: parent.verticalCenter; text: "⌄"; color: root.softInk }
                  background: Rectangle { color: root.surface; radius: 5; border.width: objectTypeChoice.activeFocus ? 2 : 1; border.color: objectTypeChoice.activeFocus ? root.accent : root.line }
                  delegate: ItemDelegate {
                    id: objectTypeOption
                    required property var modelData
                    required property int index
                    width: objectTypeChoice.width
                    height: 36
                    contentItem: Text { text: objectTypeOption.modelData; color: root.ink; font: objectTypeChoice.font; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
                    background: Rectangle { color: objectTypeChoice.highlightedIndex === objectTypeOption.index ? root.selected : root.bg }
                  }
                  popup: Popup {
                    y: objectTypeChoice.height
                    width: objectTypeChoice.width
                    padding: 4
                    implicitHeight: contentItem.implicitHeight + 8
                    contentItem: ListView { clip: true; implicitHeight: contentHeight; model: objectTypeChoice.popup.visible ? objectTypeChoice.delegateModel : null; currentIndex: objectTypeChoice.highlightedIndex }
                    background: Rectangle { color: root.bg; radius: 5; border.width: 1; border.color: root.accent }
                  }
                }
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
                color: Qt.rgba(Theme.Color.urgent.r, Theme.Color.urgent.g, Theme.Color.urgent.b, 0.12)
                RowLayout {
                  anchors.fill: parent
                  anchors.margins: 8
                  spacing: 8
                  Text {
                    id: schemaErrorText
                    Layout.fillWidth: true
                    text: root.schemaError
                    textFormat: Text.PlainText
                    color: Theme.Color.urgent
                    font.family: root.uiFont
                    font.pixelSize: Math.max(12, Style.font.caption)
                    wrapMode: Text.WordWrap
                  }
                  StudioButton { label: "Retry"; compact: true; buttonEnabled: root.connectionId !== ""; onClicked: root.loadSchema() }
                }
              }
              Item {
                id: schemaScroll
                objectName: "schemaBrowserArea"
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
                  objectName: "schemaEmptyMessage"
                  text: !root.connectionId ? "Connect to browse schemas and tables." : root.objectSearch.trim() ? "No matching objects." : root.objectTypeFilter === "table" ? "No tables found." : root.objectTypeFilter === "view" ? "No views found." : "No tables or views found."
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
                    StudioButton { label: "✦ Ask AI"; compact: true; visible: root.aiAvailable; helpText: "Build or fix this query with AI"; Accessible.name: "Ask AI"; onClicked: root.openAiDialog() }
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
                      id: queryGrid
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      Layout.margins: 11
                      visible: root.resultPane === "results"
                      columns: root.activeTab ? root.activeTab.columns : []
                      rows: root.activeTab ? root.activeTab.rows : []
                      cellRefs: root.activeTab ? root.activeTab.cellRefs || [] : []
                      busy: root.activeTab ? root.activeTab.busy : false
                      error: root.activeTab ? root.activeTab.error : ""
                      hasMore: root.activeTab ? root.activeTab.hasMore : false
                      emptyText: "The query returned no rows"
                      onViewCell: function(cell) { root.openCellViewer(cell) }
                      onCopyCell: function(cell) { root.copyCellValue(cell) }
                      onCopyColumnName: function(name) { root.copyPlainText(name) }
                    }
                    Text {
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      Layout.margins: 20
                      visible: root.resultPane === "messages"
                      text: root.activeTab ? (root.activeTab.message || "") : ""
                      textFormat: Text.PlainText
                      color: root.activeTab && root.activeTab.error ? Theme.Color.urgent : root.ink
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
                  id: tableGrid
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.margins: 12
                  visible: root.activeTab && root.activeTab.tablePane === "data"
                  columns: root.activeTab ? root.activeTab.columns : []
                  rows: root.activeTab ? root.activeTab.rows : []
                  cellRefs: root.activeTab ? root.activeTab.cellRefs || [] : []
                  busy: root.activeTab ? root.activeTab.busy : false
                  error: root.activeTab ? root.activeTab.error : ""
                  paged: true
                  offset: root.activeTab ? root.activeTab.offset || 0 : 0
                  hasMore: root.activeTab ? root.activeTab.hasMore : false
                  limit: root.rowLimit
                  onNextPage: root.nextTablePage(root.activeTab.id)
                  onPreviousPage: root.previousTablePage(root.activeTab.id)
                  onViewCell: function(cell) { root.openCellViewer(cell) }
                  onCopyCell: function(cell) { root.copyCellValue(cell) }
                  onCopyColumnName: function(name) { root.copyPlainText(name) }
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
          color: root.noticeError ? Qt.rgba(Theme.Color.urgent.r, Theme.Color.urgent.g, Theme.Color.urgent.b, 0.13) : root.surface
          Text { anchors.fill: parent; anchors.leftMargin: 16; verticalAlignment: Text.AlignVCenter; text: root.notice; textFormat: Text.PlainText; color: root.noticeError ? Theme.Color.urgent : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); elide: Text.ElideRight }
        }
      }
    }

    TextEdit {
      id: clipboardBuffer
      width: 1
      height: 1
      opacity: 0
      textFormat: TextEdit.PlainText
      readOnly: true
      visible: true
    }

    Dialog {
      id: aiDialog
      parent: window.contentItem
      modal: true
      title: "Ask AI"
      anchors.centerIn: parent
      width: Math.min(680, window.width - 48)
      height: Math.min(640, window.height - 48)
      padding: 0
      onClosed: root.cancelAiQuery()
      Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.56) }
      background: Rectangle {
        color: Qt.tint(root.bg, Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.10))
        border.width: 2
        border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
        radius: 10
      }
      header: Rectangle {
        implicitHeight: 62
        color: root.bg
        radius: 10
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.25) }
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 16
          spacing: 10
          Text { text: "✦"; color: root.accent; font.family: root.uiFont; font.pixelSize: 25 }
          Text { Layout.fillWidth: true; text: "Ask AI"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(19, Style.font.heading); font.bold: true }
          StudioButton { label: "Close"; compact: true; onClicked: aiDialog.close() }
        }
      }
      contentItem: Item {
        ColumnLayout {
          anchors.fill: parent
          spacing: 10
          Text {
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            Layout.topMargin: 18
            text: "YOUR REQUEST"
            color: root.accent
            font.family: root.uiFont
            font.pixelSize: Math.max(12, Style.font.caption)
            font.bold: true
            font.letterSpacing: 1.1
          }
          Text {
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            text: "Describe the query you want, or ask AI to fix the SQL in this tab."
            textFormat: Text.PlainText
            color: root.ink
            font.family: root.uiFont
            font.pixelSize: Math.max(14, Style.font.body)
            wrapMode: Text.WordWrap
          }
          ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 112
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            clip: true
            TextArea {
              id: aiPromptField
              placeholderText: "E.g. Show the 20 newest orders with customer names…"
              textFormat: TextEdit.PlainText
              wrapMode: TextEdit.Wrap
              selectByMouse: true
              color: root.ink
              placeholderTextColor: root.softInk
              selectionColor: root.accent
              selectedTextColor: root.bg
              font.family: root.uiFont
              font.pixelSize: Math.max(14, Style.font.body)
              background: Rectangle { color: root.bg; border.width: aiPromptField.activeFocus ? 2 : 1; border.color: aiPromptField.activeFocus ? root.accent : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.35); radius: 6 }
            }
          }
          Text {
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            text: root.connectionId === "" ? "Connect to a database to generate SQL with schema context."
              : "Sends this tab's SQL" + (root.aiLastError ? ", its last error" : "") + ", and compact schema details to your Omarchy agent. The prompt excludes row data and connection credentials."
            textFormat: Text.PlainText
            color: root.softInk
            font.family: root.uiFont
            font.pixelSize: Math.max(12, Style.font.caption)
            wrapMode: Text.WordWrap
          }
          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.25) }
          RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            Text { Layout.fillWidth: true; text: "SUGGESTED SQL"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1 }
            Text { text: root.aiBusy ? "Generating…" : "Review before running"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
          }
          ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 90
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            Layout.bottomMargin: 10
            clip: true
            TextArea {
              text: root.aiDraft
              placeholderText: root.aiBusy ? "Choosing relevant tables and drafting SQL…" : "Your suggested query will appear here."
              textFormat: TextEdit.PlainText
              readOnly: true
              selectByMouse: true
              wrapMode: TextEdit.NoWrap
              color: root.ink
              placeholderTextColor: root.softInk
              selectionColor: root.accent
              selectedTextColor: root.bg
              font.family: root.codeFont
              font.pixelSize: Math.max(14, Style.font.body)
              background: Rectangle { color: root.bg; border.width: 1; border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.3); radius: 6 }
            }
          }
          Text {
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            Layout.bottomMargin: 8
            visible: root.aiExplanation !== "" || root.aiError !== ""
            text: root.aiError || root.aiExplanation
            textFormat: Text.PlainText
            color: root.aiError ? Theme.Color.urgent : root.ink
            font.family: root.uiFont
            font.pixelSize: Math.max(13, Style.font.bodySmall)
            wrapMode: Text.WordWrap
          }
        }
      }
      footer: Rectangle {
        implicitHeight: 62
        color: root.bg
        radius: 10
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.25) }
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 20
          spacing: 10
          Item { Layout.fillWidth: true }
          StudioButton { label: root.aiBusy ? "Cancel request" : "Cancel"; compact: true; onClicked: aiDialog.close() }
          StudioButton { label: "Generate"; compact: true; buttonEnabled: root.aiAvailable && !root.aiBusy && root.connectionId !== "" && aiPromptField.text.trim() !== ""; onClicked: root.generateAiQuery() }
          StudioButton { label: "Use in editor"; compact: true; prominent: true; buttonEnabled: root.aiDraft !== "" && !root.aiBusy; onClicked: root.useAiQuery() }
        }
      }
    }

    FileDialog {
      id: diffSaveDialog
      title: "Save schema diff script"
      fileMode: FileDialog.SaveFile
      defaultSuffix: "sql"
      nameFilters: ["SQL script (*.sql)"]
      onAccepted: root.saveDiffScript(decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")))
    }

    Dialog {
      id: diffTargetOnlyDialog
      parent: window.contentItem
      modal: true
      title: "Only in target"
      anchors.centerIn: parent
      width: Math.min(640, window.width - 72)
      height: Math.min(520, window.height - 72)
      padding: 16
      Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.46) }
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.accent; radius: 8 }
      header: Rectangle {
        implicitHeight: 55
        color: root.raised
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 16
          anchors.rightMargin: 16
          Text { Layout.fillWidth: true; text: "Only in target · left unchanged"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(16, Style.font.body); font.bold: true }
          StudioButton { label: "Close"; compact: true; onClicked: diffTargetOnlyDialog.close() }
        }
      }
      contentItem: ListView {
        clip: true
        model: root.diffResult ? root.diffResult.targetOnly.slice().sort(function(a, b) { return (a.schema + "." + a.name).localeCompare(b.schema + "." + b.name, undefined, { sensitivity: "base" }) }) : []
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: RowLayout {
          required property var modelData
          width: ListView.view.width
          height: 36
          Text { Layout.fillWidth: true; text: modelData.schema + "." + modelData.name; textFormat: Text.PlainText; color: root.ink; font.family: root.codeFont; font.pixelSize: Math.max(13, Style.font.bodySmall); elide: Text.ElideRight }
          Text { text: modelData.type; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
        }
      }
    }

    Dialog {
      id: diffDialog
      parent: window.contentItem
      modal: true
      title: "Schema diff"
      anchors.centerIn: parent
      width: Math.min(1000, window.width - 44)
      height: Math.min(790, window.height - 44)
      padding: 0
      onClosed: { diffTargetOnlyDialog.close(); root.resetDiffResults() }
      Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.56) }
      background: Rectangle { color: root.bg; border.width: 2; border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.65); radius: 10 }
      header: Rectangle {
        implicitHeight: 62
        color: root.raised
        radius: 10
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: root.line }
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 20
          Text { Layout.fillWidth: true; text: "Schema diff"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(19, Style.font.heading); font.bold: true }
          Text { text: "SQL Server · Azure SQL"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
          StudioButton { label: "Close"; compact: true; onClicked: diffDialog.close() }
        }
      }
      contentItem: Item {
        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 20
          spacing: 12
          Text {
            Layout.fillWidth: true
            text: root.diffPhase === "setup" ? "Choose the source and target databases. The script will make the target match selected source objects."
              : root.diffPhase === "select" ? "Select schemas, tables, and views. Only checked objects are compared; all start checked."
              : root.diffPhase === "results" ? "Review the differences before generating a source-to-target script."
              : "Review the SQL before saving or copying it. DB Studio will not run this script."
            textFormat: Text.PlainText
            color: root.ink
            font.family: root.uiFont
            font.pixelSize: Math.max(14, Style.font.body)
            wrapMode: Text.WordWrap
          }
          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
          StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: root.diffPhase === "setup" ? 0 : root.diffPhase === "select" ? 1 : root.diffPhase === "results" ? 2 : 3

            Item {
              ColumnLayout {
                anchors.fill: parent
                spacing: 16
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 16
                  ColumnLayout {
                    Layout.fillWidth: true
                    Text { text: "SOURCE"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true }
                    ComboBox {
                      id: diffSourcePicker
                      Layout.fillWidth: true
                      implicitHeight: 40
                      model: [{ id: "", name: "Choose source…" }].concat(root.diffProfiles())
                      textRole: "name"
                      currentIndex: root.diffProfileIndex(root.diffSourceProfileId)
                      onActivated: function(index) {
                        var profile = root.diffProfiles()[index - 1]
                        if (profile) { root.diffSourceProfileId = profile.id; root.resetDiffResults() }
                      }
                      contentItem: Text { text: diffSourcePicker.displayText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); verticalAlignment: Text.AlignVCenter; leftPadding: 10; elide: Text.ElideRight }
                      background: Rectangle { color: root.surface; border.width: 1; border.color: root.line; radius: 5 }
                      delegate: ItemDelegate {
                        id: sourceOption
                        required property var modelData
                        required property int index
                        width: diffSourcePicker.width
                        height: 38
                        text: modelData.name
                        contentItem: Text { text: sourceOption.text; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); verticalAlignment: Text.AlignVCenter; leftPadding: 10; elide: Text.ElideRight }
                        background: Rectangle { color: diffSourcePicker.highlightedIndex === sourceOption.index ? root.selected : root.bg }
                      }
                      popup: Popup {
                        y: diffSourcePicker.height - 1
                        width: diffSourcePicker.width
                        implicitHeight: Math.min(contentItem.implicitHeight + 8, 300)
                        padding: 4
                        contentItem: ListView { clip: true; implicitHeight: contentHeight; model: diffSourcePicker.popup.visible ? diffSourcePicker.delegateModel : null; currentIndex: diffSourcePicker.highlightedIndex; ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded } }
                        background: Rectangle { color: root.bg; border.width: 1; border.color: root.accent; radius: 5 }
                      }
                    }
                  }
                  Text { text: "→"; color: root.accent; font.family: root.uiFont; font.pixelSize: 26 }
                  ColumnLayout {
                    Layout.fillWidth: true
                    Text { text: "TARGET"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true }
                    ComboBox {
                      id: diffTargetPicker
                      Layout.fillWidth: true
                      implicitHeight: 40
                      model: [{ id: "", name: "Choose target…" }].concat(root.diffProfiles())
                      textRole: "name"
                      currentIndex: root.diffProfileIndex(root.diffTargetProfileId)
                      onActivated: function(index) {
                        var profile = root.diffProfiles()[index - 1]
                        if (profile) { root.diffTargetProfileId = profile.id; root.resetDiffResults() }
                      }
                      contentItem: Text { text: diffTargetPicker.displayText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); verticalAlignment: Text.AlignVCenter; leftPadding: 10; elide: Text.ElideRight }
                      background: Rectangle { color: root.surface; border.width: 1; border.color: root.line; radius: 5 }
                      delegate: ItemDelegate {
                        id: targetOption
                        required property var modelData
                        required property int index
                        width: diffTargetPicker.width
                        height: 38
                        text: modelData.name
                        contentItem: Text { text: targetOption.text; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); verticalAlignment: Text.AlignVCenter; leftPadding: 10; elide: Text.ElideRight }
                        background: Rectangle { color: diffTargetPicker.highlightedIndex === targetOption.index ? root.selected : root.bg }
                      }
                      popup: Popup {
                        y: diffTargetPicker.height - 1
                        width: diffTargetPicker.width
                        implicitHeight: Math.min(contentItem.implicitHeight + 8, 300)
                        padding: 4
                        contentItem: ListView { clip: true; implicitHeight: contentHeight; model: diffTargetPicker.popup.visible ? diffTargetPicker.delegateModel : null; currentIndex: diffTargetPicker.highlightedIndex; ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded } }
                        background: Rectangle { color: root.bg; border.width: 1; border.color: root.accent; radius: 5 }
                      }
                    }
                  }
                }
                Text {
                  Layout.fillWidth: true
                  text: root.diffProfiles().length < 2 ? "Add at least two SQL Server or Azure SQL connections to compare." :
                    !root.diffSourceProfileId || !root.diffTargetProfileId ? "Choose both connections. The script applies changes to the target database." :
                    root.diffSourceProfileId === root.diffTargetProfileId ? "Choose two different connections." :
                    "The comparison reads schema metadata from both connections. No table rows are read."
                  textFormat: Text.PlainText
                  color: root.softInk
                  font.family: root.uiFont
                  font.pixelSize: Math.max(13, Style.font.bodySmall)
                  wrapMode: Text.WordWrap
                }
                Item { Layout.fillHeight: true }
              }
            }

            Item {
              ColumnLayout {
                anchors.fill: parent
                spacing: 9
                RowLayout {
                  Layout.fillWidth: true
                  Text { Layout.fillWidth: true; text: root.diffCatalog ? root.diffCatalog.sourceName + " (" + root.diffCatalog.sourceDatabase + ") → " + root.diffCatalog.targetName + " (" + root.diffCatalog.targetDatabase + ") · " + root.diffSelectedCount() + " objects checked" : ""; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: true; elide: Text.ElideRight }
                  StudioButton { label: "Select all"; compact: true; onClicked: root.selectAllDiff(true) }
                  StudioButton { label: "Clear all"; compact: true; onClicked: root.selectAllDiff(false) }
                }
                StudioField { Layout.fillWidth: true; placeholderText: "Filter schemas, tables, and views…"; text: root.diffFilter; onTextChanged: root.diffFilter = text }
                Rectangle {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  color: root.surface
                  border.width: 1
                  border.color: root.line
                  radius: 6
                  ListView {
                    anchors.fill: parent
                    anchors.margins: 5
                    clip: true
                    spacing: 1
                    model: root.diffRows()
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    delegate: Rectangle {
                      id: diffSelectionRow
                      required property var modelData
                      readonly property bool schemaRow: modelData.kind === "schema"
                      width: ListView.view.width
                      height: 38
                      color: diffRowHover.hovered ? root.raised : "transparent"
                      radius: 5
                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: diffSelectionRow.schemaRow ? 10 : 44
                        anchors.rightMargin: 10
                        spacing: 9
                        Text {
                          visible: diffSelectionRow.schemaRow
                          text: root.diffExpandedSchemas[diffSelectionRow.modelData.name] ? "⌄" : "›"
                          color: root.softInk
                          font.pixelSize: 20
                          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.diffExpandedSchemas = Object.assign({}, root.diffExpandedSchemas, { [diffSelectionRow.modelData.name]: !root.diffExpandedSchemas[diffSelectionRow.modelData.name] }) }
                        }
                        StudioCheck { text: ""; checked: root.diffChecked(diffSelectionRow.modelData); onToggled: root.toggleDiffRow(diffSelectionRow.modelData, checked) }
                        StudioIcon { Layout.preferredWidth: 16; Layout.preferredHeight: 16; iconName: diffSelectionRow.schemaRow ? "server-database" : diffSelectionRow.modelData.object.type === "view" ? "view-list-details" : "x-office-spreadsheet" }
                        Text { Layout.fillWidth: true; text: diffSelectionRow.schemaRow ? diffSelectionRow.modelData.name : diffSelectionRow.modelData.object.name; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: diffSelectionRow.schemaRow; elide: Text.ElideRight }
                        Text { text: diffSelectionRow.schemaRow ? String(diffSelectionRow.modelData.count) : diffSelectionRow.modelData.object.type; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                      }
                      HoverHandler { id: diffRowHover }
                    }
                  }
                }
              }
            }

            Item {
              ColumnLayout {
                anchors.fill: parent
                spacing: 10
                RowLayout {
                  Layout.fillWidth: true
                  Text {
                    Layout.fillWidth: true
                    text: root.diffResult ? root.diffIncludedCount() + " of " + root.diffResult.changes.length + " changes selected · " + root.diffResult.unchanged + " unchanged" : ""
                    color: root.ink
                    font.family: root.uiFont
                    font.pixelSize: Math.max(14, Style.font.body)
                    font.bold: true
                  }
                  StudioButton { label: root.diffResult ? root.diffResult.targetOnly.length + " only in target" : ""; compact: true; visible: !!root.diffResult && root.diffResult.targetOnly.length > 0; onClicked: diffTargetOnlyDialog.open() }
                }
                RowLayout {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  spacing: 12
                  Rectangle {
                    Layout.preferredWidth: 365
                    Layout.fillHeight: true
                    color: root.surface
                    border.width: 1
                    border.color: root.line
                    radius: 6
                    ListView {
                      anchors.fill: parent
                      anchors.margins: 5
                      clip: true
                      spacing: 2
                      model: root.diffResultRows()
                      boundsBehavior: Flickable.StopAtBounds
                      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                      delegate: Rectangle {
                        id: diffResultRow
                        required property var modelData
                        readonly property bool objectRow: modelData.kind === "object"
                        width: ListView.view.width
                        height: modelData.kind === "section" ? 45 : modelData.kind === "group" ? 38 : 45
                        color: modelData.kind === "section" ? root.raised : objectRow && root.diffFocusedKey === modelData.key ? root.selected : diffResultHover.hovered && objectRow ? root.raised : "transparent"
                        border.width: objectRow && root.diffFocusedKey === modelData.key ? 1 : 0
                        border.color: root.accent
                        radius: 5
                        RowLayout {
                          anchors.fill: parent
                          anchors.leftMargin: diffResultRow.modelData.kind === "section" ? 10 : 18
                          anchors.rightMargin: 9
                          spacing: 8
                          StudioCheck {
                            visible: diffResultRow.modelData.kind !== "section"
                            text: ""
                            checked: diffResultRow.modelData.kind === "group" ? root.diffIncludedCount(diffResultRow.modelData.groupKey) === diffResultRow.modelData.count : !!root.diffIncluded[diffResultRow.modelData.key]
                            onToggled: {
                              if (diffResultRow.modelData.kind === "group") root.toggleDiffGroup(diffResultRow.modelData.groupKey, checked)
                              else root.toggleDiffIncluded(diffResultRow.modelData.key, checked)
                            }
                          }
                          ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                              Layout.fillWidth: true
                              text: diffResultRow.modelData.kind === "object" ? diffResultRow.modelData.change.schema + "." + diffResultRow.modelData.change.name : diffResultRow.modelData.label
                              textFormat: Text.PlainText
                              color: root.ink
                              font.family: diffResultRow.objectRow ? root.codeFont : root.uiFont
                              font.pixelSize: diffResultRow.modelData.kind === "section" ? Math.max(15, Style.font.body) : Math.max(13, Style.font.bodySmall)
                              font.bold: !diffResultRow.objectRow
                              elide: Text.ElideRight
                            }
                            Text {
                              visible: diffResultRow.objectRow
                              Layout.fillWidth: true
                              text: diffResultRow.objectRow ? (diffResultRow.modelData.change.notes || []).join(" ") || (diffResultRow.modelData.change.status === "create" ? "Create" : diffResultRow.modelData.change.status === "manual" ? "Manual review" : "Modify") : ""
                              textFormat: Text.PlainText
                              color: root.softInk
                              font.family: root.uiFont
                              font.pixelSize: Math.max(11, Style.font.caption)
                              elide: Text.ElideRight
                            }
                          }
                          Text {
                            text: diffResultRow.modelData.kind === "group" ? root.diffIncludedCount(diffResultRow.modelData.groupKey) + "/" + diffResultRow.modelData.count : diffResultRow.modelData.kind === "section" ? String(diffResultRow.modelData.count) : diffResultRow.modelData.change.status === "manual" ? "review" : diffResultRow.modelData.change.status
                            color: diffResultRow.objectRow && diffResultRow.modelData.change.status === "manual" ? Theme.Color.urgent : root.accent
                            font.family: root.uiFont
                            font.pixelSize: Math.max(11, Style.font.caption)
                          }
                        }
                        MouseArea {
                          visible: diffResultRow.objectRow
                          anchors.top: parent.top
                          anchors.bottom: parent.bottom
                          anchors.left: parent.left
                          anchors.leftMargin: 47
                          anchors.right: parent.right
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.focusDiffChange(diffResultRow.modelData.key)
                        }
                        HoverHandler { id: diffResultHover }
                      }
                    }
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: root.raised
                    border.width: 1
                    border.color: root.line
                    radius: 6
                    ColumnLayout {
                      anchors.fill: parent
                      anchors.margins: 12
                      spacing: 8
                      Text { Layout.fillWidth: true; text: root.diffPreview ? root.diffPreview.schema + "." + root.diffPreview.name : root.diffPreviewBusy ? "Loading change…" : "Select an object to inspect"; textFormat: Text.PlainText; color: root.ink; font.family: root.codeFont; font.pixelSize: Math.max(15, Style.font.body); font.bold: true; elide: Text.ElideRight }
                      Text { Layout.fillWidth: true; visible: !!root.diffPreview; text: root.diffPreview ? (root.diffPreview.status === "manual" ? "Different in target · manual review" : (root.diffPreview.status === "create" ? "Missing in target · CREATE " : "Different in target · ALTER ") + root.diffPreview.type.toUpperCase() + (root.diffPreview.complete ? "" : " · manual review needed")) : ""; color: root.diffPreview && !root.diffPreview.complete ? Theme.Color.urgent : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.bodySmall); wrapMode: Text.WordWrap }
                      Text { Layout.fillWidth: true; visible: !!root.diffPreview && root.diffPreview.notes.length > 0; text: root.diffPreview ? root.diffPreview.notes.join(" ") : ""; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.bodySmall); wrapMode: Text.WordWrap }
                      RowLayout {
                        Layout.fillWidth: true
                        visible: !!root.diffPreview
                        StudioButton { label: "Difference"; compact: true; prominent: root.diffDetailTab === "difference"; onClicked: root.diffDetailTab = "difference" }
                        StudioButton { label: "SQL script"; compact: true; prominent: root.diffDetailTab === "sql"; onClicked: root.diffDetailTab = "sql" }
                        Item { Layout.fillWidth: true }
                      }
                      RowLayout {
                        Layout.fillWidth: true
                        visible: !!root.diffPreview && root.diffPreview.type === "view" && root.diffDetailTab === "difference"
                        Text { Layout.fillWidth: true; text: "View definition"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true }
                        StudioButton { label: "Changes"; compact: true; prominent: root.diffViewSide === "changes"; onClicked: root.diffViewSide = "changes" }
                        StudioButton { visible: !!root.diffPreview && root.diffPreview.type === "view"; label: "Source"; compact: true; prominent: root.diffViewSide === "source"; onClicked: root.diffViewSide = "source" }
                        StudioButton { visible: !!root.diffPreview && root.diffPreview.type === "view"; label: "Target"; compact: true; prominent: root.diffViewSide === "target"; onClicked: root.diffViewSide = "target" }
                      }
                      ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: !!root.diffPreview
                        clip: true
                        TextArea {
                          text: !root.diffPreview ? "" : root.diffDetailTab === "sql" ? root.diffPreview.sql : root.diffPreview.type === "view" ? (root.diffViewSide === "changes" ? root.diffPreview.viewDifference : root.diffViewSide === "source" ? root.diffPreview.sourceDefinition : root.diffPreview.targetDefinition || "(missing in target)") : root.diffPreview.columns.length ? root.diffPreview.columns.map(function(item) { return (item.action === "add" ? "+ " : item.action === "target-only" ? "= " : "~ ") + item.name + "\n  Target: " + (item.before || "(missing)") + "\n  Source: " + (item.after || "(absent; left unchanged)") }).join("\n\n") : "No column changes."
                          textFormat: TextEdit.PlainText
                          readOnly: true
                          selectByMouse: true
                          wrapMode: TextEdit.NoWrap
                          color: root.ink
                          font.family: root.codeFont
                          font.pixelSize: Math.max(12, Style.font.bodySmall)
                          background: Rectangle { color: root.bg; border.width: 1; border.color: root.line; radius: 5 }
                        }
                      }
                    }
                  }
                }
                Text { Layout.fillWidth: true; visible: !!root.diffResult && root.diffResult.changes.length === 0; text: "No differences in the selected objects."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) }
              }
            }

            Item {
              ColumnLayout {
                anchors.fill: parent
                spacing: 10
                Text { Layout.fillWidth: true; text: root.diffScriptComplete ? "Script ready · no manual changes flagged" : "Script incomplete · " + root.diffManual.length + " changes need manual review"; color: root.diffScriptComplete ? root.ink : Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: true }
                ScrollView {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  clip: true
                  TextArea {
                    text: root.diffScript
                    textFormat: TextEdit.PlainText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.NoWrap
                    color: root.ink
                    selectionColor: root.accent
                    selectedTextColor: root.bg
                    font.family: root.codeFont
                    font.pixelSize: Math.max(13, Style.font.bodySmall)
                    background: Rectangle { color: root.surface; border.width: 1; border.color: root.line; radius: 6 }
                  }
                }
              }
            }
          }
          Text { Layout.fillWidth: true; visible: root.diffBusy || root.diffError !== ""; text: root.diffBusy ? "Reading schema metadata…" : root.diffError; textFormat: Text.PlainText; color: root.diffError ? Theme.Color.urgent : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
        }
      }
      footer: Rectangle {
        implicitHeight: 62
        color: root.raised
        radius: 10
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: root.line }
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 20
          spacing: 9
          StudioButton { label: "Back"; compact: true; visible: root.diffPhase === "results" || root.diffPhase === "script"; onClicked: root.diffPhase = root.diffPhase === "script" ? "results" : "select" }
          Item { Layout.fillWidth: true }
          StudioButton { label: "Load objects"; compact: true; prominent: true; visible: root.diffPhase === "setup"; buttonEnabled: !root.diffBusy && root.diffSourceProfileId !== "" && root.diffTargetProfileId !== "" && root.diffSourceProfileId !== root.diffTargetProfileId; onClicked: root.loadDiffCatalog() }
          StudioButton { label: "Compare selected"; compact: true; prominent: true; visible: root.diffPhase === "select"; buttonEnabled: !root.diffBusy && root.diffSelectedSchemas.length > 0; onClicked: root.compareDiff() }
          StudioButton { label: "Generate script"; compact: true; prominent: true; visible: root.diffPhase === "results"; buttonEnabled: !root.diffBusy && root.diffIncludedCount() > 0; onClicked: root.generateDiffScript() }
          StudioButton { label: "Copy script"; compact: true; visible: root.diffPhase === "script"; buttonEnabled: root.diffScript !== ""; onClicked: root.copyPlainText(root.diffScript) }
          StudioButton { label: "Save .sql"; compact: true; prominent: true; visible: root.diffPhase === "script"; buttonEnabled: root.diffScript !== ""; onClicked: diffSaveDialog.open() }
        }
      }
    }

    Dialog {
      id: cellViewerDialog
      parent: window.contentItem
      modal: true
      title: "Cell value"
      anchors.centerIn: parent
      width: Math.min(root.viewerWidth, window.width - 48)
      height: Math.min(root.viewerHeight, window.height - 48)
      padding: 0
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.line; radius: 9 }
      header: Rectangle {
        implicitHeight: 68
        color: root.raised
        radius: 9
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 18
          spacing: 12
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Text {
              Layout.fillWidth: true
              text: root.viewedCell ? root.viewedCell.columnName : "Cell value"
              textFormat: Text.PlainText
              color: root.ink
              font.family: root.uiFont
              font.pixelSize: Math.max(18, Style.font.heading)
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              text: root.viewedCell ? "Row " + root.viewedCell.displayRow + " · read only" : "Read only"
              color: root.softInk
              font.family: root.uiFont
              font.pixelSize: Math.max(12, Style.font.caption)
            }
          }
          StudioButton { label: "Close"; compact: true; onClicked: root.closeCellViewer() }
        }
      }
      contentItem: Item {
        ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: 49
          spacing: 0
          StudioTab { label: "Text"; selectedTab: root.viewerMode === "text"; onClicked: root.setViewerMode("text") }
          StudioTab { label: "JSON"; selectedTab: root.viewerMode === "json"; onClicked: root.setViewerMode("json") }
          StudioTab { label: "HTML source"; selectedTab: root.viewerMode === "html"; onClicked: root.setViewerMode("html") }
          Item { Layout.fillWidth: true }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: 55
          Layout.leftMargin: 16
          Layout.rightMargin: 16
          spacing: 10
          StudioField {
            id: viewerSearch
            Layout.fillWidth: true
            placeholderText: "Find in value…"
            onAccepted: root.findInViewer()
          }
          StudioButton { label: "Find next"; compact: true; onClicked: root.findInViewer() }
          StudioCheck { id: viewerWrap; text: "Wrap"; checked: true }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
        Text {
          Layout.fillWidth: true
          Layout.leftMargin: 18
          Layout.rightMargin: 18
          Layout.topMargin: 8
          Layout.bottomMargin: 7
          text: root.viewerLoading ? "Loading full value…"
            : root.viewerError ? root.viewerError
            : root.viewerComplete ? ((root.viewedCell && root.viewedCell.byteLength !== null ? root.viewedCell.byteLength + " bytes · " : "") + "Full value")
            : "Preview only · full value unavailable"
          textFormat: Text.PlainText
          color: root.viewerError ? Theme.Color.urgent : root.softInk
          font.family: root.uiFont
          font.pixelSize: Math.max(12, Style.font.caption)
          elide: Text.ElideRight
        }
        ScrollView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.leftMargin: 14
          Layout.rightMargin: 14
          Layout.bottomMargin: 8
          clip: true
          TextArea {
            id: viewerTextArea
            text: root.viewerMode === "json" ? root.viewerJsonText : root.viewerText
            textFormat: TextEdit.PlainText
            readOnly: true
            selectByMouse: true
            wrapMode: viewerWrap.checked && root.viewerMode !== "html" ? TextEdit.WrapAnywhere : TextEdit.NoWrap
            color: root.ink
            selectionColor: root.accent
            selectedTextColor: root.bg
            font.family: root.codeFont
            font.pixelSize: Math.max(14, Style.font.body)
            background: Rectangle { color: root.surface; border.width: 1; border.color: root.line; radius: 5 }
          }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: 52
          Layout.leftMargin: 16
          Layout.rightMargin: 16
          spacing: 10
          Text {
            Layout.fillWidth: true
            text: root.viewerMode === "html" ? "HTML is shown as source." : ""
            color: root.softInk
            font.family: root.uiFont
            font.pixelSize: Math.max(12, Style.font.caption)
          }
          StudioButton { label: "Copy original value"; compact: true; buttonEnabled: root.viewerComplete; onClicked: root.copyPlainText(root.viewerText) }
          StudioButton { label: "Close"; compact: true; onClicked: root.closeCellViewer() }
        }
      }
      Item {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: 24
        height: 24
        z: 3
        Text { anchors.centerIn: parent; text: "◢"; color: root.softInk; font.pixelSize: 16 }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.SizeFDiagCursor
          property real startX: 0
          property real startY: 0
          property real startWidth: 0
          property real startHeight: 0
          onPressed: function(mouse) {
            var point = mapToItem(window.contentItem, mouse.x, mouse.y)
            startX = point.x
            startY = point.y
            startWidth = cellViewerDialog.width
            startHeight = cellViewerDialog.height
          }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var point = mapToItem(window.contentItem, mouse.x, mouse.y)
            root.viewerWidth = Math.max(500, Math.min(window.width - 48, startWidth + point.x - startX))
            root.viewerHeight = Math.max(340, Math.min(window.height - 48, startHeight + point.y - startY))
          }
        }
      }
      }
      onClosed: {
        root.viewerGeneration++
        root.viewedCell = null
        root.viewedSnapshot = null
        root.viewerText = ""
        root.viewerJsonText = ""
        root.viewerComplete = false
        root.viewerLoading = false
        viewerSearch.text = ""
      }
    }

    Dialog {
      id: connectionDialog
      objectName: "connectionDialog"
      readonly property bool isD1: enginePicker.currentIndex >= 0 && root.engineOptions[enginePicker.currentIndex].value === "cloudflare_d1"
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
                ? connectionDialog.isD1 ? "Connection details saved in system keyring. Leave the fields blank to keep them, or enter new details to replace them." : "Connection string saved in system keyring. Leave the string and fields blank to keep it, or enter new details to replace it."
                : "Connection details available for this session. Leave the string and fields blank to keep them, or enter new details to replace them."
              textFormat: Text.PlainText
              color: root.ink
              font.family: root.uiFont
              font.pixelSize: Math.max(13, Style.font.bodySmall)
              wrapMode: Text.WordWrap
            }
          }
          Text { text: "Name"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
          StudioField { id: connectionName; objectName: "connectionName"; Layout.fillWidth: true; placeholderText: "Production reporting" }
          Text { text: "Database type"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
          ComboBox {
            id: enginePicker
            objectName: "enginePicker"
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
          Text { visible: !connectionDialog.isD1; text: root.editingProfileId ? "New connection string (optional)" : "Paste connection string (optional)"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); Layout.topMargin: 5 }
          StudioField { id: connectionStringInput; visible: !connectionDialog.isD1; Layout.fillWidth: true; placeholderText: root.editingProfileId ? "Blank keeps the existing connection" : "Paste a URL or driver connection string"; echoMode: TextInput.Password }
          Text { Layout.fillWidth: true; visible: !connectionDialog.isD1; text: "The full string is passed to the local worker, then cleared from this form. If remembered, it is stored in the system keyring."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          Text { visible: !connectionDialog.isD1; text: "OR ENTER FIELDS"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1; Layout.topMargin: 8 }
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            ColumnLayout { Layout.fillWidth: true; Text { text: connectionDialog.isD1 ? "Cloudflare Account ID" : "Host"; color: root.softInk; font.pixelSize: Math.max(13, Style.font.bodySmall) } StudioField { id: hostInput; objectName: "hostInput"; Layout.fillWidth: true; placeholderText: connectionDialog.isD1 ? "32-character account identifier" : "server.example.com" } }
            ColumnLayout { visible: !connectionDialog.isD1; Layout.preferredWidth: 100; Text { text: "Port"; color: root.softInk; font.pixelSize: Math.max(13, Style.font.bodySmall) } StudioField { id: portInput; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly } }
          }
          Text { text: connectionDialog.isD1 ? "D1 Database ID" : "Database"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
          StudioField { id: databaseInput; objectName: "databaseInput"; Layout.fillWidth: true; placeholderText: connectionDialog.isD1 ? "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" : "Database name" }
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            ColumnLayout { visible: !connectionDialog.isD1; Layout.fillWidth: true; Text { text: "User"; color: root.softInk; font.pixelSize: Math.max(13, Style.font.bodySmall) } StudioField { id: userInput; Layout.fillWidth: true; placeholderText: "User name" } }
            ColumnLayout {
              Layout.fillWidth: true
              Text {
                text: connectionDialog.isD1 ? "Cloudflare API token" : enginePicker.currentIndex >= 0 && root.engineOptions[enginePicker.currentIndex].value === "mysql" ? "Password (optional)" : "Password"
                color: root.softInk
                font.pixelSize: Math.max(13, Style.font.bodySmall)
              }
              StudioField {
                id: passwordInput
                objectName: "passwordInput"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: connectionDialog.isD1 ? "API token with D1 permission" : enginePicker.currentIndex >= 0 && root.engineOptions[enginePicker.currentIndex].value === "mysql" ? "Leave blank if none" : "Password"
              }
            }
          }
          Text { Layout.fillWidth: true; visible: connectionDialog.isD1; text: "Find the IDs on your database's Cloudflare D1 page. Use an account-scoped API token with D1 Read to browse, or D1 Write for SQL changes. Add one connection per database. Connections always use verified HTTPS."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          StudioCheck { id: sslCheck; text: "Use verified TLS"; checked: true; visible: !connectionDialog.isD1 && connectionStringInput.text.trim() === ""; enabled: root.engineOptions[enginePicker.currentIndex].value !== "azure_sql" }
          Text { Layout.fillWidth: true; visible: root.engineOptions[enginePicker.currentIndex].value === "azure_sql" && connectionStringInput.text.trim() === ""; text: "Azure SQL always uses verified TLS."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          Text {
            Layout.fillWidth: true
            visible: !connectionDialog.isD1 && connectionStringInput.text.trim() !== ""
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
          Text { Layout.fillWidth: true; visible: !connectionDialog.isD1 && connectionStringInput.text.trim() === "" && !sslCheck.checked; text: "TLS is off. Credentials and data may travel in plaintext."; textFormat: Text.PlainText; color: Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          StudioCheck { id: rememberCheck; text: "Remember connection in system keyring"; checked: true }
          Text { Layout.fillWidth: true; text: "Without Remember, this connection works for this session and disappears when DB Studio closes."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
          StudioCheck { id: agentAccessCheck; text: "Allow AI agents to use this connection"; checked: false; enabled: rememberCheck.checked }
          Text {
            Layout.fillWidth: true
            text: agentAccessCheck.checked && rememberCheck.checked
              ? "DB Studio MCP and CLI agents can inspect this database and run SQL with this account's permissions, including changes. Results may go to your AI provider. DB Studio tool responses do not include credentials. An agent with shell access under your user account may still access local files or the keyring. Disabling this stops new DB Studio agent requests; queries already running may finish."
              : "Only remembered connections can be enabled for AI agents."
            textFormat: Text.PlainText
            color: agentAccessCheck.checked && rememberCheck.checked ? Theme.Color.urgent : root.softInk
            font.family: root.uiFont
            font.pixelSize: Math.max(12, Style.font.caption)
            wrapMode: Text.WordWrap
          }
          Text { id: formError; Layout.fillWidth: true; color: Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
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
                    Text { text: root.engineName(profileRow.modelData.type) + (profileRow.modelData.agentAccess ? " · AI access on" : ""); color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
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
        StudioCheck { id: reopenCheck; text: "Reopen last connection automatically"; checked: root.reopenLastConnection; enabled: root.settingsLoaded; onToggled: root.setReopenLastConnection(checked) }
        Text { Layout.fillWidth: true; text: "When DB Studio opens, reconnect to the last remembered profile if it is available. Session-only connections cannot be reopened."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
        RowLayout { Layout.fillWidth: true; Text { text: "Query timeout (seconds)"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) } Item { Layout.fillWidth: true } SpinBox { from: 5; to: 120; value: root.timeoutMs / 1000; onValueModified: root.timeoutMs = value * 1000 } }
        Text { Layout.fillWidth: true; text: "Data browsing is view only in v1. Row editing will be added later."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
        RowLayout { Layout.fillWidth: true; Item { Layout.fillWidth: true } StudioButton { label: "Done"; prominent: true; onClicked: settingsDialog.close() } }
      }
    }
  }
}
