pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Theme
import "editor/sql-language.js" as SqlLanguage

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
  property var completionDefinitions: ({})
  property int completionGeneration: 0
  readonly property var completionCatalog: Object.keys(objectsBySchema).reduce(function(all, schema) { return all.concat(objectsBySchema[schema]) }, [])
  property var expandedSchemas: Object.create(null)
  property string objectSearch: ""
  property string objectTypeFilter: "all"
  property var selectedObject: null
  property var inspectorDefinition: null
  property int inspectorLoadGeneration: 0
  property var scriptObject: null
  property bool scriptBusy: false
  property int scriptGeneration: 0

  property var tabs: [{ id: "query-1", kind: "query", title: "Query 1", sql: "", columns: [], rows: [], cellRefs: [], durationMs: 0, rowCount: 0, hasMore: false, busy: false, error: "", message: "", pendingId: 0 }]
  property string activeTabId: "query-1"
  property int nextTabId: 2
  readonly property var activeTab: tabs.find(function(tab) { return tab.id === activeTabId }) || null
  property string resultPane: "results"
  onResultPaneChanged: {
    var tab = tabs.find(function(entry) { return entry.id === activeTabId })
    if (tab && tab.kind === "query" && tab.resultPane !== resultPane) updateTab(tab.id, { resultPane: resultPane })
    Qt.callLater(ensureActiveResultVisible)
  }
  readonly property bool queryHasOutput: !!activeTab && activeTab.kind === "query" && (!!activeTab.hasCompletedQuery || (activeTab.columns || []).length > 0)
  readonly property bool queryEditorCollapsed: !!activeTab && activeTab.kind === "query" && (activeTab.editorCollapsed !== undefined ? !!activeTab.editorCollapsed : queryHasOutput && !activeTab.error && querySplit.height < 360)
  property var editingCell: null
  property var editFields: []
  property int editRevision: 0
  readonly property int editedCellCount: { var revision = editRevision; return changedRowFields().length }
  property bool editSaving: false
  property string editError: ""
  property bool editorFindVisible: false
  property string editorFindText: ""
  readonly property var editorFindMatches: editorMatches()
  property string savingSqlTabId: ""
  property string closeAfterSaveId: ""
  property string closingTabId: ""
  readonly property bool editorDialogVisible: editDialog.visible || tableFilterDialog.visible || tableExportDialog.visible || exportSaveDialog.visible || unsavedDialog.visible || sqlOpenDialog.visible || sqlSaveDialog.visible || aiDialog.visible || diffDialog.visible || cellViewerDialog.visible || connectionDialog.visible || connectionListDialog.visible || settingsDialog.visible || diffOptionsDialog.visible || diffTargetOnlyDialog.visible
  property string filterTabId: ""
  property string filterError: ""
  property var exportContext: null
  property var exportSelectedColumns: []
  property string exportFormat: "csv"
  property string exportError: ""
  property bool exportBusy: false
  property bool exportCancelling: false
  property int exportPendingId: 0
  property int exportGeneration: 0
  property var exportOptions: null
  property bool sidebarVisible: window.width >= 1000
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
  property string diffResultFilter: ""
  property string diffResultType: "all"
  property string diffResultStatus: "all"
  property var diffScriptOptions: ({ includeIndexes: true, includeChecks: true, includeForeignKeys: true, refreshDependentViews: true })
  property var diffRefreshedViews: []
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
    diffResultFilter = ""
    diffResultType = "all"
    diffResultStatus = "all"
    diffRefreshedViews = []
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
      var matches = children.filter(function(object) { return (object.schema + "." + object.name).toLocaleLowerCase().includes(needle) })
      if (needle && !matches.length && !schema.name.toLocaleLowerCase().includes(needle)) return
      rows.push({ kind: "schema", name: schema.name, count: children.length })
      if (diffExpandedSchemas[schema.name] || needle) {
        ;(needle ? matches : children).forEach(function(object) { rows.push({ kind: "object", object: object }) })
      }
    })
    return rows
  }
  function diffObjectKey(object) { return JSON.stringify([object.schema, object.name]) }
  function diffMatchingObjects() {
    if (!diffCatalog) return []
    var needle = diffFilter.toLocaleLowerCase().trim()
    return diffCatalog.source.objects.filter(function(object) { return (object.schema + "." + object.name).toLocaleLowerCase().includes(needle) })
  }
  function diffCheckState(objects, included) {
    var count = objects.filter(function(object) { return !!included[diffObjectKey(object)] }).length
    return count === 0 ? Qt.Unchecked : count === objects.length ? Qt.Checked : Qt.PartiallyChecked
  }
  function diffSelectionObjects(type) {
    return diffCatalog ? diffCatalog.source.objects.filter(function(object) { return !type || object.type === type }) : []
  }
  function diffRowObjects(row) {
    return row.kind === "schema" ? diffMatchingObjects().filter(function(object) { return object.schema === row.name }) : [row.object]
  }
  function setDiffObjects(objects, checked) {
    if (diffBusy || !diffCatalog) return
    var selected = Object.assign({}, diffSelectedObjects)
    objects.forEach(function(object) { selected[diffObjectKey(object)] = checked })
    diffSelectedObjects = selected
    diffSelectedSchemas = diffCatalog.source.schemas.filter(function(schema) {
      return diffCatalog.source.objects.some(function(object) { return object.schema === schema.name && !!selected[diffObjectKey(object)] })
    }).map(function(schema) { return schema.name })
    diffResult = null
    diffScript = ""
    diffError = ""
    diffPreviewGeneration++
    diffPhase = "select"
  }
  function toggleDiffRow(row, checked) { setDiffObjects(diffRowObjects(row), checked) }
  function selectAllDiff(checked) { setDiffObjects(diffSelectionObjects(), checked) }
  function expandDiffSchemas(expanded) {
    var schemas = ({})
    if (diffCatalog) diffCatalog.source.schemas.forEach(function(schema) { schemas[schema.name] = expanded })
    diffExpandedSchemas = schemas
  }
  function diffSelectedCount() {
    if (!diffCatalog) return 0
    return (diffCatalog.source.objects || []).filter(function(object) { return !!diffSelectedObjects[diffObjectKey(object)] }).length
  }
  function compareDiff() {
    if (!diffCatalog || diffSelectedCount() === 0 || diffBusy) return
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
      diffResultFilter = ""
      diffResultType = "all"
      diffResultStatus = "all"
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
  function diffVisibleChanges() {
    if (!diffResult) return []
    var needle = diffResultFilter.trim().toLocaleLowerCase()
    return diffResult.changes.filter(function(change) {
      return (change.schema + "." + change.name).toLocaleLowerCase().includes(needle)
        && (diffResultType === "all" || change.type === diffResultType)
        && (diffResultStatus === "all" || (diffResultStatus === "missing" && !change.targetExists)
          || (diffResultStatus === "different" && change.targetExists) || (diffResultStatus === "manual" && (change.reviewRequired || change.status === "manual")))
    })
  }
  function diffTypeChanges(type) { return diffResult ? diffResult.changes.filter(function(change) { return change.type === type }) : [] }
  function setDiffIncluded(changes, checked) {
    if (diffBusy) return
    var included = Object.assign({}, diffIncluded)
    changes.forEach(function(change) { included[diffObjectKey(change)] = checked })
    diffIncluded = included
    diffScript = ""
    diffError = ""
  }
  function setDiffOption(key, enabled) {
    diffScriptOptions = Object.assign({}, diffScriptOptions, { [key]: enabled })
    diffScript = ""
    if (diffFocusedKey) { var keyToReload = diffFocusedKey; diffFocusedKey = ""; focusDiffChange(keyToReload) }
  }
  function diffResultRows() {
    if (!diffResult) return []
    var rows = []
    var changes = diffVisibleChanges()
    ;[{ status: "missing", title: "Missing in target" }, { status: "different", title: "Different in target" }].forEach(function(section) {
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
    return diffVisibleChanges().filter(function(change) {
      return change.type === parts[1] && (parts[0] === "missing" ? !change.targetExists : change.targetExists)
    })
  }
  function diffIncludedCount(groupKey) {
    var changes = groupKey ? diffGroupChanges(groupKey) : diffResult ? diffResult.changes || [] : []
    return changes.filter(function(change) { return !!diffIncluded[diffObjectKey(change)] }).length
  }
  function toggleDiffIncluded(key, checked) {
    setDiffIncluded((diffResult.changes || []).filter(function(change) { return diffObjectKey(change) === key }), checked)
  }
  function toggleDiffGroup(groupKey, checked) { setDiffIncluded(diffGroupChanges(groupKey), checked) }
  function focusDiffChange(key) {
    if (!diffResult || key === diffFocusedKey) return
    diffFocusedKey = key
    diffPreview = null
    diffError = ""
    diffViewSide = "changes"
    diffDetailTab = "difference"
    diffPreviewBusy = true
    var generation = ++diffPreviewGeneration
    request("schemaDiff.preview", { comparisonId: diffResult.comparisonId, objectKey: key, scriptOptions: diffScriptOptions }, function(data, error) {
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
    request("schemaDiff.script", { comparisonId: diffResult.comparisonId, selectedKeys: selectedKeys, scriptOptions: diffScriptOptions }, function(data, error) {
      if (generation !== diffGeneration || !diffDialog.visible) return
      diffBusy = false
      if (error) { diffError = error; return }
      diffScript = String(data.sql || "")
      diffScriptComplete = data.complete === true
      diffManual = data.manual || []
      diffRefreshedViews = data.refreshedViews || []
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
    var viewport = sqlScroll.contentItem as Flickable
    var position = viewport ? viewport["contentY"] : 0
    return typeof position === "number" ? position : 0
  }
  function open(payloadJson) {
    closingFromHost = false
    if (window.visible) {
      // A mapped window may be behind another app or on another workspace.
      var target = "title:^DB Studio$"
      Hyprland.dispatch(Hyprland.usingLua
        ? "hl.dsp.focus({ window = " + JSON.stringify(target) + " })"
        : "focuswindow " + target)
      return
    }
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
      if (entry.action !== "query.run" && entry.action !== "table.rows" && entry.action !== "table.describe" && entry.action !== "cell.get" && !/cancel/i.test(error)) showNotice(error, true)
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
    scriptGeneration++
    scriptBusy = false
    scriptObject = null
    tableScriptMenu.close()
    exportGeneration++
    if (exportPendingId && workerReady && !stoppingWorker) request("query.cancel", { targetId: exportPendingId }, function() {})
    exportPendingId = 0
    exportBusy = false
    exportCancelling = false
    exportSaveDialog.close()
    tableExportDialog.close()
    exportContext = null
    exportOptions = null
    closeCellViewer()
    editDialog.close()
    editingCell = null
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
    resetCompletionMetadata()
    expandedSchemas = Object.create(null)
    objectSearch = ""
    selectedObject = null
    inspectorDefinition = null
    tabs = tabs.filter(function(tab) { return tab.kind === "query" }).map(function(tab) {
      return Object.assign({}, tab, { columns: [], rows: [], cellRefs: [], resultSets: [], activeResultIndex: 0, resultPane: "results", rowCount: 0, hasMore: false, hasCompletedQuery: false, durationMs: 0, busy: false, error: "", message: "", pendingId: 0 })
    })
    if (tabs.length === 0) {
      var id = "query-" + nextTabId++
      tabs = [{ id: id, kind: "query", title: "Query " + (nextTabId - 1), sql: "", columns: [], rows: [], cellRefs: [], rowCount: 0, hasMore: false, durationMs: 0, busy: false, error: "", message: "", pendingId: 0 }]
    }
    if (!tabs.some(function(tab) { return tab.id === activeTabId })) activeTabId = tabs[0].id
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
  function resetCompletionMetadata() {
    completionGeneration++
    completionDefinitions = ({})
    sqlEditor.dismissCompletion()
  }
  function loadCompletionMetadata(objects) {
    if (!connectionId) return
    var currentConnectionId = connectionId, generation = completionGeneration
    objects.slice(0,4).forEach(function(object) {
      var key = SqlLanguage.objectKey(object)
      if (completionDefinitions[key]) return
      var next = Object.assign({},completionDefinitions)
      next[key] = {loading:true,columns:[]}
      completionDefinitions = next
      request("table.describe", {connectionId:currentConnectionId,schema:object.schema,name:object.name}, function(data,error) {
        if (generation !== completionGeneration || currentConnectionId !== connectionId) return
        var updated = Object.assign({},completionDefinitions)
        updated[key] = error ? {error:true,columns:[]} : {columns:data.columns || []}
        completionDefinitions = updated
      })
    })
  }
  function loadSchema() {
    if (!connectionId) return
    resetCompletionMetadata()
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
  onActiveTabIdChanged: {
    closeCellViewer()
    var tab = tabs.find(function(entry) { return entry.id === activeTabId })
    resultPane = tab && tab.resultPane ? tab.resultPane : "results"
    Qt.callLater(syncEditor); Qt.callLater(ensureActiveTabVisible); Qt.callLater(ensureActiveResultVisible)
  }
  onTabsChanged: {
    if (cellViewerDialog.visible && !cellSnapshotCurrent(viewedSnapshot)) closeCellViewer()
  }
  function newQuery(sql, title) {
    var id = "query-" + nextTabId++
    tabs = tabs.concat([{ id: id, kind: "query", title: title || ("Query " + (nextTabId - 1)), sql: sql || "", columns: [], rows: [], cellRefs: [], durationMs: 0, rowCount: 0, hasMore: false, busy: false, error: "", message: "", pendingId: 0 }])
    activeTabId = id
    resultPane = "results"
    return id
  }
  function closeTab(id, discard) {
    var tab = tabs.find(function(entry) { return entry.id === id })
    if (!tab) return
    if (tab.fileSaving) { showNotice("Wait for the SQL file to finish saving.", true); return }
    if (!discard && queryIsDirty(tab)) { closingTabId = id; unsavedDialog.open(); return }
    if (tab && tab.pendingId) request("query.cancel", { targetId: tab.pendingId }, function() {})
    if (tab && tab.pendingRowsId) request("query.cancel", { targetId: tab.pendingRowsId }, function() {})
    var currentIndex = tabs.findIndex(function(entry) { return entry.id === id })
    tabs = tabs.filter(function(entry) { return entry.id !== id })
    if (tabs.length === 0) { newQuery(); return }
    if (activeTabId === id) activeTabId = tabs[Math.max(0, currentIndex - 1)].id
  }
  function ensureActiveTabVisible() {
    var index = tabs.findIndex(function(tab) { return tab.id === activeTabId })
    var item = workTabRepeater.itemAt(index)
    if (!item) return
    if (item.x < workTabs.contentX) workTabs.contentX = item.x
    else if (item.x + item.width > workTabs.contentX + workTabs.width) workTabs.contentX = Math.max(0, item.x + item.width - workTabs.width)
  }
  function queryIsDirty(tab) { return !!tab && tab.kind === "query" && String(tab.sql || "") !== String(tab.savedSql || "") }
  function openSqlFile(filePath) {
    var existing = tabs.find(function(tab) { return tab.kind === "query" && tab.filePath === filePath })
    if (existing) { activeTabId = existing.id; return }
    request("sql.open", { filePath: filePath }, function(data, error) {
      if (error) return
      var id = newQuery(data.sql, filePath.split("/").pop())
      updateTab(id, { filePath: data.filePath, fileRevision: data.revision, savedSql: data.sql })
      Qt.callLater(function() { root.syncEditor(); sqlEditor.forceActiveFocus() })
    })
  }
  function saveQuery(tabId, saveAs) {
    var tab = tabs.find(function(t) { return t.id === tabId })
    if (!tab || tab.kind !== "query" || tab.fileSaving) return
    if (saveAs || !tab.filePath) {
      savingSqlTabId = tab.id
      sqlSaveDialog.selectedFile = tab.filePath ? Qt.resolvedUrl("file://" + tab.filePath.split("/").map(encodeURIComponent).join("/")) : ""
      sqlSaveDialog.open()
      return
    }
    writeSqlFile(tab.id, tab.filePath, false)
  }
  function writeSqlFile(tabId, filePath, overwrite) {
    var tab = tabs.find(function(t) { return t.id === tabId })
    if (!tab || tab.kind !== "query" || tab.fileSaving) return
    var savedText = String(tab.sql || "")
    var payload = { filePath: filePath, sql: savedText, overwrite: overwrite }
    if (filePath === tab.filePath && tab.fileRevision) payload.revision = tab.fileRevision
    updateTab(tabId, { fileSaving: true })
    request("sql.save", payload, function(data, error) {
      var current = tabs.find(function(t) { return t.id === tabId })
      if (current) updateTab(tabId, error ? { fileSaving: false } : { fileSaving: false, filePath: data.filePath, fileRevision: data.revision, savedSql: savedText, title: filePath.split("/").pop() })
      if (!error) showNotice("SQL file saved", false)
      if (closeAfterSaveId === tabId) {
        closeAfterSaveId = ""
        current = tabs.find(function(t) { return t.id === tabId })
        if (!error && current && !queryIsDirty(current)) closeTab(tabId, true)
      }
    })
  }
  function setQueryEditorCollapsed(collapsed) {
    if (!activeTab || activeTab.kind !== "query") return
    updateTab(activeTab.id, { editorCollapsed: !!collapsed })
    if (collapsed) editorFindVisible = false
    else Qt.callLater(function() { sqlEditor.forceActiveFocus() })
  }
  function showEditorFind() {
    if (!activeTab || activeTab.kind !== "query") return
    setQueryEditorCollapsed(false)
    editorFindVisible = true
    if (sqlEditor.selectedText && sqlEditor.selectedText.length <= 2000) editorFindText = sqlEditor.selectedText
    sqlFindField.forceActiveFocus()
    sqlFindField.selectAll()
  }
  function editorMatches() {
    if (!activeTab || activeTab.kind !== "query" || !editorFindText) return []
    var text = String(activeTab.sql || "")
    var pattern = new RegExp(editorFindText.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi")
    var matches = []
    var match
    while ((match = pattern.exec(text)) !== null) matches.push(match.index)
    return matches
  }
  function findInEditor(backwards) {
    var matches = editorFindMatches
    if (!matches.length) return
    var position = backwards ? sqlEditor.selectionStart : sqlEditor.selectionEnd
    var match = backwards ? matches.slice().reverse().find(function(m) { return m < position }) : matches.find(function(m) { return m >= position })
    if (match === undefined) match = backwards ? matches[matches.length - 1] : matches[0]
    sqlEditor.select(match, match + editorFindText.length)
    // Keep the match visible while leaving the search field ready to type.
    var rect = sqlEditor.positionToRectangle(match)
    var viewport = sqlScroll.contentItem as Flickable
    if (viewport) {
      viewport.contentY = Math.max(0, Math.min(Math.max(0, viewport.contentHeight - viewport.height), rect.y - viewport.height / 2))
      viewport.contentX = Math.max(0, Math.min(Math.max(0, viewport.contentWidth - viewport.width), rect.x - viewport.width / 2))
    }
  }
  function runQuery() {
    sqlEditor.dismissCompletion()
    var tab = activeTab
    if (!tab || tab.kind !== "query" || tab.busy) return
    if (!connectionId) { showNotice("Connect to a database first", true); return }
    var sql = String((sqlEditor.text === tab.sql ? sqlEditor.selectedText : "") || tab.sql || "").trim()
    if (!sql) { showNotice("Write a query before running it", true); return }
    var tabId = tab.id
    var queryConnectionId = connectionId
    showNotice("", false)
    closeCellViewer()
    updateTab(tabId, { busy: true, error: "", message: "Running query…", columns: [], rows: [], cellRefs: [], resultSets: [], activeResultIndex: 0, rowCount: 0, hasMore: false, hasCompletedQuery: false, resultPane: "results" })
    resultPane = "results"
    var requestId = request("query.run", { connectionId: queryConnectionId, sql: sql, limit: rowLimit, timeoutMs: timeoutMs }, function(data, error) {
      if (queryConnectionId !== connectionId) return
      var currentTab = tabs.find(function(entry) { return entry.id === tabId })
      if (!currentTab || currentTab.pendingId !== requestId) return
      if (error) {
        var cancelled = /cancel/i.test(error)
        updateTab(tabId, { busy: false, pendingId: 0, resultPane: "messages", error: cancelled ? "" : error, message: cancelled ? (activeProfile && activeProfile.type === "cloudflare_d1" ? "Stopped waiting. Cloudflare may still finish the query." : "Query cancelled") : error })
        if (activeTabId === tabId) resultPane = "messages"
        return
      }
      var sets = data.resultSets || ((data.columns || []).length ? [data] : [])
      var first = sets[0] || data
      var pane = sets.length ? "results" : "messages"
      var messages = [data.message || "Query completed"]
      sets.forEach(function(set, index) { messages.push((sets.length > 1 ? "Result " + (index + 1) : "Results") + " · " + (set.rows || []).length + " rows returned" + (set.hasMore ? " (display limit reached)" : "")) })
      if (!sets.length && !data.message) messages.push((data.rowCount || 0) + " rows affected")
      updateTab(tabId, { busy: false, pendingId: 0, hasCompletedQuery: true, resultSets: sets, activeResultIndex: 0, resultPane: pane, columns: first.columns || [], rows: first.rows || [], cellRefs: first.cellRefs || [], rowCount: first.rowCount || 0, hasMore: !!first.hasMore, durationMs: data.durationMs || 0, message: messages.join("\n") })
      if (activeTabId === tabId) resultPane = pane
      Qt.callLater(ensureActiveResultVisible)
    })
    updateTab(tabId, { pendingId: requestId })
  }
  function selectQueryResult(index) {
    if (!activeTab || activeTab.kind !== "query" || activeTab.busy) return
    var set = (activeTab.resultSets || [])[index]
    if (!set) { resultPane = "results"; return }
    closeCellViewer()
    updateTab(activeTab.id, { activeResultIndex: index, columns: set.columns || [], rows: set.rows || [], cellRefs: set.cellRefs || [], rowCount: set.rowCount || 0, hasMore: !!set.hasMore })
    resultPane = "results"
    Qt.callLater(ensureActiveResultVisible)
  }
  function ensureActiveResultVisible() {
    var item = resultPane === "messages" ? queryMessagesTab : queryResultTabs.itemAt(activeTab ? activeTab.activeResultIndex || 0 : 0)
    if (!item) return
    if (item.x < queryResultTabScroll.contentX) queryResultTabScroll.contentX = item.x
    else if (item.x + item.width > queryResultTabScroll.contentX + queryResultTabScroll.width) queryResultTabScroll.contentX = Math.max(0, item.x + item.width - queryResultTabScroll.width)
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
  function openTableScriptMenu(object, anchor, x, y) {
    if (!object || object.type !== "table" || !connectionId || scriptBusy) return
    scriptObject = object
    var point = anchor.mapToItem(window.contentItem, x === undefined ? 0 : x, y === undefined ? anchor.height : y)
    tableScriptMenu.x = point.x
    tableScriptMenu.y = point.y
    tableScriptMenu.open()
  }
  function generateTableScript(action) {
    if (!scriptObject || scriptBusy || !connectionId) return
    var object = scriptObject
    var currentConnectionId = connectionId
    var generation = ++scriptGeneration
    scriptBusy = true
    request("table.script", {connectionId: currentConnectionId, schema: object.schema, name: object.name, script: action}, function(data, error) {
      if (generation !== scriptGeneration || currentConnectionId !== connectionId) return
      scriptBusy = false
      if (error) { showNotice(error, true); return }
      var id = newQuery(data.sql, object.name + " · " + action.toUpperCase())
      updateTab(id, {editorCollapsed: false})
      Qt.callLater(function() { syncEditor(); sqlEditor.forceActiveFocus() })
    })
  }
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
    var requestId = request("table.rows", { connectionId: currentConnectionId, schema: tab.object.schema, name: tab.object.name, limit: rowLimit, offset: offset, sort: tab.sort || null, filter: tab.filter || null }, function(data, error) {
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
      updateTab(tabId, { busy: false, pendingRowsId: 0, columns: data.columns || [], rows: data.rows || [], cellRefs: data.cellRefs || [], editHandles: data.editHandles || [], stableOrder: !!data.stableOrder, order: data.order || [], hasMore: !!data.hasMore, offset: pageOffset, pageOffsets: pageOffsets })
    })
    updateTab(tabId, { pendingRowsId: requestId })
  }
  function tableColumnCapabilities(column, dialect) {
    var type = column.type || ""
    var scalar = /^(character varying|character|varchar|nvarchar|char|nchar|text|ntext|tinytext|mediumtext|longtext|citext|uuid|uniqueidentifier|tinyint|smallint|mediumint|int|integer|bigint|int2|int4|int8|decimal|numeric|money|smallmoney|real|float|double precision|double|boolean|bool|bit|date|datetime|datetime2|smalldatetime|datetimeoffset|timestamp|timestamptz|time|timetz)(\b|\()/i.test(type) && !/\[\]|^bit\(/i.test(type)
    var typeName = dialect || (activeProfile ? activeProfile.type : "")
    var sqlserver = typeName === "sqlserver" || typeName === "azure_sql"
    return { sortable: scalar && !(sqlserver && /^(text|ntext)$/i.test(type)), filterable: scalar, text: /^(character|varchar|nvarchar|char|nchar|text|ntext|tinytext|mediumtext|longtext|citext)(\b|\()/i.test(type) }
  }
  function tableSortableColumns() {
    if (!activeTab || activeTab.kind !== "table" || !activeTab.definition) return []
    return activeTab.definition.columns.filter(function(c) { return tableColumnCapabilities(c).sortable }).map(function(c) { return c.name })
  }
  function changeTableOptions(tabId, changes) {
    var tab = tabs.find(function(t) { return t.id === tabId })
    if (!tab || tab.busy || !connectionId) return
    updateTab(tabId, Object.assign({ rows: [], cellRefs: [], editHandles: [], offset: 0, pageOffsets: [0] }, changes))
    loadTableRows(tabId, 0)
  }
  function sortTable(column) {
    var tab = activeTab
    if (!tab || tableSortableColumns().indexOf(column) < 0) return
    var direction = tab.sort && tab.sort.column === column ? tab.sort.direction === "asc" ? "desc" : "" : "asc"
    changeTableOptions(tab.id, { sort: direction ? { column: column, direction: direction } : null })
  }
  function filterColumns() {
    var tab = tabs.find(function(t) { return t.id === filterTabId })
    return tab && tab.definition ? tab.definition.columns.filter(function(c) { return tableColumnCapabilities(c).filterable }) : []
  }
  function filterOperators() {
    var column = filterColumns()[filterColumn.currentIndex]
    return columnFilterOperators(column)
  }
  function columnFilterOperators(column) {
    var ops = [{ label: "Equals", value: "equals" }, { label: "Does not equal", value: "notEqual" }, { label: "Greater than", value: "greaterThan" }, { label: "Less than", value: "lessThan" }]
    if (column && tableColumnCapabilities(column).text) ops = [{ label: "Contains", value: "contains" }, { label: "Starts with", value: "startsWith" }].concat(ops)
    return ops.concat([{ label: "Is NULL", value: "isNull" }, { label: "Is not NULL", value: "notNull" }])
  }
  function exportColumns() { return exportContext ? exportContext.definition.columns || [] : [] }
  function exportColumnAllowed(column) {
    return exportFormat !== "sql" || (!column.generated && !/\b(VIRTUAL|STORED) GENERATED\b/i.test(column.extra || "") &&
      !(exportContext && /^(sqlserver|azure_sql)$/.test(exportContext.type) && /^(timestamp|rowversion)$/i.test(column.type)))
  }
  function exportFilterColumns() {
    return exportColumns().filter(function(column) { return tableColumnCapabilities(column, exportContext ? exportContext.type : "").filterable })
  }
  function exportFilterOperators() { return columnFilterOperators(exportFilterColumns()[exportFilterColumn.currentIndex]) }
  function selectExportColumns(all) { exportSelectedColumns = all ? exportColumns().filter(exportColumnAllowed).map(function(column) { return column.name }) : [] }
  function toggleExportColumn(name, checked) {
    exportSelectedColumns = checked ? exportSelectedColumns.concat([name]) : exportSelectedColumns.filter(function(column) { return column !== name })
  }
  function changeExportFormat() {
    exportFormat = exportFormatChoice.currentIndex === 1 ? "sql" : "csv"
    exportSelectedColumns = exportSelectedColumns.filter(function(name) { return exportColumns().some(function(column) { return column.name === name && exportColumnAllowed(column) }) })
  }
  function openTableExport() {
    var tab = activeTab
    if (!tab || tab.kind !== "table" || !tab.definition || !connectionId || exportBusy) return
    exportContext = { connectionId: connectionId, schema: tab.object.schema, name: tab.object.name, definition: tab.definition,
      type: activeProfile ? activeProfile.type : "", sort: tab.sort || null }
    exportError = ""
    exportFormatChoice.currentIndex = 0
    exportFormat = "csv"
    selectExportColumns(true)
    var current = tab.filter
    exportFilterEnabled.checked = !!current
    exportFilterColumn.currentIndex = current ? Math.max(0, exportFilterColumns().findIndex(function(column) { return column.name === current.column })) : 0
    exportFilterOperator.currentIndex = current ? Math.max(0, exportFilterOperators().findIndex(function(op) { return op.value === current.operator })) : 0
    exportFilterValue.text = current && current.value !== undefined ? String(current.value) : ""
    exportOptions = null
    exportScroll.contentItem.contentY = 0
    tableExportDialog.open()
  }
  function chooseExportFile() {
    if (!exportContext || exportBusy || !exportSelectedColumns.length) return
    exportError = ""
    var filter = null
    if (exportFilterEnabled.checked) {
      var column = exportFilterColumns()[exportFilterColumn.currentIndex]
      var op = exportFilterOperators()[exportFilterOperator.currentIndex]
      if (!column || !op) { exportError = "Select a filter column and condition."; return }
      var value = exportFilterValue.text
      if (!/^(isNull|notNull)$/.test(op.value) && /^(boolean|bool|bit)$/i.test(column.type)) {
        if (!/^(true|false|0|1)$/i.test(value)) { exportError = "Enter true, false, 0, or 1."; return }
        value = /^(true|1)$/i.test(value)
      }
      filter = { column: column.name, operator: op.value, value: value }
    }
    exportOptions = { connectionId: exportContext.connectionId, schema: exportContext.schema, name: exportContext.name,
      format: exportFormat, columns: exportColumns().filter(function(column) { return exportSelectedColumns.indexOf(column.name) >= 0 && exportColumnAllowed(column) }).map(function(column) { return column.name }),
      filter: filter, sort: exportContext.sort, timeoutMs: timeoutMs }
    exportSaveDialog.selectedFile = ""
    exportSaveDialog.open()
  }
  function startTableExport(filePath) {
    if (!exportOptions || exportBusy || exportOptions.connectionId !== connectionId) return
    var generation = ++exportGeneration
    exportBusy = true
    exportCancelling = false
    exportError = ""
    exportPendingId = request("table.export", Object.assign({}, exportOptions, { filePath: filePath, overwrite: true }), function(data, error) {
      if (generation !== exportGeneration) return
      exportBusy = false
      exportPendingId = 0
      exportCancelling = false
      if (error) { exportError = /cancel/i.test(error) ? "Export cancelled. Your destination file was left unchanged." : error; return }
      tableExportDialog.close()
      showNotice("Exported " + data.rowCount + " rows to " + data.filePath, false)
    })
  }
  function cancelTableExport() {
    if (!exportBusy) { tableExportDialog.close(); return }
    if (!exportPendingId || exportCancelling) return
    exportCancelling = true
    request("query.cancel", { targetId: exportPendingId }, function() {})
  }
  function openTableFilter() {
    if (!activeTab || activeTab.kind !== "table" || activeTab.busy) return
    filterTabId = activeTab.id
    filterError = ""
    var current = activeTab.filter
    filterColumn.currentIndex = current ? Math.max(0, filterColumns().findIndex(function(c) { return c.name === current.column })) : 0
    filterOperator.currentIndex = current ? Math.max(0, filterOperators().findIndex(function(op) { return op.value === current.operator })) : 0
    filterValue.text = current && current.value !== undefined ? String(current.value) : ""
    tableFilterDialog.open()
    filterValue.forceActiveFocus()
  }
  function applyTableFilter(clear) {
    var columns = filterColumns()
    var tab = tabs.find(function(t) { return t.id === filterTabId })
    if (!tab || tab.busy || (!clear && !columns.length)) return
    var filter = null
    if (!clear) {
      var column = columns[filterColumn.currentIndex]
      var op = filterOperators()[filterOperator.currentIndex]
      if (!column || !op) return
      var value = filterValue.text
      if (!/^(isNull|notNull)$/.test(op.value) && /^(boolean|bool|bit)$/i.test(column.type)) {
        if (!/^(true|false|0|1)$/i.test(value)) { filterError = "Enter true, false, 0, or 1."; return }
        value = /^(true|1)$/i.test(value)
      }
      filter = { column: column.name, operator: op.value, value: value }
    }
    changeTableOptions(tab.id, { filter: filter })
    tableFilterDialog.close()
  }
  function tableEditableColumns() {
    if (activeProfile && activeProfile.type === "cloudflare_d1") return []
    var tab = activeTab
    if (!tab || tab.kind !== "table" || !tab.object || tab.object.type !== "table" || !tab.definition || tab.busy) return []
    var columns = tab.definition.columns || []
    if (!columns.some(function(c) { return c.primaryKey })) return []
    return columns.filter(function(c) {
      return !c.primaryKey && !c.generated && !c.identity && !/generated|auto_increment/i.test(c.extra || "") &&
        /^(character varying|character|varchar|nvarchar|char|nchar|text|tinytext|mediumtext|longtext|citext|uuid|uniqueidentifier|tinyint|smallint|mediumint|int|integer|bigint|int2|int4|int8|decimal|numeric|money|smallmoney|real|float|double precision|double|boolean|bool|bit)(\b|\()/i.test(c.type || "") && !/^bit\(/i.test(c.type || "")
    }).map(function(c) { return c.name })
  }
  function tableEditHint() {
    if (!activeTab || !activeTab.object) return ""
    if (activeProfile && activeProfile.type === "cloudflare_d1") return "Cloudflare D1 · use SQL to edit · click a column to sort"
    if (activeTab.object.type === "view") return "View · read-only · click a column to sort"
    if (!activeTab.definition) return "Loading column details…"
    if (!activeTab.definition.columns.some(function(c) { return c.primaryKey })) return "Read-only · no primary key · page order may change"
    return (activeTab.filter ? "Filtered rows · " : "") + "F2 to edit row · click a column to sort"
  }
  function openCellEditor(cell) {
    var tab = activeTab
    var allowed = tableEditableColumns()
    if (!cell || !tab || !tab.rows[cell.row] || !allowed.length) return
    if (!tab.editHandles || !tab.editHandles[cell.row]) { showNotice("Refresh the table to edit this row.", true); return }
    var fields = []
    tab.columns.forEach(function(column, index) {
      var name = typeof column === "string" ? column : column.name
      if (allowed.indexOf(name) < 0) return
      var definition = tab.definition.columns.find(function(c) { return c.name === name })
      var value = tab.rows[cell.row][index]
      var shortened = (tab.cellRefs || []).some(function(ref) { return ref.row === cell.row && ref.column === index }) ||
        (typeof value === "string" && value.length === 4097 && value.endsWith("…"))
      fields.push({ column: name, type: definition.type, nullable: !!definition.nullable, original: value, readOnly: shortened })
    })
    var identity = tab.definition.columns.filter(function(c) { return c.primaryKey }).map(function(c) {
      var index = tab.columns.findIndex(function(column) { return (typeof column === "string" ? column : column.name) === c.name })
      return c.name + " = " + String(tab.rows[cell.row][index])
    }).join(" · ")
    editingCell = { tabId: tab.id, connectionId: connectionId, handle: tab.editHandles[cell.row], column: cell.columnName, offset: tab.offset || 0,
      title: tab.object.schema + "." + tab.object.name, identity: identity }
    editFields = fields
    editError = ""
    editDialog.open()
    Qt.callLater(function() {
      var index = fields.findIndex(function(field) { return field.column === cell.columnName })
      if (index < 0 || fields[index].readOnly) index = fields.findIndex(function(field) { return !field.readOnly })
      var field = rowEditFields.itemAt(index)
      if (field) {
        field.input.forceActiveFocus()
        rowEditScroll.contentItem.contentY = Math.max(0, Math.min(field.y, rowEditScroll.contentItem.contentHeight - rowEditScroll.height))
      }
    })
  }
  function changedRowFields() {
    var fields = []
    for (var i = 0; i < rowEditFields.count; i++) {
      var field = rowEditFields.itemAt(i)
      if (field && field.changed) fields.push(field)
    }
    return fields
  }
  function saveCellEdit() {
    if (!editingCell || editSaving || editingCell.connectionId !== connectionId) return
    var edit = editingCell
    var changes = []
    var fields = changedRowFields()
    for (var i = 0; i < fields.length; i++) {
      var field = fields[i]
      var value = field.nullInput.checked ? null : field.input.text
      if (value !== null && /^(boolean|bool|bit)$/i.test(field.modelData.type)) {
        if (!/^(true|false|0|1)$/i.test(value)) { editError = field.modelData.column + ": Enter true, false, 0, or 1."; field.input.forceActiveFocus(); return }
        value = /^(true|1)$/i.test(value)
      }
      if (value !== null && value.length > 65536) { editError = field.modelData.column + ": Values are limited to 65,536 characters."; return }
      changes.push({ column: field.modelData.column, value: value })
    }
    if (!changes.length) return
    editSaving = true
    editError = ""
    request("table.updateRow", { connectionId: edit.connectionId, handle: edit.handle, changes: changes }, function(_, error) {
      editSaving = false
      if (error) { editError = error + " Close this dialog and refresh the table before trying again."; editingCell = null; return }
      editDialog.close()
      editingCell = null
      if (edit.connectionId === connectionId) root.loadTableRows(edit.tabId, edit.offset)
      showNotice("Row saved", false)
    })
  }
  function copyGridRows(rowIndex) {
    var tab = activeTab
    if (!tab || tab.busy || !tab.rows.length) return
    var refs = tab.cellRefs || []
    if (refs.some(function(ref) { return rowIndex < 0 || ref.row === rowIndex })) { showNotice("Some values are shortened. Copy individual values from the value viewer.", true); return }
    function tsv(value) {
      var text = value === null || value === undefined ? "NULL" : typeof value === "object" ? JSON.stringify(value) : String(value)
      return /[\t\n\r"]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text
    }
    var lines = rowIndex < 0 ? [tab.columns.map(function(c) { return tsv(typeof c === "string" ? c : c.name) }).join("\t")] : []
    var rows = rowIndex < 0 ? tab.rows : [tab.rows[rowIndex]]
    rows.forEach(function(row) { lines.push(row.map(tsv).join("\t")) })
    copyPlainText(lines.join("\n"))
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
        case "filter":
          ctx.moveTo(2, 3); ctx.lineTo(18, 3); ctx.lineTo(12, 10)
          ctx.lineTo(12, 16); ctx.lineTo(8, 18); ctx.lineTo(8, 10); ctx.closePath()
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
    enabled: buttonEnabled
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
  component StudioChoice: ComboBox {
    id: choice
    implicitHeight: 38
    font.family: root.uiFont
    font.pixelSize: Math.max(13, Style.font.bodySmall)
    contentItem: Text { text: choice.displayText; color: root.ink; font: choice.font; verticalAlignment: Text.AlignVCenter; leftPadding: 10; rightPadding: 24; elide: Text.ElideRight }
    indicator: Text { x: choice.width - width - 9; anchors.verticalCenter: parent.verticalCenter; text: "⌄"; color: root.softInk }
    background: Rectangle { color: root.surface; radius: 5; border.width: choice.activeFocus ? 2 : 1; border.color: choice.activeFocus ? root.accent : root.line }
    delegate: ItemDelegate {
      id: option
      required property var modelData
      required property int index
      width: choice.width
      height: 36
      contentItem: Text { text: option.modelData; color: root.ink; font: choice.font; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
      background: Rectangle { color: choice.highlightedIndex === option.index ? root.selected : root.bg }
    }
    popup: Popup {
      y: choice.height
      width: choice.width
      padding: 4
      implicitHeight: Math.min(contentItem.implicitHeight + 8, 260)
      contentItem: ListView { clip: true; implicitHeight: contentHeight; model: choice.popup.visible ? choice.delegateModel : null; currentIndex: choice.highlightedIndex; ScrollBar.vertical: ScrollBar {} }
      background: Rectangle { color: root.bg; radius: 5; border.width: 1; border.color: root.accent }
    }
  }
  component StudioCheck: CheckBox {
    id: check
    nextCheckState: function() { return checkState === Qt.Checked ? Qt.Unchecked : Qt.Checked }
    font.family: root.uiFont
    font.pixelSize: Math.max(14, Style.font.body)
    spacing: 9
    indicator: Rectangle {
      implicitWidth: 19
      implicitHeight: 19
      x: check.leftPadding
      y: (check.height - height) / 2
      radius: 4
      color: check.checkState !== Qt.Unchecked ? root.accent : root.surface
      border.width: check.activeFocus ? 2 : 1
      border.color: check.activeFocus || check.checkState !== Qt.Unchecked ? root.accent : root.line
      Text {
        anchors.centerIn: parent
        text: check.checkState === Qt.PartiallyChecked ? "−" : "✓"
        visible: check.checkState !== Qt.Unchecked
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

  component ObjectTypeAction: MenuItem {
    id: typeAction
    required property string objectType
    implicitHeight: 36
    checkable: true
    autoExclusive: true
    checked: root.objectTypeFilter === objectType
    contentItem: Text { text: typeAction.text; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); verticalAlignment: Text.AlignVCenter; leftPadding: 30 }
    indicator: Text { x: 10; anchors.verticalCenter: parent.verticalCenter; text: "✓"; visible: typeAction.checked; color: root.accent; font.pixelSize: 14 }
    background: Rectangle { color: typeAction.highlighted ? root.raised : "transparent"; radius: 3 }
    onTriggered: root.objectTypeFilter = objectType
  }

  component TableScriptAction: MenuItem {
    id: scriptAction
    required property string scriptKind
    objectName: "generateTableScript_" + scriptKind
    implicitHeight: 38
    enabled: !!root.connectionId && !root.scriptBusy
    contentItem: Text { text: scriptAction.scriptKind.toUpperCase(); color: scriptAction.enabled ? root.ink : root.faintInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); verticalAlignment: Text.AlignVCenter; leftPadding: 12 }
    background: Rectangle { color: scriptAction.highlighted ? root.raised : root.surface }
    onTriggered: root.generateTableScript(scriptKind)
  }

  FloatingWindow {
    id: window
    objectName: "dbStudioWindow"
    title: "DB Studio"
    color: root.bg
    implicitWidth: 1420
    implicitHeight: 920
    minimumSize: Qt.size(760, 480)
    visible: false
    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("andean-bridge.db-browser")
      else if (!visible && !root.closingFromHost) root.close()
    }

    Menu {
      id: objectTypeMenu
      objectName: "objectTypeMenu"
      parent: window.contentItem
      width: 160
      padding: 4
      onAboutToShow: currentIndex = ["all", "table", "view"].indexOf(root.objectTypeFilter)
      background: Rectangle { color: root.surface; border.width: 1; border.color: root.line; radius: 5 }
      ObjectTypeAction { text: "All"; objectType: "all" }
      ObjectTypeAction { text: "Tables"; objectType: "table" }
      ObjectTypeAction { text: "Views"; objectType: "view" }
    }

    Menu {
      id: tableScriptMenu
      objectName: "tableScriptMenu"
      parent: window.contentItem
      width: 220
      background: Rectangle { color: root.surface; border.width: 1; border.color: root.line; radius: 5 }
      MenuItem {
        enabled: false
        height: 34
        contentItem: Text { text: "Generate script"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); verticalAlignment: Text.AlignVCenter; leftPadding: 12 }
      }
      TableScriptAction { scriptKind: "create" }
      TableScriptAction { scriptKind: "alter" }
      TableScriptAction { scriptKind: "insert" }
      TableScriptAction { scriptKind: "update" }
    }

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.editorDialogVisible) return
        if (root.editorFindVisible) { root.editorFindVisible = false; sqlEditor.forceActiveFocus(); return }
        if (root.queryEditorCollapsed) root.setQueryEditorCollapsed(false)
        else root.requestClose()
      }
      Shortcut { sequence: "Ctrl+W"; enabled: !root.editorDialogVisible; onActivated: { if (root.activeTab) root.closeTab(root.activeTab.id) } }
      Shortcut { sequence: "Ctrl+B"; enabled: !root.editorDialogVisible; onActivated: root.sidebarVisible = !root.sidebarVisible }
      Shortcut { sequence: "F5"; enabled: !root.editorDialogVisible; onActivated: { if (root.activeTab && root.activeTab.kind === "table") root.loadTableRows(root.activeTab.id, root.activeTab.offset || 0); else root.runQuery() } }
      Shortcut { sequence: "Ctrl+N"; enabled: !root.editorDialogVisible; onActivated: root.newQuery() }
      Shortcut { sequence: "Ctrl+Return"; enabled: !root.editorDialogVisible; onActivated: root.runQuery() }
      Shortcut { sequence: "Ctrl+Enter"; enabled: !root.editorDialogVisible; onActivated: root.runQuery() }
      Shortcut { sequence: "Ctrl+O"; enabled: !root.editorDialogVisible; onActivated: sqlOpenDialog.open() }
      Shortcut { sequence: "Ctrl+S"; enabled: !root.editorDialogVisible && !!root.activeTab && root.activeTab.kind === "query"; onActivated: root.saveQuery(root.activeTab.id, false) }
      Shortcut { sequence: "Ctrl+Shift+S"; enabled: !root.editorDialogVisible && !!root.activeTab && root.activeTab.kind === "query"; onActivated: root.saveQuery(root.activeTab.id, true) }
      Shortcut { sequence: "Ctrl+F"; enabled: !root.editorDialogVisible; onActivated: { if (root.databasePickerExpanded) databaseSearchField.forceActiveFocus(); else if (root.activeTab && root.activeTab.kind === "query") root.showEditorFind(); else root.openTableFilter() } }
      Shortcut { sequence: "Ctrl+Shift+E"; enabled: !root.editorDialogVisible && !!root.activeTab && root.activeTab.kind === "query"; onActivated: root.setQueryEditorCollapsed(!root.queryEditorCollapsed) }
      Shortcut { sequence: "Ctrl+Shift+F"; enabled: !root.editorDialogVisible; onActivated: { root.sidebarVisible = true; searchField.forceActiveFocus() } }
      Shortcut { sequence: "F3"; enabled: root.editorFindVisible && !root.editorDialogVisible; onActivated: root.findInEditor(false) }
      Shortcut { sequence: "Shift+F3"; enabled: root.editorFindVisible && !root.editorDialogVisible; onActivated: root.findInEditor(true) }

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
            spacing: window.width < 1000 ? 8 : 22
            StudioIcon { Layout.preferredWidth: 27; Layout.preferredHeight: 27; iconName: "server-database" }
            Text { text: "DB Studio"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(22, Style.font.heading + 6); font.bold: true }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 28; color: root.line }
            StudioButton { label: root.sidebarVisible ? "Hide browser" : "Show browser"; compact: true; helpText: "Toggle schema browser (Ctrl+B)"; onClicked: root.sidebarVisible = !root.sidebarVisible }
            ToolButton {
              id: connectionMenuButton
              objectName: "connectionMenuButton"
              readonly property bool connected: root.connectionId !== "" && !!root.activeProfile
              text: connected ? root.activeProfile.name : root.connecting ? "Connecting…" : "Connections"
              Layout.preferredWidth: Math.max(120, connectionMenuName.implicitWidth + 72)
              Layout.maximumWidth: window.width < 1000 ? 180 : 240
              Layout.minimumWidth: 100
              Layout.preferredHeight: 46
              Accessible.name: connected ? "Connections: " + text : text
              ToolTip {
                id: connectionMenuTip
                visible: connectionMenuButton.hovered
                text: connectionMenuButton.connected ? root.activeProfile.name + " · " + root.engineName(root.activeProfile.type)
                  + (root.activeProfile.transportSecure === true ? " · Verified TLS" : root.activeProfile.transportSecure === false ? " · No TLS" : "")
                  + "\nManage connections" : "Choose or add a connection"
                contentItem: Text { text: connectionMenuTip.text; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                background: Rectangle { color: root.raised; border.color: root.line; border.width: 1; radius: 5 }
              }
              contentItem: RowLayout {
                spacing: 9
                Rectangle { objectName: "connectionStatusDot"; Layout.preferredWidth: 10; Layout.preferredHeight: 10; radius: 5; color: connectionMenuButton.connected ? "#58c89a" : root.connecting ? root.accent : root.faintInk }
                Text { id: connectionMenuName; objectName: "connectionMenuName"; Layout.fillWidth: true; text: connectionMenuButton.text; textFormat: Text.PlainText; color: connectionMenuButton.connected ? root.ink : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: connectionMenuButton.connected; elide: Text.ElideRight }
                Text { text: "⌄"; color: root.softInk; font.pixelSize: 16 }
              }
              background: Rectangle { color: connectionMenuButton.hovered ? root.raised : "transparent"; radius: 5; border.width: connectionMenuButton.activeFocus ? 2 : 0; border.color: root.accent }
              onClicked: connectionListDialog.open()
            }
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
            visible: root.sidebarVisible
            Layout.preferredWidth: Math.max(240, Math.min(320, window.width * 0.23))
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
              Text { Layout.fillWidth: true; visible: root.connectionId !== "" && !!root.activeProfile && root.activeProfile.transportSecure === false && !root.activeProfile.localConnection; text: "Unencrypted remote connection. Credentials and data may travel in plaintext."; textFormat: Text.PlainText; color: Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap }
              Rectangle {
                objectName: "databaseSelector"
                Layout.fillWidth: true
                Layout.preferredHeight: 40
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
                  Text { Layout.fillWidth: true; text: root.activeProfile ? root.activeProfile.database || "Select database" : "Select database"; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: true; elide: Text.ElideRight }
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
                Text { text: "SCHEMAS"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1 }
                ToolButton {
                  id: objectTypeFilterButton
                  objectName: "objectTypeFilterButton"
                  Layout.preferredWidth: 30
                  Layout.preferredHeight: 28
                  text: "Filter object types"
                  Accessible.name: text
                  Accessible.description: "Showing " + (root.objectTypeFilter === "all" ? "all objects" : root.objectTypeFilter === "table" ? "tables" : "views")
                  ToolTip.visible: hovered
                  ToolTip.text: "Filter objects: " + (root.objectTypeFilter === "all" ? "All" : root.objectTypeFilter === "table" ? "Tables" : "Views")
                  contentItem: Item { StudioIcon { anchors.centerIn: parent; width: 17; height: 17; iconName: "filter" } }
                  background: Rectangle {
                    radius: 5
                    color: root.objectTypeFilter !== "all" ? root.selected : objectTypeFilterButton.hovered ? root.raised : "transparent"
                    border.width: objectTypeFilterButton.activeFocus || root.objectTypeFilter !== "all" ? 1 : 0
                    border.color: root.accent
                  }
                  onClicked: objectTypeMenu.popup(objectTypeFilterButton, 0, height)
                }
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
                  objectName: "schemaObjectList"
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
                    MouseArea {
                      objectName: browserRow.isSchema ? "" : "browserObject_" + browserRow.modelData.object.name
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      acceptedButtons: Qt.LeftButton | Qt.RightButton
                      onClicked: function(mouse) {
                        if (mouse.button === Qt.RightButton) {
                          if (!browserRow.isSchema) root.openTableScriptMenu(browserRow.modelData.object, this, mouse.x, mouse.y)
                        } else if (browserRow.isSchema) root.toggleSchema(browserRow.schemaName)
                        else root.openTable(browserRow.modelData.object)
                      }
                    }
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
                  anchors.margins: 4
                  spacing: 4
                Flickable {
                  id: workTabs
                  objectName: "workTabs"
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.minimumWidth: 100
                  clip: true
                  contentWidth: workTabRow.implicitWidth
                  contentHeight: height
                  flickableDirection: Flickable.HorizontalFlick
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                  RowLayout {
                    id: workTabRow
                    width: implicitWidth
                    height: workTabs.height
                    spacing: 4
                  Repeater {
                    id: workTabRepeater
                    model: root.tabs
                    delegate: Rectangle {
                      id: workTab
                      required property var modelData
                      onXChanged: if (root.activeTabId === modelData.id) Qt.callLater(root.ensureActiveTabVisible)
                      onWidthChanged: if (root.activeTabId === modelData.id) Qt.callLater(root.ensureActiveTabVisible)
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
                        Text { id: tabLabel; Layout.fillWidth: true; text: workTab.modelData.title + (root.queryIsDirty(workTab.modelData) ? " *" : ""); textFormat: Text.PlainText; color: root.activeTabId === workTab.modelData.id ? root.ink : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); elide: Text.ElideRight }
                        StudioIcon { Layout.preferredWidth: 13; Layout.preferredHeight: 13; iconName: "window-close"; opacity: 0.65; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.closeTab(workTab.modelData.id) } }
                      }
                    }
                  }
                  }
                }
                  StudioButton { label: "New query"; iconName: "list-add"; compact: true; onClicked: root.newQuery() }
                  StudioButton { label: "Open SQL"; compact: true; helpText: "Open SQL file (Ctrl+O)"; onClicked: sqlOpenDialog.open() }
                  StudioButton { label: "Save"; compact: true; helpText: "Save SQL (Ctrl+S); Save as (Ctrl+Shift+S)"; buttonEnabled: !!root.activeTab && root.activeTab.kind === "query" && !root.activeTab.fileSaving; onClicked: root.saveQuery(root.activeTab.id, false) }
                }
              }

              ColumnLayout {
                id: queryWorkspace
                objectName: "queryWorkspace"
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                visible: root.activeTab && root.activeTab.kind === "query"

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 44
                  color: root.surface
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 8
                    StudioButton {
                      objectName: "runQueryButton"
                      label: root.activeTab && root.activeTab.busy ? "Running…" : "Run query"
                      iconName: "media-playback-start"
                      compact: true
                      prominent: true
                      buttonEnabled: root.connectionId !== "" && !!root.activeTab && !root.activeTab.busy
                      helpText: "Run selected SQL or the whole query (Ctrl+Enter)"
                      onClicked: root.runQuery()
                    }
                    StudioButton { label: "✦ Ask AI"; compact: true; visible: root.aiAvailable; helpText: "Build or fix this query with AI"; Accessible.name: "Ask AI"; onClicked: root.openAiDialog() }
                    StudioButton { objectName: "cancelQueryButton"; label: "Cancel"; compact: true; visible: !!root.activeTab && root.activeTab.busy; onClicked: root.cancelQuery() }
                    Text {
                      Layout.fillWidth: true
                      Layout.minimumWidth: 0
                      text: root.queryEditorCollapsed ? String(root.activeTab ? root.activeTab.sql || "" : "").replace(/\s+/g, " ").trim() : "SQL · Ctrl+Space suggestions · Ctrl+Enter run"
                      textFormat: Text.PlainText
                      color: root.softInk
                      font.family: root.queryEditorCollapsed ? root.codeFont : root.uiFont
                      font.pixelSize: Math.max(12, Style.font.caption)
                      elide: Text.ElideRight
                    }
                    StudioButton {
                      objectName: "toggleSqlEditorButton"
                      label: root.queryEditorCollapsed ? "Show SQL" : "Hide SQL"
                      compact: true
                      helpText: "Show or hide the SQL editor (Ctrl+Shift+E)"
                      onClicked: root.setQueryEditorCollapsed(!root.queryEditorCollapsed)
                    }
                  }
                }
                SplitView {
                  id: querySplit
                  objectName: "querySplit"
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  orientation: Qt.Vertical
                  readonly property real reservedResultsHeight: Math.min(340, Math.max(0, height - (queryComposer.visible ? queryComposer.minimumEditorHeight + 8 : 0)))
                  handle: Rectangle {
                    objectName: "queryPaneDivider"
                    implicitHeight: 8
                    color: splitterHover.hovered ? root.raised : root.surface
                    Rectangle { width: 44; height: 2; radius: 1; anchors.centerIn: parent; color: splitterHover.hovered ? root.accent : root.faintInk }
                    HoverHandler { id: splitterHover; cursorShape: Qt.SizeVerCursor }
                  }
                  ColumnLayout {
                    id: queryComposer
                    objectName: "queryComposer"
                    readonly property real minimumEditorHeight: root.editorFindVisible ? 108 : 64
                    SplitView.minimumHeight: minimumEditorHeight
                    SplitView.maximumHeight: Math.max(minimumEditorHeight, querySplit.height - querySplit.reservedResultsHeight - 8)
                    SplitView.preferredHeight: Math.max(minimumEditorHeight, Math.min(200, querySplit.height * 0.3, sqlEditor.lineCount * editorGutter.lineHeight + 32 + (root.editorFindVisible ? 44 : 0)))
                    visible: !root.queryEditorCollapsed
                    spacing: 0
                RowLayout {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 44
                  Layout.leftMargin: 8
                  Layout.rightMargin: 8
                  visible: root.editorFindVisible
                  spacing: 6
                  StudioField { id: sqlFindField; objectName: "sqlFindField"; Layout.fillWidth: true; placeholderText: "Find in SQL…"; Accessible.name: "Find in SQL"; maximumLength: 2000; text: root.editorFindText; onTextChanged: root.editorFindText = text; onAccepted: root.findInEditor(false) }
                  Text { text: root.editorFindMatches.length + " matches"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                  StudioButton { label: "Previous"; compact: true; buttonEnabled: root.editorFindMatches.length > 0; onClicked: root.findInEditor(true) }
                  StudioButton { label: "Next"; compact: true; buttonEnabled: root.editorFindMatches.length > 0; onClicked: root.findInEditor(false) }
                  StudioButton { label: "Close"; compact: true; onClicked: { root.editorFindVisible = false; sqlEditor.forceActiveFocus() } }
                }
                Rectangle {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.minimumHeight: 60
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
                      readonly property int lineHeight: Math.max(1,sqlEditor.cursorRectangle.height)
                      readonly property int firstVisibleLine: Math.min(Math.max(0, sqlEditor.lineCount - 1), Math.max(0, Math.floor(root.editorScrollY() / lineHeight)))
                      Column {
                        y: 16 - (root.editorScrollY() - editorGutter.firstVisibleLine * editorGutter.lineHeight)
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
                      objectName: "sqlEditorScroll"
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      clip: true
                      SqlEditor {
                        id: sqlEditor
                        objectName: "sqlEditor"
                        dialect: root.activeProfile ? root.activeProfile.type : "sqlserver"
                        contextKey: root.connectionId + ":" + root.activeTabId
                        catalog: root.completionCatalog
                        definitions: root.completionDefinitions
                        completionsEnabled: !root.syncingEditor && !root.editorDialogVisible && !!root.activeTab && root.activeTab.kind === "query" && !root.queryEditorCollapsed
                        viewportX: { var viewport = sqlScroll.contentItem as Flickable; return viewport ? viewport.contentX : 0 }
                        viewportY: { var viewport = sqlScroll.contentItem as Flickable; return viewport ? viewport.contentY : 0 }
                        viewportWidth: sqlScroll.availableWidth
                        viewportHeight: sqlScroll.availableHeight
                        textInk: root.ink
                        onMetadataRequested: function(objects) { root.loadCompletionMetadata(objects) }
                        selectByMouse: true
                        persistentSelection: root.editorFindVisible
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
                        placeholderTextColor: root.faintInk
                        selectionColor: root.accent
                        selectedTextColor: root.bg
                        font.family: root.codeFont
                        font.pixelSize: Math.max(16, Style.font.body + 2)
                        padding: 16
                        textFormat: TextEdit.PlainText
                        wrapMode: TextEdit.NoWrap
                        background: Rectangle { color: root.bg }
                      }
                    }
                  }
                }
                  }
                  Rectangle {
                    id: queryResultsPanel
                    objectName: "queryResultsPanel"
                    SplitView.minimumHeight: querySplit.reservedResultsHeight
                    SplitView.fillHeight: true
                    color: root.surface
                    ColumnLayout {
                      anchors.fill: parent
                      spacing: 0
                      RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        spacing: 0
                        Flickable {
                          id: queryResultTabScroll
                          objectName: "queryResultTabScroll"
                          Layout.fillWidth: true
                          Layout.minimumWidth: 120
                          Layout.preferredHeight: 40
                          contentWidth: queryResultTabRow.implicitWidth
                          contentHeight: height
                          flickableDirection: Flickable.HorizontalFlick
                          boundsBehavior: Flickable.StopAtBounds
                          clip: true
                          onWidthChanged: Qt.callLater(root.ensureActiveResultVisible)
                          ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                          Row {
                            id: queryResultTabRow
                            height: 40
                            Repeater {
                              id: queryResultTabs
                              objectName: "queryResultTabs"
                              model: Math.max(1, root.activeTab ? (root.activeTab.resultSets || []).length : 0)
                              StudioTab {
                                required property int index
                                height: 40
                                label: queryResultTabs.count > 1 ? "Result " + (index + 1) : "Results"
                                iconName: "x-office-spreadsheet"
                                selectedTab: root.resultPane === "results" && (root.activeTab ? root.activeTab.activeResultIndex || 0 : 0) === index
                                onClicked: root.selectQueryResult(index)
                              }
                            }
                            StudioTab {
                              id: queryMessagesTab
                              height: 40
                              label: "Messages"
                              iconName: "text-x-generic"
                              selectedTab: root.resultPane === "messages"
                              onClicked: root.resultPane = "messages"
                            }
                          }
                        }
                        Text {
                          objectName: "queryResultSummary"
                          Layout.preferredWidth: Math.min(260, queryResultsPanel.width * 0.32)
                          Layout.minimumWidth: 0
                          Layout.leftMargin: 8
                          Layout.rightMargin: 8
                          horizontalAlignment: Text.AlignRight
                          elide: Text.ElideRight
                          text: root.activeTab ? root.activeTab.busy ? "Running…" : (root.activeTab.columns || []).length ? root.activeTab.rows.length + " rows · " + root.activeTab.durationMs + " ms" + (root.activeTab.hasMore ? " · limit reached" : "") : root.activeTab.hasCompletedQuery ? (root.activeTab.rowCount || 0) + " rows affected" : "" : ""
                          color: root.softInk
                          font.family: root.uiFont
                          font.pixelSize: Math.max(12, Style.font.caption)
                        }
                        StudioButton { label: queryResultsPanel.width < 700 ? "Copy" : "Copy results"; helpText: "Copy results with headers"; compact: true; buttonEnabled: !!root.activeTab && root.activeTab.rows.length > 0 && !root.activeTab.busy; onClicked: root.copyGridRows(-1); Layout.rightMargin: 8 }
                      }
                      Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
                      DbGrid {
                        id: queryGrid
                        layoutKey: root.activeTab ? root.activeTab.id + ":result-" + (root.activeTab.activeResultIndex || 0) : ""
                        objectName: "queryGrid"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.margins: 4
                        visible: root.resultPane === "results"
                        columns: root.activeTab ? root.activeTab.columns : []
                        rows: root.activeTab ? root.activeTab.rows : []
                        cellRefs: root.activeTab ? root.activeTab.cellRefs || [] : []
                        busy: root.activeTab ? root.activeTab.busy : false
                        error: root.activeTab ? root.activeTab.error : ""
                        hasMore: root.activeTab ? !!root.activeTab.hasMore : false
                        emptyText: "The query returned no rows"
                        onViewCell: function(cell) { root.openCellViewer(cell) }
                        onCopyCell: function(cell) { root.copyCellValue(cell) }
                        onCopyColumnName: function(name) { root.copyPlainText(name) }
                        onCopyRow: function(row) { root.copyGridRows(row) }
                        onCopyResults: root.copyGridRows(-1)
                      }
                      ScrollView {
                        objectName: "queryMessages"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.margins: 12
                        visible: root.resultPane === "messages"
                        clip: true
                        TextArea {
                          readOnly: true
                          selectByMouse: true
                          text: root.activeTab ? (root.activeTab.message || "") : ""
                          textFormat: TextEdit.PlainText
                          color: root.activeTab && root.activeTab.error ? Theme.Color.urgent : root.ink
                          font.family: root.codeFont
                          font.pixelSize: Math.max(14, Style.font.body)
                          wrapMode: TextEdit.Wrap
                          background: null
                        }
                      }
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
                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: root.activeTab && root.activeTab.object ? root.activeTab.object.schema + "." + root.activeTab.object.name : ""; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(18, Style.font.heading); font.bold: true }
                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: root.tableEditHint(); color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall) }
                  }
                  StudioButton { objectName: "openTableExportButton"; label: "Export…"; iconName: "document-save"; buttonEnabled: !!root.activeTab && !!root.activeTab.definition && !root.exportBusy; onClicked: root.openTableExport() }
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
                  StudioButton { label: root.activeTab && root.activeTab.filter ? "Filtered…" : "Filter…"; compact: true; prominent: !!root.activeTab && !!root.activeTab.filter; buttonEnabled: !!root.activeTab && !!root.activeTab.definition && !root.activeTab.busy; onClicked: root.openTableFilter() }
                  StudioButton { label: "Edit row"; helpText: "Edit selected row (F2)"; compact: true; buttonEnabled: tableGrid.canEditSelectedRow(); onClicked: root.openCellEditor(tableGrid.selectedCell()) }
                  StudioButton { label: "Copy"; helpText: "Copy results with headers"; compact: true; buttonEnabled: !!root.activeTab && root.activeTab.rows.length > 0 && !root.activeTab.busy; onClicked: root.copyGridRows(-1) }
                  StudioButton { label: "Cancel"; compact: true; visible: !!root.activeTab && root.activeTab.busy && root.activeTab.tablePane === "data"; onClicked: root.cancelTableRows(root.activeTab.id) }
                  StudioButton { label: "Refresh"; compact: true; buttonEnabled: root.connectionId !== "" && !!root.activeTab && !root.activeTab.busy; onClicked: { if (root.activeTab) { root.inspectObject(root.activeTab.object); root.loadTableRows(root.activeTab.id, root.activeTab.offset || 0) } } Layout.rightMargin: 12 }
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
                DbGrid {
                  id: tableGrid
                  layoutKey: root.activeTab ? root.activeTab.id : ""
                  sortableColumns: root.tableSortableColumns()
                  sort: root.activeTab ? root.activeTab.sort || null : null
                  onSortRequested: function(column) { root.sortTable(column) }
                  editableColumns: root.tableEditableColumns()
                  onEditCell: function(cell) { root.openCellEditor(cell) }
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
                  hasMore: root.activeTab ? !!root.activeTab.hasMore : false
                  limit: root.rowLimit
                  onNextPage: root.nextTablePage(root.activeTab.id)
                  onPreviousPage: root.previousTablePage(root.activeTab.id)
                  onViewCell: function(cell) { root.openCellViewer(cell) }
                  onCopyCell: function(cell) { root.copyCellValue(cell) }
                  onCopyColumnName: function(name) { root.copyPlainText(name) }
                      onCopyRow: function(row) { root.copyGridRows(row) }
                      onCopyResults: root.copyGridRows(-1)
                }
                ScrollView {
                  id: definitionScroll
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.margins: 20
                  visible: root.activeTab && root.activeTab.tablePane === "definition"
                  clip: true
                  ColumnLayout {
                    width: definitionScroll.availableWidth
                    spacing: 12
                    RowLayout {
                      Layout.fillWidth: true
                      Text { Layout.fillWidth: true; text: "COLUMNS"; color: root.accent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); font.bold: true; font.letterSpacing: 1.1 }
                      StudioButton {
                        objectName: "generateTableScriptButton"
                        label: root.scriptBusy ? "Generating…" : "Generate script…"
                        iconName: "accessories-text-editor"
                        compact: true
                        visible: !!root.activeTab && !!root.activeTab.object && root.activeTab.object.type === "table"
                        buttonEnabled: !!root.connectionId && !root.scriptBusy
                        onClicked: root.openTableScriptMenu(root.activeTab.object, this)
                      }
                    }
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
      id: sqlOpenDialog
      title: "Open SQL file"
      fileMode: FileDialog.OpenFile
      nameFilters: ["SQL files (*.sql *.SQL)"]
      onAccepted: root.openSqlFile(decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")))
    }
    FileDialog {
      id: sqlSaveDialog
      title: "Save SQL file"
      fileMode: FileDialog.SaveFile
      defaultSuffix: "sql"
      nameFilters: ["SQL files (*.sql)"]
      onAccepted: root.writeSqlFile(root.savingSqlTabId, decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")), true)
      onRejected: { root.savingSqlTabId = ""; root.closeAfterSaveId = "" }
    }
    Dialog {
      id: unsavedDialog
      objectName: "unsavedQueryDialog"
      parent: window.contentItem
      anchors.centerIn: parent
      width: Math.min(540, window.width - 40)
      modal: true
      padding: 16
      background: Rectangle { color: root.bg; border.color: root.accent; border.width: 1; radius: 8 }
      header: Text { text: "Save SQL before closing?"; padding: 16; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(16, Style.font.title); font.bold: true }
      contentItem: ColumnLayout {
        spacing: 16
        Text { Layout.fillWidth: true; text: "This query has unsaved changes."; color: root.ink; font.family: root.uiFont; wrapMode: Text.WordWrap }
        RowLayout {
          Layout.fillWidth: true
          StudioButton { label: "Discard"; compact: true; onClicked: { unsavedDialog.close(); root.closeTab(root.closingTabId, true) } }
          Item { Layout.fillWidth: true }
          StudioButton { label: "Cancel"; compact: true; onClicked: unsavedDialog.close() }
          StudioButton { label: "Save"; compact: true; prominent: true; onClicked: { unsavedDialog.close(); root.closeAfterSaveId = root.closingTabId; root.saveQuery(root.closingTabId, false) } }
        }
      }
    }

    FileDialog {
      id: exportSaveDialog
      objectName: "exportSaveDialog"
      title: "Export table as " + root.exportFormat.toUpperCase()
      fileMode: FileDialog.SaveFile
      defaultSuffix: root.exportFormat
      nameFilters: root.exportFormat === "sql" ? ["SQL files (*.sql)"] : ["CSV files (*.csv)"]
      onAccepted: root.startTableExport(decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")))
      onRejected: root.exportOptions = null
    }
    Dialog {
      id: tableExportDialog
      objectName: "tableExportDialog"
      parent: window.contentItem
      anchors.centerIn: parent
      width: Math.min(660, window.width - 40)
      height: Math.min(720, window.height - 40)
      modal: true
      closePolicy: root.exportBusy ? Popup.NoAutoClose : Popup.CloseOnEscape
      padding: 16
      background: Rectangle { color: root.bg; border.color: root.accent; border.width: 1; radius: 8 }
      header: Text { text: "Export table"; padding: 16; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(16, Style.font.title); font.bold: true }
      contentItem: ScrollView {
        id: exportScroll
        clip: true
        contentWidth: availableWidth
        ColumnLayout {
          width: exportScroll.availableWidth
          spacing: 12
          enabled: !root.exportBusy
          Text { Layout.fillWidth: true; text: root.exportContext ? root.exportContext.schema + "." + root.exportContext.name : ""; textFormat: Text.PlainText; color: root.ink; font.family: root.codeFont; elide: Text.ElideRight }
          Text { Layout.fillWidth: true; text: "Export every matching row with full values. The grid page size does not limit the export."; color: root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap }
          RowLayout {
            Layout.fillWidth: true
            Text { text: "Format"; color: root.ink; font.family: root.uiFont; font.bold: true }
            StudioChoice { id: exportFormatChoice; objectName: "exportFormat"; Layout.fillWidth: true; Accessible.name: "Export format"; model: ["CSV (.csv)", "SQL INSERT statements (.sql)"]; onCurrentIndexChanged: root.changeExportFormat() }
          }
          Text { Layout.fillWidth: true; text: root.exportFormat === "sql" ? "Data for an existing table, using this database's SQL dialect. Generated columns are omitted; review keys, constraints, and sequences before importing." : "UTF-8 with a header row. NULL is an empty field; empty text is quoted. Binary values use hexadecimal."; color: root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap; font.pixelSize: Math.max(12, Style.font.caption) }
          StudioCheck { id: exportFilterEnabled; objectName: "exportFilterEnabled"; text: "Filter rows"; enabled: root.exportFilterColumns().length > 0 }
          ColumnLayout {
            Layout.fillWidth: true
            visible: exportFilterEnabled.checked
            spacing: 8
            RowLayout {
              Layout.fillWidth: true
              StudioChoice { id: exportFilterColumn; objectName: "exportFilterColumn"; Layout.fillWidth: true; Layout.preferredWidth: 1; Accessible.name: "Filter column"; model: root.exportFilterColumns().map(function(column) { return column.name }); onCurrentIndexChanged: exportFilterOperator.currentIndex = 0 }
              StudioChoice { id: exportFilterOperator; objectName: "exportFilterOperator"; Layout.fillWidth: true; Layout.preferredWidth: 1; Accessible.name: "Filter condition"; model: root.exportFilterOperators().map(function(op) { return op.label }) }
            }
            StudioField { id: exportFilterValue; objectName: "exportFilterValue"; Layout.fillWidth: true; Accessible.name: "Export filter value"; placeholderText: "Value (empty text is allowed)"; maximumLength: 2000; enabled: { var op = root.exportFilterOperators()[exportFilterOperator.currentIndex]; return !!op && !/^(isNull|notNull)$/.test(op.value) } }
            Text { Layout.fillWidth: true; text: "Applies to this export. The table view keeps its current filter."; color: root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap; font.pixelSize: Math.max(12, Style.font.caption) }
          }
          RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; text: "Columns · " + root.exportSelectedColumns.length + " selected"; color: root.ink; font.family: root.uiFont; font.bold: true }
            StudioButton { label: "Select all"; compact: true; onClicked: root.selectExportColumns(true) }
            StudioButton { label: "Clear"; compact: true; onClicked: root.selectExportColumns(false) }
          }
          ScrollView {
            id: exportColumnScroll
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(230, Math.max(44, root.exportColumns().length * 38))
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
              width: exportColumnScroll.availableWidth
              spacing: 2
              Repeater {
                id: exportColumnChecks
                objectName: "exportColumnChecks"
                model: root.exportColumns()
                delegate: RowLayout {
                  id: exportColumnRow
                  required property var modelData
                  required property int index
                  property alias check: exportColumnCheck
                  Layout.fillWidth: true
                  Layout.preferredHeight: 36
                  StudioCheck {
                    id: exportColumnCheck
                    objectName: "exportColumn_" + exportColumnRow.index
                    Layout.fillWidth: true
                    text: exportColumnRow.modelData.name
                    checked: root.exportSelectedColumns.indexOf(exportColumnRow.modelData.name) >= 0
                    enabled: root.exportColumnAllowed(exportColumnRow.modelData)
                    opacity: enabled ? 1 : 0.5
                    onToggled: root.toggleExportColumn(exportColumnRow.modelData.name, checked)
                    contentItem: Text { text: exportColumnCheck.text; font: exportColumnCheck.font; leftPadding: exportColumnCheck.indicator.width + exportColumnCheck.spacing; verticalAlignment: Text.AlignVCenter; color: root.ink; elide: Text.ElideRight; textFormat: Text.PlainText }
                  }
                  Text { Layout.maximumWidth: 220; text: root.exportColumnAllowed(exportColumnRow.modelData) ? exportColumnRow.modelData.type : "Generated · omitted"; textFormat: Text.PlainText; color: root.faintInk; elide: Text.ElideRight; font.family: root.codeFont; font.pixelSize: Math.max(12, Style.font.caption) }
                }
              }
            }
          }
          Text { Layout.fillWidth: true; visible: !!root.exportContext && !root.exportColumns().some(function(column) { return column.primaryKey }); text: "This object has no primary key. Rows may move during export if the data changes."; color: root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap; font.pixelSize: Math.max(12, Style.font.caption) }
        }
      }
      footer: ColumnLayout {
        spacing: 10
        Text { Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; visible: root.exportError !== "" || root.exportBusy; text: root.exportBusy ? (root.exportCancelling ? "Cancelling export…" : "Exporting full values to file…") : root.exportError; color: root.exportError ? Theme.Color.urgent : root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap }
        RowLayout {
          Layout.fillWidth: true
          Layout.margins: 16
          StudioButton { label: root.exportBusy ? "Cancel export" : "Cancel"; compact: true; buttonEnabled: !root.exportCancelling; onClicked: root.cancelTableExport() }
          Item { Layout.fillWidth: true }
          StudioButton { objectName: "saveTableExportButton"; label: root.exportBusy ? "Exporting…" : "Export…"; compact: true; prominent: true; buttonEnabled: !!root.exportContext && !root.exportBusy && root.exportSelectedColumns.length > 0; onClicked: root.chooseExportFile() }
        }
      }
    }

    Dialog {
      id: tableFilterDialog
      objectName: "tableFilterDialog"
      parent: window.contentItem
      anchors.centerIn: parent
      width: Math.min(560, window.width - 40)
      height: Math.min(380, window.height - 40)
      modal: true
      padding: 16
      background: Rectangle { color: root.bg; border.color: root.accent; border.width: 1; radius: 8 }
      header: Text { text: "Filter table rows"; padding: 16; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(16, Style.font.title); font.bold: true }
      contentItem: ColumnLayout {
        spacing: 10
        Text { Layout.fillWidth: true; text: "Filters run in the database, across all rows. Text matching follows the database collation."; color: root.softInk; wrapMode: Text.WordWrap; font.family: root.uiFont }
        StudioChoice { id: filterColumn; objectName: "filterColumn"; Layout.fillWidth: true; Accessible.name: "Column"; model: root.filterColumns().map(function(c) { return c.name }); onActivated: filterOperator.currentIndex = 0 }
        StudioChoice { id: filterOperator; objectName: "filterOperator"; Layout.fillWidth: true; Accessible.name: "Condition"; model: root.filterOperators().map(function(op) { return op.label }) }
        StudioField { id: filterValue; objectName: "filterValue"; Layout.fillWidth: true; Accessible.name: "Filter value"; placeholderText: "Value (empty text is allowed)"; maximumLength: 2000; enabled: { var op = root.filterOperators()[filterOperator.currentIndex]; return !!op && !/^(isNull|notNull)$/.test(op.value) } onAccepted: root.applyTableFilter(false) }
        Text { Layout.fillWidth: true; visible: root.filterError !== ""; text: root.filterError; color: Theme.Color.urgent; wrapMode: Text.WordWrap }
        Item { Layout.fillHeight: true }
        RowLayout {
          Layout.fillWidth: true
          StudioButton { label: "Clear filter"; compact: true; onClicked: root.applyTableFilter(true) }
          Item { Layout.fillWidth: true }
          StudioButton { label: "Cancel"; compact: true; onClicked: tableFilterDialog.close() }
          StudioButton { label: "Apply"; compact: true; prominent: true; buttonEnabled: root.filterColumns().length > 0; onClicked: root.applyTableFilter(false) }
        }
      }
    }

    Dialog {
      id: editDialog
      objectName: "editValueDialog"
      parent: window.contentItem
      anchors.centerIn: parent
      width: Math.min(620, window.width - 40)
      height: Math.min(680, window.height - 40)
      modal: true
      closePolicy: root.editSaving ? Popup.NoAutoClose : Popup.CloseOnEscape
      title: "Edit row"
      onClosed: { root.editingCell = null; root.editFields = [] }
      padding: 16
      header: Rectangle {
        implicitHeight: 50
        color: root.surface
        Text { anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; text: editDialog.title; textFormat: Text.PlainText; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(16, Style.font.title); font.bold: true }
      }
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.accent; radius: 8 }
      contentItem: ColumnLayout {
        spacing: 12
        Text { Layout.fillWidth: true; text: root.editingCell ? root.editingCell.title + " · " + root.editingCell.identity : ""; textFormat: Text.PlainText; elide: Text.ElideRight; color: root.ink; font.family: root.codeFont }
        Text { Layout.fillWidth: true; text: "Edit fields, then save all changes together. Keys and complex values are read-only."; wrapMode: Text.WordWrap; color: root.softInk; font.family: root.uiFont }
        ScrollView {
          id: rowEditScroll
          Layout.fillWidth: true; Layout.fillHeight: true; clip: true
          contentWidth: availableWidth
          ColumnLayout {
            width: rowEditScroll.availableWidth
            spacing: 16
            Repeater {
              id: rowEditFields
              objectName: "rowEditFields"
              model: root.editFields
              delegate: ColumnLayout {
                id: rowField
                required property var modelData
                required property int index
                property alias input: rowValue
                property alias nullInput: rowNull
                readonly property bool booleanType: /^(boolean|bool|bit)$/i.test(modelData.type)
                readonly property bool changed: !modelData.readOnly && (rowNull.checked !== (modelData.original === null) ||
                  (!rowNull.checked && (booleanType && /^(true|false|0|1)$/i.test(rowValue.text) ?
                    /^(true|1)$/i.test(rowValue.text) !== modelData.original : rowValue.text !== String(modelData.original))))
                onChangedChanged: root.editRevision++
                Layout.fillWidth: true
                spacing: 6
                RowLayout {
                  Layout.fillWidth: true
                  Text { Layout.fillWidth: true; text: rowField.modelData.column; textFormat: Text.PlainText; elide: Text.ElideRight; color: rowField.changed ? root.accent : root.ink; font.family: root.uiFont; font.bold: true }
                  Text { text: rowField.changed ? "Modified" : rowField.modelData.type; textFormat: Text.PlainText; color: rowField.changed ? root.accent : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                  CheckBox {
                    id: rowNull
                    objectName: "rowEditNull_" + rowField.index
                    text: "NULL"
                    checked: rowField.modelData.original === null
                    enabled: rowField.modelData.nullable && !rowField.modelData.readOnly && !root.editSaving && !!root.editingCell
                    Accessible.name: rowField.modelData.column + " set to NULL"
                    contentItem: Text { text: rowNull.text; leftPadding: rowNull.indicator.width + rowNull.spacing; verticalAlignment: Text.AlignVCenter; color: root.ink; font.family: root.uiFont }
                  }
                }
                ScrollView {
                  Layout.fillWidth: true
                  Layout.preferredHeight: /^(character|varchar|nvarchar|char|nchar|text|tinytext|mediumtext|longtext|citext)/i.test(rowField.modelData.type) ? 84 : 44
                  clip: true
                  TextArea {
                    id: rowValue
                    objectName: "rowEditValue_" + rowField.index
                    Accessible.name: rowField.modelData.column
                    text: rowField.modelData.original === null ? "" : String(rowField.modelData.original)
                    enabled: !rowNull.checked && !root.editSaving && !!root.editingCell
                    readOnly: rowField.modelData.readOnly
                    wrapMode: TextEdit.Wrap
                    color: root.ink; font.family: root.codeFont; selectByMouse: true
                    background: Rectangle { color: root.surface; border.color: rowField.changed ? root.accent : root.line; border.width: 1; radius: 4 }
                  }
                }
                Text { Layout.fillWidth: true; visible: rowField.modelData.readOnly; text: "Shortened value · use SQL to edit"; color: root.softInk; font.family: root.uiFont }
              }
            }
          }
        }
        Text { Layout.fillWidth: true; visible: root.editError !== ""; text: root.editError; textFormat: Text.PlainText; wrapMode: Text.WordWrap; color: Theme.Color.urgent }
        RowLayout {
          Layout.fillWidth: true
          StudioButton { label: "Cancel"; buttonEnabled: !root.editSaving; onClicked: editDialog.close() }
          Text { Layout.fillWidth: true; text: root.editedCellCount + (root.editedCellCount === 1 ? " changed cell" : " changed cells"); color: root.softInk; font.family: root.uiFont; horizontalAlignment: Text.AlignRight }
          StudioButton { objectName: "saveRowButton"; label: root.editSaving ? "Saving…" : "Save row"; prominent: true; buttonEnabled: !!root.editingCell && !root.editSaving && root.editedCellCount > 0; onClicked: root.saveCellEdit() }
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
      id: diffOptionsDialog
      parent: window.contentItem
      anchors.centerIn: parent
      modal: true
      title: "Script options"
      width: Math.min(580, window.width - 60)
      height: Math.min(520, window.height - 44)
      padding: 0
      header: Rectangle {
        implicitHeight: 48; color: root.raised; radius: 8
        Text { anchors.fill: parent; anchors.margins: 16; text: "Script options"; color: root.ink; font.family: root.uiFont; font.bold: true; verticalAlignment: Text.AlignVCenter }
      }
      background: Rectangle { color: root.bg; border.width: 1; border.color: root.accent; radius: 8 }
      contentItem: ScrollView {
        id: diffOptionsScroll
        clip: true
        padding: 16
        contentWidth: availableWidth
        ColumnLayout {
        width: diffOptionsScroll.availableWidth
        spacing: 10
        Text { Layout.fillWidth: true; text: "New tables"; color: root.ink; font.bold: true; font.family: root.uiFont }
        Repeater {
          model: [{key:"includeIndexes",label:"Include indexes"}, {key:"includeChecks",label:"Include CHECK constraints"}, {key:"includeForeignKeys",label:"Include foreign keys"}]
          StudioCheck { required property var modelData; text: modelData.label; checked: root.diffScriptOptions[modelData.key]; onClicked: root.setDiffOption(modelData.key, checked) }
        }
        Text { Layout.fillWidth: true; text: "Columns, defaults, primary keys, and unique constraints stay included. Existing-table index and constraint differences are not compared."; color: root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.line }
        StudioCheck { text: "Refresh dependent target views"; checked: root.diffScriptOptions.refreshDependentViews; onClicked: root.setDiffOption("refreshDependentViews", checked) }
        Text { Layout.fillWidth: true; text: "Adds sys.sp_refreshview after changes for existing non-schema-bound views, including unchecked views and views outside the comparison. Their target definitions are preserved. Disabling this leaves required refreshes as manual work. Schema-bound dependencies require manual review."; color: root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap }
        }
      }
      footer: Rectangle {
        implicitHeight: 52; color: root.raised; radius: 8
        StudioButton { anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; label: "Done"; compact: true; onClicked: diffOptionsDialog.close() }
      }
    }

    Dialog {
      id: diffDialog
      objectName: "schemaDiffDialog"
      parent: window.contentItem
      modal: true
      title: "Schema diff"
      anchors.centerIn: parent
      width: Math.min(1100, window.width - (window.height < 600 ? 24 : 44))
      height: Math.min(850, window.height - (window.height < 600 ? 24 : 44))
      padding: 0
      onClosed: { diffTargetOnlyDialog.close(); diffOptionsDialog.close(); root.resetDiffResults() }
      Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.56) }
      background: Rectangle { color: root.bg; border.width: 2; border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.65); radius: 10 }
      header: Rectangle {
        implicitHeight: window.height < 600 ? 50 : 62
        color: root.raised
        radius: 10
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: root.line }
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 20
          Text { Layout.fillWidth: true; text: "Schema diff · " + (root.diffPhase === "setup" ? "1. Connections" : root.diffPhase === "select" ? "2. Compare scope" : root.diffPhase === "results" ? "3. Script scope" : "4. Review script"); color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(19, Style.font.heading); font.bold: true }
          Text { visible: diffDialog.width > 850; text: "SQL Server · Azure SQL"; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
          StudioButton { label: "Close"; compact: true; onClicked: diffDialog.close() }
        }
      }
      contentItem: Item {
        ColumnLayout {
          anchors.fill: parent
          anchors.margins: window.height < 600 ? 12 : 20
          spacing: window.height < 600 ? 8 : 12
          Text {
            Layout.fillWidth: true
            visible: window.height >= 600 || root.diffPhase === "setup"
            text: root.diffPhase === "setup" ? "Choose the source and target databases. The script proposes supported changes from source to target."
              : root.diffPhase === "select" ? "Choose tables and views to compare. Type and schema checkboxes select groups; a dash means partly selected."
              : root.diffPhase === "results" ? "Choose which differences to script. Filtering changes the list; hidden selections stay included."
              : "Review the SQL before saving or copying it. DB Studio will not run this script."
            textFormat: Text.PlainText
            color: root.ink
            font.family: root.uiFont
            font.pixelSize: Math.max(14, Style.font.body)
            wrapMode: Text.WordWrap
          }
          Text { Layout.fillWidth: true; visible: window.height >= 600 && !!root.diffCatalog && (root.diffPhase === "results" || root.diffPhase === "script"); text: root.diffCatalog ? root.diffCatalog.sourceName + " (" + root.diffCatalog.sourceDatabase + ") → " + root.diffCatalog.targetName + " (" + root.diffCatalog.targetDatabase + ")" : ""; textFormat: Text.PlainText; color: root.softInk; font.family: root.uiFont; elide: Text.ElideRight }
          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.line }
          StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            enabled: !root.diffBusy
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
                        root.diffSourceProfileId = profile ? profile.id : ""; root.resetDiffResults()
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
                        root.diffTargetProfileId = profile ? profile.id : ""; root.resetDiffResults()
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
                RowLayout {
                  Layout.fillWidth: true
                  Repeater {
                    model: [{type:"table", label:"Tables"}, {type:"view", label:"Views"}]
                    StudioCheck {
                      required property var modelData
                      objectName: "diffCompareType_" + modelData.type
                      readonly property var objects: root.diffSelectionObjects(modelData.type)
                      text: modelData.label + " (" + objects.filter(function(object) { return !!root.diffSelectedObjects[root.diffObjectKey(object)] }).length + "/" + objects.length + ")"
                      checkState: root.diffCheckState(objects, root.diffSelectedObjects)
                      enabled: objects.length > 0
                      onClicked: root.setDiffObjects(objects, checkState === Qt.Checked)
                    }
                  }
                  Item { Layout.fillWidth: true }
                  StudioButton { label: "Expand"; compact: true; onClicked: root.expandDiffSchemas(true) }
                  StudioButton { label: "Collapse"; compact: true; onClicked: root.expandDiffSchemas(false) }
                }
                RowLayout {
                  Layout.fillWidth: true
                  StudioField { Layout.fillWidth: true; placeholderText: "Search schema or object name…"; text: root.diffFilter; onTextChanged: root.diffFilter = text }
                  StudioButton { label: "Select shown"; compact: true; buttonEnabled: root.diffMatchingObjects().length > 0; onClicked: root.setDiffObjects(root.diffMatchingObjects(), true) }
                  StudioButton { label: "Clear shown"; compact: true; buttonEnabled: root.diffMatchingObjects().length > 0; onClicked: root.setDiffObjects(root.diffMatchingObjects(), false) }
                }
                Text { Layout.fillWidth: true; text: "Supports tables and views. Procedures, functions, and other object types are not compared."; color: root.softInk; font.family: root.uiFont; font.pixelSize: 12; wrapMode: Text.WordWrap }
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
                        StudioButton {
                          visible: diffSelectionRow.schemaRow
                          Layout.preferredWidth: 28
                          label: root.diffExpandedSchemas[diffSelectionRow.modelData.name] ? "⌄" : "›"
                          compact: true
                          Accessible.name: "Expand or collapse schema " + diffSelectionRow.modelData.name
                          onClicked: root.diffExpandedSchemas = Object.assign({}, root.diffExpandedSchemas, { [diffSelectionRow.modelData.name]: !root.diffExpandedSchemas[diffSelectionRow.modelData.name] })
                        }
                        StudioCheck { text: ""; Accessible.name: diffSelectionRow.schemaRow ? "Compare schema " + diffSelectionRow.modelData.name : "Compare " + diffSelectionRow.modelData.object.name; checkState: root.diffCheckState(root.diffRowObjects(diffSelectionRow.modelData), root.diffSelectedObjects); onClicked: root.toggleDiffRow(diffSelectionRow.modelData, checkState === Qt.Checked) }
                        StudioIcon { Layout.preferredWidth: 16; Layout.preferredHeight: 16; iconName: diffSelectionRow.schemaRow ? "server-database" : diffSelectionRow.modelData.object.type === "view" ? "view-list-details" : "x-office-spreadsheet" }
                        Text { Layout.fillWidth: true; text: diffSelectionRow.schemaRow ? diffSelectionRow.modelData.name : diffSelectionRow.modelData.object.name; textFormat: Text.PlainText; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: diffSelectionRow.schemaRow; elide: Text.ElideRight }
                        Text { text: diffSelectionRow.schemaRow ? root.diffRowObjects(diffSelectionRow.modelData).filter(function(object) { return !!root.diffSelectedObjects[root.diffObjectKey(object)] }).length + "/" + root.diffRowObjects(diffSelectionRow.modelData).length : diffSelectionRow.modelData.object.type; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption) }
                      }
                      HoverHandler { id: diffRowHover }
                    }
                  }
                  Text { anchors.centerIn: parent; visible: root.diffRows().length === 0; text: "No objects match this search."; color: root.softInk; font.family: root.uiFont }
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
                  Repeater {
                    model: [{type:"table", label:"Tables"}, {type:"view", label:"Views"}]
                    StudioCheck {
                      required property var modelData
                      objectName: "diffScriptType_" + modelData.type
                      readonly property var changes: root.diffTypeChanges(modelData.type)
                      text: modelData.label + " (" + changes.filter(function(change) { return !!root.diffIncluded[root.diffObjectKey(change)] }).length + "/" + changes.length + ")"
                      enabled: changes.length > 0
                      checkState: root.diffCheckState(changes, root.diffIncluded)
                      onClicked: root.setDiffIncluded(changes, checkState === Qt.Checked)
                    }
                  }
                  Item { Layout.fillWidth: true }
                  StudioButton { label: "Select all"; compact: true; onClicked: root.setDiffIncluded(root.diffResult.changes, true) }
                  StudioButton { label: "Clear all"; compact: true; onClicked: root.setDiffIncluded(root.diffResult.changes, false) }
                  StudioButton { label: "Script options"; compact: true; onClicked: diffOptionsDialog.open() }
                }
                RowLayout {
                  Layout.fillWidth: true
                  StudioField { Layout.fillWidth: true; placeholderText: "Search differences…"; text: root.diffResultFilter; onTextChanged: root.diffResultFilter = text }
                  StudioChoice { implicitWidth: 118; Accessible.name: "Filter differences by object type"; model: ["All types", "Tables", "Views"]; currentIndex: ["all","table","view"].indexOf(root.diffResultType); onActivated: function(index) { root.diffResultType = ["all","table","view"][index] } }
                  StudioChoice { implicitWidth: 172; Accessible.name: "Filter differences by status"; model: ["All differences", "Missing in target", "Different in target", "Manual review"]; currentIndex: ["all","missing","different","manual"].indexOf(root.diffResultStatus); onActivated: function(index) { root.diffResultStatus = ["all","missing","different","manual"][index] } }
                  StudioButton { label: "Select shown"; compact: true; buttonEnabled: root.diffVisibleChanges().length > 0; onClicked: root.setDiffIncluded(root.diffVisibleChanges(), true) }
                  StudioButton { label: "Clear shown"; compact: true; buttonEnabled: root.diffVisibleChanges().length > 0; onClicked: root.setDiffIncluded(root.diffVisibleChanges(), false) }
                }
                Text { Layout.fillWidth: true; visible: !!root.diffResult && root.diffResult.changes.length > 0 && root.diffVisibleChanges().length === 0; text: "No differences match these filters. Clear the search or choose All types / All differences."; color: root.softInk; font.family: root.uiFont; wrapMode: Text.WordWrap }
                RowLayout {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  spacing: 12
                  Rectangle {
                    Layout.preferredWidth: Math.min(365, diffDialog.width * 0.38)
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
                        activeFocusOnTab: objectRow
                        Accessible.role: Accessible.ListItem
                        Accessible.name: objectRow ? modelData.change.schema + "." + modelData.change.name : modelData.label
                        Keys.onReturnPressed: if (objectRow) root.focusDiffChange(modelData.key)
                        Keys.onSpacePressed: if (objectRow) root.toggleDiffIncluded(modelData.key, !root.diffIncluded[modelData.key])
                        width: ListView.view.width
                        height: modelData.kind === "section" ? 45 : modelData.kind === "group" ? 38 : 45
                        color: modelData.kind === "section" ? root.raised : objectRow && root.diffFocusedKey === modelData.key ? root.selected : diffResultHover.hovered && objectRow ? root.raised : "transparent"
                        border.width: activeFocus ? 2 : objectRow && root.diffFocusedKey === modelData.key ? 1 : 0
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
                            Accessible.name: diffResultRow.objectRow ? "Include " + diffResultRow.modelData.change.schema + "." + diffResultRow.modelData.change.name : "Include " + diffResultRow.modelData.label
                            checkState: diffResultRow.modelData.kind === "group" ? root.diffCheckState(root.diffGroupChanges(diffResultRow.modelData.groupKey), root.diffIncluded) : root.diffIncluded[diffResultRow.modelData.key] ? Qt.Checked : Qt.Unchecked
                            onClicked: {
                              if (diffResultRow.modelData.kind === "group") root.toggleDiffGroup(diffResultRow.modelData.groupKey, checkState === Qt.Checked)
                              else root.toggleDiffIncluded(diffResultRow.modelData.key, checkState === Qt.Checked)
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
                            text: diffResultRow.modelData.kind === "group" ? root.diffIncludedCount(diffResultRow.modelData.groupKey) + "/" + diffResultRow.modelData.count : diffResultRow.modelData.kind === "section" ? String(diffResultRow.modelData.count) : (diffResultRow.modelData.change.reviewRequired || diffResultRow.modelData.change.status === "manual") ? "Review" : diffResultRow.modelData.change.status === "create" ? "Create" : "Modify"
                            color: diffResultRow.objectRow && (diffResultRow.modelData.change.reviewRequired || diffResultRow.modelData.change.status === "manual") ? Theme.Color.urgent : root.accent
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
                    ScrollView {
                      id: diffInspectorScroll
                      anchors.fill: parent
                      anchors.margins: 12
                      clip: true
                      contentWidth: availableWidth
                      ColumnLayout {
                      width: diffInspectorScroll.availableWidth
                      height: Math.max(implicitHeight, diffInspectorScroll.availableHeight)
                      spacing: 8
                      Text { Layout.fillWidth: true; text: root.diffPreview ? root.diffPreview.schema + "." + root.diffPreview.name : root.diffPreviewBusy ? "Loading change…" : "Select an object to inspect"; textFormat: Text.PlainText; color: root.ink; font.family: root.codeFont; font.pixelSize: Math.max(15, Style.font.body); font.bold: true; elide: Text.ElideRight }
                      Text { Layout.fillWidth: true; visible: !!root.diffPreview; text: root.diffPreview ? (root.diffPreview.status === "manual" ? "Different in target · manual review" : (root.diffPreview.status === "create" ? "Missing in target · CREATE " : "Different in target · ALTER ") + root.diffPreview.type.toUpperCase() + (root.diffPreview.complete ? "" : " · manual review needed")) : ""; color: root.diffPreview && !root.diffPreview.complete ? Theme.Color.urgent : root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.bodySmall); wrapMode: Text.WordWrap }
                      Text { Layout.fillWidth: true; visible: !!root.diffPreview && root.diffPreview.notes.length > 0; text: root.diffPreview ? root.diffPreview.notes.join(" ") : ""; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.bodySmall); wrapMode: Text.WordWrap }
                      Text { Layout.fillWidth: true; visible: !!root.diffPreview && root.diffPreview.manual.length > 0; text: root.diffPreview ? root.diffPreview.manual.slice(0, 3).join("\n") : ""; textFormat: Text.PlainText; color: Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(12, Style.font.caption); wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight }
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
                        Layout.minimumHeight: 100
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
                }
                Text { Layout.fillWidth: true; visible: !!root.diffResult && root.diffResult.changes.length === 0; text: "No differences in the selected objects."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) }
              }
            }

            Item {
              ColumnLayout {
                anchors.fill: parent
                spacing: 10
                Text { Layout.fillWidth: true; text: (root.diffScriptComplete ? "Script ready for selected scope" : "Script incomplete · " + root.diffManual.length + " items need manual review") + " · " + root.diffIncludedCount() + " differences · " + root.diffRefreshedViews.length + (root.diffRefreshedViews.length === 1 ? " view refresh" : " view refreshes"); color: root.diffScriptComplete ? root.ink : Theme.Color.urgent; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body); font.bold: true }
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
        implicitHeight: window.height < 600 ? 50 : 62
        color: root.raised
        radius: 10
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: root.line }
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 20
          anchors.rightMargin: 20
          spacing: 9
          StudioButton { label: "Back"; compact: true; visible: root.diffPhase !== "setup"; buttonEnabled: !root.diffBusy; onClicked: root.diffPhase = root.diffPhase === "script" ? "results" : root.diffPhase === "results" ? "select" : "setup" }
          Item { Layout.fillWidth: true }
          StudioButton { label: "Load objects"; compact: true; prominent: true; visible: root.diffPhase === "setup"; buttonEnabled: !root.diffBusy && root.diffSourceProfileId !== "" && root.diffTargetProfileId !== "" && root.diffSourceProfileId !== root.diffTargetProfileId; onClicked: root.loadDiffCatalog() }
          StudioButton { label: "Compare selected"; compact: true; prominent: true; visible: root.diffPhase === "select"; buttonEnabled: !root.diffBusy && root.diffSelectedCount() > 0; onClicked: root.compareDiff() }
          StudioButton { label: "Generate script (" + root.diffIncludedCount() + ")"; compact: true; prominent: true; visible: root.diffPhase === "results"; buttonEnabled: !root.diffBusy && root.diffIncludedCount() > 0; onClicked: root.generateDiffScript() }
          StudioButton { label: "Copy script"; compact: true; visible: root.diffPhase === "script"; buttonEnabled: root.diffScript !== ""; onClicked: root.copyPlainText(root.diffScript) }
          StudioButton { label: "Save .sql"; compact: true; prominent: true; visible: root.diffPhase === "script"; buttonEnabled: root.diffScript !== ""; onClicked: diffSaveDialog.open() }
        }
      }
    }

    Dialog {
      id: cellViewerDialog
      objectName: "cellViewerDialog"
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
      objectName: "connectionListDialog"
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
          StudioButton { objectName: "connectionMenuAddButton"; label: "Add connection"; iconName: "list-add"; prominent: true; onClicked: { connectionListDialog.close(); root.addConnection() } }
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
        RowLayout { Layout.fillWidth: true; Text { text: "Query timeout (seconds)"; color: root.ink; font.family: root.uiFont; font.pixelSize: Math.max(14, Style.font.body) } Item { Layout.fillWidth: true } SpinBox { from: 5; to: 1000; value: root.timeoutMs / 1000; onValueModified: root.timeoutMs = value * 1000 } }
        Text { Layout.fillWidth: true; text: "Edit table values with F2 or double-click, then Save. Primary keys, generated columns, complex types, views, and query results are read-only."; color: root.softInk; font.family: root.uiFont; font.pixelSize: Math.max(13, Style.font.bodySmall); wrapMode: Text.WordWrap }
        RowLayout { Layout.fillWidth: true; Item { Layout.fillWidth: true } StudioButton { label: "Done"; prominent: true; onClicked: settingsDialog.close() } }
      }
    }
  }
}
