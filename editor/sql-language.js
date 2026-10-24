// Shared by the QML editor and the Node tests. No database calls or SQL execution.
var commonKeywords = ('SELECT FROM WHERE JOIN INNER LEFT RIGHT FULL OUTER CROSS ON AS AND OR NOT NULL IS IN EXISTS BETWEEN LIKE DISTINCT ALL TOP LIMIT OFFSET FETCH FIRST NEXT ROW ROWS ONLY ORDER BY GROUP HAVING UNION INTERSECT EXCEPT WITH RECURSIVE OVER PARTITION CASE WHEN THEN ELSE END ASC DESC INSERT INTO VALUES UPDATE SET DELETE CREATE ALTER DROP TABLE VIEW INDEX DATABASE SCHEMA PRIMARY KEY FOREIGN REFERENCES DEFAULT CHECK CONSTRAINT UNIQUE RETURNING OUTPUT BEGIN COMMIT ROLLBACK TRANSACTION TRUNCATE EXPLAIN ANALYZE TRUE FALSE CAST CONVERT COALESCE NULLIF').split(' ')
var commonFunctions = ('COUNT SUM AVG MIN MAX ABS ROUND FLOOR CEIL CEILING LENGTH CHAR_LENGTH LOWER UPPER TRIM LTRIM RTRIM SUBSTRING REPLACE CONCAT LEFT RIGHT CURRENT_TIMESTAMP CURRENT_DATE ROW_NUMBER RANK DENSE_RANK LAG LEAD').split(' ')
var dialectKeywords = {cloudflare_d1:['PRAGMA','EXPLAIN','QUERY','PLAN','REPLACE','CONFLICT','NOTHING','RETURNING','WITHOUT','ROWID','STRICT','INTEGER','TEXT','BLOB','REAL','NUMERIC'],sqlserver:['DECLARE','EXEC','EXECUTE','GO','MERGE','APPLY','PIVOT','UNPIVOT','NVARCHAR','VARCHAR','INT','BIGINT','BIT','DATETIME2','TRY_CAST','TRY_CONVERT'],azure_sql:['DECLARE','EXEC','EXECUTE','GO','MERGE','APPLY','PIVOT','UNPIVOT','NVARCHAR','VARCHAR','INT','BIGINT','BIT','DATETIME2','TRY_CAST','TRY_CONVERT'],postgres:['ILIKE','LATERAL','MATERIALIZED','CONFLICT','DO','NOTHING','BOOLEAN','TEXT','UUID','JSONB','SERIAL'],mysql:['SHOW','DESCRIBE','USE','REPLACE','DUPLICATE','UNSIGNED','AUTO_INCREMENT','VARCHAR','INT','BIGINT','BOOLEAN','TEXT']}
var dialectFunctions = {cloudflare_d1:['IFNULL','IIF','GROUP_CONCAT','JSON_EXTRACT','JSON_EACH','JSON_ARRAY','JSON_OBJECT','STRFTIME','DATETIME','JULIANDAY','UNIXEPOCH','CHANGES','LAST_INSERT_ROWID'],sqlserver:['GETDATE','SYSDATETIME','DATEADD','DATEDIFF','ISNULL','LEN','STRING_AGG','JSON_VALUE','SCOPE_IDENTITY'],azure_sql:['GETDATE','SYSDATETIME','DATEADD','DATEDIFF','ISNULL','LEN','STRING_AGG','JSON_VALUE','SCOPE_IDENTITY'],postgres:['NOW','DATE_TRUNC','TO_CHAR','STRING_AGG','ARRAY_AGG','JSONB_AGG','GENERATE_SERIES'],mysql:['NOW','DATE_FORMAT','DATE_ADD','DATEDIFF','IFNULL','GROUP_CONCAT','JSON_EXTRACT']}
function words(dialect, functions) { return (functions ? commonFunctions : commonKeywords).concat((functions ? dialectFunctions : dialectKeywords)[dialect] || []) }
function wordMap(list) { var result = Object.create(null); list.forEach(function(word) { result[word] = true }); return result }
function identifierStart(c) { return !!c && /[A-Za-z_\u0080-\uffff]/.test(c) }
function identifierPart(c) { return !!c && /[A-Za-z0-9_$#\u0080-\uffff]/.test(c) }
function analyze(sql, dialect) {
  sql = String(sql || '')
  var keywords = wordMap(words(dialect, false)), functions = wordMap(words(dialect, true))
  var tokens = [], lines = [{start:0,end:sql.length}], i = 0
  function add(start, kind, closed) { tokens.push({start:start,end:i,text:sql.slice(start,i),kind:kind,closed:closed !== false}) }
  while (i < sql.length) {
    var start = i, c = sql[i], n = sql[i+1]
    if (/\s/.test(c)) { i++; continue }
    if ((c === '-' && n === '-') || (dialect === 'mysql' && c === '#')) {
      while (i < sql.length && sql[i] !== '\n') i++
      add(start,'comment',false); continue
    }
    if (c === '/' && n === '*') {
      i += 2; var depth = 1
      while (i < sql.length && depth) {
        if (sql.slice(i,i+2) === '/*' && dialect !== 'mysql') { depth++; i+=2 }
        else if (sql.slice(i,i+2) === '*/') { depth--; i+=2 }
        else i++
      }
      add(start,'comment',depth === 0); continue
    }
    var dollar = dialect === 'postgres' && c === '$' ? sql.slice(i).match(/^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/) : null
    if (dollar) {
      var end = sql.indexOf(dollar[0],i+dollar[0].length)
      i = end < 0 ? sql.length : end+dollar[0].length
      add(start,'string',end >= 0); continue
    }
    if (c === "'" || c === '"' || c === '[' || c === '`') {
      var closing = c === '[' ? ']' : c, closed = false
      i++
      while (i < sql.length) {
        if (sql[i] === closing) {
          i++
          if (sql[i] === closing) { i++; continue }
          closed = true; break
        }
        if (sql[i] === '\\' && (dialect === 'mysql' || (dialect === 'postgres' && c === "'" && /[eE]/.test(sql[start-1] || '') && !identifierPart(sql[start-2])))) i++
        i++
      }
      i = Math.min(i,sql.length)
      add(start,c === "'" || (c === '"' && dialect === 'mysql') ? 'string' : 'identifier',closed); continue
    }
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(n || ''))) {
      var number = sql.slice(i).match(/^(?:0x[0-9a-f]+|(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)/i)
      i += number[0].length; add(start,'number'); continue
    }
    if ((c === '@' || (c === ':' && n !== ':' && sql[i-1] !== ':') || c === '$') && (identifierPart(n) || n === '@')) {
      i++; if (sql[i] === '@') i++
      while (identifierPart(sql[i])) i++
      add(start,'variable'); continue
    }
    if (identifierStart(c)) {
      i++; while (identifierPart(sql[i])) i++
      var upper = sql.slice(start,i).toUpperCase()
      add(start,keywords[upper] ? 'keyword' : functions[upper] ? 'function' : 'identifier'); continue
    }
    i++; add(start,'operator')
  }
  for (i = 0; i < sql.length; i++) if (sql[i] === '\n') { lines[lines.length-1].end = i; lines.push({start:i+1,end:sql.length}) }
  return {text:sql,tokens:tokens,lines:lines}
}
function lineAt(analysis, position) {
  var low = 0, high = analysis.lines.length
  while (low < high) { var middle = (low+high) >> 1; if (analysis.lines[middle].start <= position) low = middle+1; else high = middle }
  return Math.max(0,low-1)
}
function tokenAt(tokens, position) {
  var low = 0, high = tokens.length
  while (low < high) { var middle = (low+high) >> 1; if (tokens[middle].end < position) low = middle+1; else high = middle }
  return low
}
function paintSegments(analysis, ranges, selectionStart, selectionEnd) {
  var result = [], tokens = analysis.tokens
  ranges.forEach(function(range) {
    for (var i = tokenAt(tokens,range.start); i < tokens.length && tokens[i].start < range.end; i++) {
      var token = tokens[i], start = Math.max(range.start,token.start), end = Math.min(range.end,token.end)
      function segment(a,b) {
        // Let the native editor place tab stops; never render tabs at a token-relative origin.
        var pieces = analysis.text.slice(a,b).split('\t'), position = a
        pieces.forEach(function(piece) { if (piece.length) result.push({start:position,text:piece,kind:token.kind}); position += piece.length+1 })
      }
      if (selectionStart < selectionEnd && start < selectionEnd && end > selectionStart) {
        segment(start,Math.min(end,selectionStart)); segment(Math.max(start,selectionEnd),end)
      } else segment(start,end)
    }
  })
  return result
}
function unquote(text) {
  var first = text[0], close = first === '[' ? ']' : first
  if (first !== '[' && first !== '"' && first !== '`') return text
  var value = text.slice(1)
  if (value.endsWith(close)) value = value.slice(0,-1)
  return value.split(close+close).join(close)
}
function quote(name, dialect) {
  name = String(name)
  return dialect === 'mysql' ? '`'+name.replace(/`/g,'``')+'`' : dialect === 'sqlserver' || dialect === 'azure_sql' ? '['+name.replace(/\]/g,']]')+']' : '"'+name.replace(/"/g,'""')+'"'
}
function objectKey(object) { return JSON.stringify([object.schema || '',object.name]) }
function nameToken(token) { return token && (token.kind === 'identifier' || token.kind === 'keyword' || token.kind === 'function') }
function qualified(tokens, start) {
  if (!nameToken(tokens[start])) return null
  var parts = [unquote(tokens[start].text)], i = start+1
  while (tokens[i] && tokens[i].text === '.' && nameToken(tokens[i+1])) { parts.push(unquote(tokens[i+1].text)); i+=2 }
  return {parts:parts,next:i}
}
function resolveObject(parts, catalog) {
  var name = parts[parts.length-1], schema = parts.length > 1 ? parts[parts.length-2] : null
  // Three-part/cross-database names cannot be resolved using this database's catalog.
  if (parts.length > 2) return null
  var matches = catalog.filter(function(o) { return o.name.toLowerCase() === name.toLowerCase() && (schema === null || (o.schema || '').toLowerCase() === schema.toLowerCase()) })
  return matches.length === 1 ? matches[0] : null
}
function references(tokens, catalog) {
  var refs = [], ctes = Object.create(null)
  // CTE output and derived tables need a full SQL parser. Do not substitute a
  // catalog table with the same name for a CTE or guess its output columns.
  if (tokens[0] && tokens[0].text.toUpperCase() === 'WITH') {
    for (var c = 1, nesting = 0; c < tokens.length; c++) {
      if (nesting === 0 && nameToken(tokens[c]) && (c === 1 || tokens[c-1].text === ',' || tokens[c-1].text.toUpperCase() === 'RECURSIVE')) ctes[unquote(tokens[c].text).toLowerCase()] = true
      if (tokens[c].text === '(') nesting++
      if (tokens[c].text === ')') nesting--
      if (!nesting && tokens[c].text.toUpperCase() === 'SELECT') break
    }
  }
  for (var i = 0; i < tokens.length; i++) {
    if (!/^(FROM|JOIN|UPDATE|INTO)$/.test(tokens[i].text.toUpperCase()) || tokens[i].kind !== 'keyword') continue
    var parsed = qualified(tokens,i+1)
    if (!parsed || (parsed.parts.length === 1 && ctes[parsed.parts[0].toLowerCase()])) continue
    var object = resolveObject(parsed.parts,catalog)
    if (!object) continue
    var next = parsed.next
    if (tokens[next] && tokens[next].text.toUpperCase() === 'AS') next++
    var alias = tokens[next] && tokens[next].kind === 'identifier' ? unquote(tokens[next].text) : ''
    refs.push({object:object,alias:alias,name:object.name,schema:object.schema || ''})
  }
  return refs
}
function complete(analysis, cursor, catalog, definitions, dialect, explicit) {
  var sql = analysis.text, tokens = analysis.tokens, start = cursor, end = cursor, prefix = ''
  var index = tokenAt(tokens,cursor), token = tokens[index]
  if (token && cursor > token.start && cursor <= token.end) {
    if (token.kind === 'comment' || token.kind === 'string') {
      if (cursor < token.end || !token.closed) return {items:[],missing:[],blocked:true,start:start,end:end}
    } else if (nameToken(token)) {
      start = token.start; end = token.end; prefix = unquote(sql.slice(start,cursor))
    }
  }
  var before = tokens.filter(function(t) { return t.end <= start && t.kind !== 'comment' && t.kind !== 'string' })
  var qualifiers = [], b = before.length-1
  if (before[b] && before[b].text === '.') {
    while (b > 0 && before[b].text === '.' && nameToken(before[b-1])) { qualifiers.unshift(unquote(before[b-1].text)); b-=2 }
  }
  if (!explicit && !qualifiers.length && prefix.length < 2) return {items:[],missing:[],start:start,end:end}
  var statementStart = 0, statementEnd = sql.length
  tokens.forEach(function(t) { if (t.text === ';' && t.kind === 'operator') { if (t.end <= cursor) statementStart = t.end; else if (statementEnd === sql.length) statementEnd = t.start } })
  var statement = tokens.filter(function(t) { return t.start >= statementStart && t.end <= statementEnd && t.kind !== 'comment' && t.kind !== 'string' })
  var refs = references(statement,catalog), items = [], missing = [], seen = Object.create(null), loading = false, unavailable = false
  var objectContext = before.length && /^(FROM|JOIN|UPDATE|INTO)$/.test(before[before.length-1].text.toUpperCase())
  var needle = prefix.toLowerCase()
  function add(label, insertion, kind, detail) {
    if (label.toLowerCase().indexOf(needle) !== 0 || seen[insertion]) return
    seen[insertion] = true; items.push({label:label,insertText:insertion,kind:kind,detail:detail || ''})
  }
  var selectedRefs = qualifiers.length ? refs.filter(function(ref) { return qualifiers.join('.').toLowerCase() === (ref.alias || ref.name).toLowerCase() || qualifiers.join('.').toLowerCase() === (ref.schema+'.'+ref.name).toLowerCase() }) : refs
  var schemaQualifier = qualifiers.length === 1 && !selectedRefs.length ? qualifiers[0] : null
  if (!objectContext && !schemaQualifier) {
    selectedRefs.forEach(function(ref) {
      var key = objectKey(ref.object), definition = definitions[key]
      if (!definition) { if (!missing.some(function(o) { return objectKey(o) === key }) && missing.length < 4) missing.push(ref.object); loading = true; return }
      if (definition.loading) { loading = true; return }
      if (definition.error) { unavailable = true; return }
      ;(definition.columns || []).forEach(function(column) {
        var insertion = quote(column.name,dialect)
        if (!qualifiers.length && selectedRefs.length > 1) insertion = quote(ref.alias || ref.name,dialect)+'.'+insertion
        add(column.name,insertion,'column',(ref.alias || ref.name)+' · '+(column.type || 'column'))
      })
    })
  }
  if (!qualifiers.length || schemaQualifier) {
    if (objectContext || schemaQualifier) {
      catalog.forEach(function(object) {
        if (schemaQualifier && (object.schema || '').toLowerCase() !== schemaQualifier.toLowerCase()) return
        var insertion = (schemaQualifier || !object.schema ? '' : quote(object.schema,dialect)+'.')+quote(object.name,dialect)
        add(object.name,insertion,object.type === 'view' ? 'view' : 'table',object.schema || '')
      })
    }
    if (!schemaQualifier) {
      var schemas = Object.create(null)
      catalog.forEach(function(object) { if (object.schema && !schemas[object.schema]) { schemas[object.schema] = true; add(object.schema,quote(object.schema,dialect)+'.','schema','schema') } })
      words(dialect,false).forEach(function(word) { add(word,word,'keyword','SQL keyword') })
      if (!objectContext) words(dialect,true).forEach(function(word) { add(word,word,'function','SQL function') })
    }
  }
  items.sort(function(a,b) { var rank = {column:0,table:1,view:1,schema:2,keyword:3,function:4}; return rank[a.kind]-rank[b.kind] || a.label.localeCompare(b.label) || a.detail.localeCompare(b.detail) })
  return {items:items.slice(0,80),missing:missing,start:start,end:end,prefix:prefix,loading:loading,unavailable:unavailable}
}
