import { randomUUID } from 'node:crypto';

const sqlName = value => `[${String(value).replaceAll(']', ']]')}]`;
const sqlString = value => `N'${String(value).replaceAll("'", "''")}'`;
const commentText = value => String(value).replace(/[\x00-\x1f\x7f]/g, ' ');
const objectKey = object => JSON.stringify([object.schema, object.name]);
const columnKey = column => column.name;

function columnType(column) {
  const name = String(column.typeName || '').toLowerCase();
  if (!name || column.isUserDefined || column.xmlCollectionId) return null;
  let size = '';
  if (['varchar', 'char', 'varbinary', 'binary', 'nvarchar', 'nchar'].includes(name)) {
    const bytes = Number(column.maxLength);
    size = bytes === -1 ? '(max)' : `(${['nvarchar', 'nchar'].includes(name) ? bytes / 2 : bytes})`;
  } else if (['decimal', 'numeric'].includes(name)) {
    size = `(${Number(column.precision)},${Number(column.scale)})`;
  } else if (['datetime2', 'datetimeoffset', 'time'].includes(name)) {
    size = `(${Number(column.scale)})`;
  }
  return `${sqlName(name)}${size}`;
}

function columnSignature(column) {
  return JSON.stringify([
    columnType(column), column.typeSchema || '', column.typeName || '',
    column.maxLength, column.precision, column.scale, !!column.isUserDefined,
    column.xmlCollectionId || 0, !!column.nullable, column.collation || '',
    column.defaultDefinition || '', column.computedDefinition || '',
    !!column.persisted, !!column.filestream, column.generatedAlwaysType || 0,
    column.encryptionType || 0, !!column.identityNotForReplication,
    !!column.identity, String(column.identitySeed ?? ''), String(column.identityIncrement ?? ''),
    !!column.sparse, !!column.rowguidcol
  ]);
}

function viewSignature(definition) {
  return String(definition || '').replace(/\r\n?/g, '\n').trim()
    .replace(/^(?:CREATE\s+OR\s+ALTER|CREATE|ALTER)(\s+VIEW\b)/i, 'CREATE$1');
}

export function compareCatalogs(source, target, selectedSchemas, selectedObjects) {
  if (!Array.isArray(selectedSchemas) || !Array.isArray(selectedObjects)) throw new Error('Invalid schema diff selection.');
  const availableSchemas = new Set(source.schemas.map(schema => schema.name));
  const schemas = new Set(selectedSchemas);
  if (schemas.size !== selectedSchemas.length || [...schemas].some(schema => !availableSchemas.has(schema))) {
    throw new Error('Invalid schema diff selection.');
  }
  const sourceMap = new Map(source.objects.map(object => [objectKey(object), object]));
  const selected = new Map();
  for (const key of selectedObjects) {
    if (typeof key !== 'string' || selected.has(key)) throw new Error('Invalid schema diff selection.');
    const object = sourceMap.get(key);
    if (!object || !schemas.has(object.schema)) throw new Error('Invalid schema diff selection.');
    selected.set(key, object);
  }
  const targetMap = new Map(target.objects.map(object => [objectKey(object), object]));
  const targetOnly = target.objects.filter(object => schemas.has(object.schema) && !sourceMap.has(objectKey(object)))
    .map(({ schema, name, type }) => ({ schema, name, type }));
  return {
    schemas: [...schemas], selected: [...selected.values()], targetMap, targetOnly,
    missingSchemas: [...schemas].filter(schema => !target.schemas.some(item => item.name === schema))
  };
}

export function compareDefinitions({ sourceCatalog, targetCatalog, sourceDetails, targetDetails, selectedSchemas, selectedObjects }) {
  const selection = compareCatalogs(sourceCatalog, targetCatalog, selectedSchemas, selectedObjects);
  const changes = [];
  let unchanged = 0;
  for (const source of selection.selected) {
    const key = objectKey(source);
    const target = selection.targetMap.get(key);
    const sourceDetail = sourceDetails[key];
    const targetDetail = target && targetDetails[key];
    if (!sourceDetail || (target && !targetDetail)) throw new Error('Could not read selected schema definitions.');
    const entry = { schema: source.schema, name: source.name, type: source.type, source: sourceDetail, target: targetDetail || null, status: 'same', notes: [] };
    if (!target) entry.status = 'create';
    else if (target.type !== source.type) {
      entry.status = 'manual';
      entry.notes.push('Target object has a different type.');
    } else if (source.type === 'view') {
      if (!sourceDetail.definition || !targetDetail.definition) {
        entry.status = 'manual';
        entry.notes.push('View definition is unavailable.');
      } else if (viewSignature(sourceDetail.definition) !== viewSignature(targetDetail.definition)) entry.status = 'alter';
    } else {
      const sourceColumns = new Map(sourceDetail.columns.map(column => [columnKey(column), column]));
      const targetColumns = new Map(targetDetail.columns.map(column => [columnKey(column), column]));
      entry.columns = [];
      for (const column of sourceDetail.columns) {
        const existing = targetColumns.get(column.name);
        if (!existing) entry.columns.push({ name: column.name, action: 'add', source: column });
        else if (columnSignature(column) !== columnSignature(existing)) {
          entry.columns.push({ name: column.name, action: 'alter', source: column, target: existing });
        }
      }
      for (const column of targetDetail.columns) {
        if (!sourceColumns.has(column.name)) entry.columns.push({ name: column.name, action: 'target-only', target: column });
      }
      if (entry.columns.some(change => change.action === 'target-only')) entry.notes.push('Target-only columns are left unchanged.');
      if (entry.columns.length > 0) entry.status = 'alter';
    }
    if (entry.status === 'same') unchanged++;
    else changes.push(entry);
  }
  return { id: randomUUID(), changes, unchanged, targetOnly: selection.targetOnly,
    missingSchemas: selection.missingSchemas, selectedCount: selection.selected.length };
}

function renderColumn(column) {
  const type = columnType(column);
  if (!type || column.filestream || column.generatedAlwaysType || column.encryptionType ||
      (column.defaultDefinition && !column.defaultName)) return null;
  if (column.computedDefinition) {
    return `${sqlName(column.name)} AS ${column.computedDefinition}${column.persisted ? ' PERSISTED' : ''}`;
  }
  let ddl = `${sqlName(column.name)} ${type}`;
  if (column.collation) {
    if (!/^[A-Za-z0-9_]+$/.test(column.collation)) return null;
    ddl += ` COLLATE ${column.collation}`;
  }
  if (column.identity) ddl += ` IDENTITY(${column.identitySeed},${column.identityIncrement})${column.identityNotForReplication ? ' NOT FOR REPLICATION' : ''}`;
  if (column.rowguidcol) ddl += ' ROWGUIDCOL';
  if (column.sparse) ddl += ' SPARSE';
  ddl += column.nullable ? ' NULL' : ' NOT NULL';
  if (column.defaultDefinition) ddl += ` CONSTRAINT ${sqlName(column.defaultName)} DEFAULT ${column.defaultDefinition}`;
  return ddl;
}

function renderIndex(index, tableName) {
  if (!['CLUSTERED', 'NONCLUSTERED'].includes(index.type) || index.disabled || index.partitioned ||
      index.hypothetical || (index.hasFilter && !index.filterDefinition) || !index.keys?.length) return null;
  const keys = index.keys.map(column => `${sqlName(column.name)} ${column.descending ? 'DESC' : 'ASC'}`).join(', ');
  if (index.constraintName) {
    const kind = index.primaryKey ? 'PRIMARY KEY' : 'UNIQUE';
    return `CONSTRAINT ${sqlName(index.constraintName)} ${kind} ${index.type} (${keys})`;
  }
  let ddl = `CREATE ${index.unique ? 'UNIQUE ' : ''}${index.type} INDEX ${sqlName(index.name)} ON ${tableName} (${keys})`;
  if (index.includes?.length) ddl += ` INCLUDE (${index.includes.map(sqlName).join(', ')})`;
  if (index.filterDefinition) ddl += ` WHERE ${index.filterDefinition}`;
  return `${ddl};\nGO`;
}

function tableUnsupported(table) {
  const issues = [];
  if (table.properties?.temporal || table.properties?.memoryOptimized || table.properties?.fileTable || table.properties?.partitioned || table.properties?.compressed || table.properties?.hasTriggers) {
    issues.push('Table uses a feature requiring manual scripting (temporal, memory optimized, FileTable, partitioning, compression, or triggers).');
  }
  if (table.columns.some(column => !renderColumn(column))) issues.push('A column type or property could not be scripted.');
  if (table.indexes.some(index => !renderIndex(index, '[table]'))) issues.push('An index type or property could not be scripted.');
  if (table.checks?.some(check => !check.definition || check.disabled || check.notTrusted)) issues.push('A CHECK constraint is unreadable, disabled, or untrusted.');
  if (table.foreignKeys?.some(fk => fk.disabled || fk.notTrusted)) issues.push('A foreign key is disabled or untrusted.');
  return issues;
}

function renderCreateTable(entry, options) {
  const table = { ...entry.source,
    indexes: entry.source.indexes.filter(index => index.constraintName || options.includeIndexes),
    checks: options.includeChecks ? entry.source.checks : [],
    foreignKeys: options.includeForeignKeys ? entry.source.foreignKeys : [] };
  const issues = tableUnsupported(table);
  if (issues.length) return { issues, statements: [], foreignKeys: [] };
  const fullName = `${sqlName(entry.schema)}.${sqlName(entry.name)}`;
  const lines = table.columns.map(column => `    ${renderColumn(column)}`);
  for (const index of table.indexes.filter(item => item.constraintName)) lines.push(`    ${renderIndex(index, fullName)}`);
  for (const check of table.checks || []) lines.push(`    CONSTRAINT ${sqlName(check.name)} CHECK ${check.definition}`);
  const statements = [`CREATE TABLE ${fullName} (\n${lines.join(',\n')}\n);\nGO`];
  for (const index of table.indexes.filter(item => !item.constraintName)) statements.push(renderIndex(index, fullName));
  const foreignKeys = (table.foreignKeys || []).map(fk => ({ tableName: fullName, fk }));
  return { issues: [], statements, foreignKeys };
}

// Reuse the full table renderer for editor scripts, without diff headers or
// target-database checks. Dependencies must already exist at the destination.
export function sqlServerCreateScript(schema, name, definition) {
  if (!definition?.columns?.length) throw new Error('Could not read the complete CREATE TABLE definition. Check metadata permissions.');
  const result = renderCreateTable({schema, name, source: definition}, schemaDiffOptions());
  if (result.issues.length) throw new Error('Could not generate complete CREATE: ' + result.issues.join(' '));
  for (const {tableName, fk} of result.foreignKeys) {
    let ddl = `ALTER TABLE ${tableName} WITH CHECK ADD CONSTRAINT ${sqlName(fk.name)} FOREIGN KEY (${fk.columns.map(sqlName).join(', ')}) REFERENCES ${sqlName(fk.referencedSchema)}.${sqlName(fk.referencedTable)} (${fk.referencedColumns.map(sqlName).join(', ')})`;
    if (fk.deleteAction && fk.deleteAction !== 'NO_ACTION') ddl += ` ON DELETE ${fk.deleteAction.replaceAll('_', ' ')}`;
    if (fk.updateAction && fk.updateAction !== 'NO_ACTION') ddl += ` ON UPDATE ${fk.updateAction.replaceAll('_', ' ')}`;
    result.statements.push(ddl + ';\nGO');
  }
  return result.statements.join('\n\n');
}

function canAlterColumn(source, target, table) {
  if (source.computedDefinition || target.computedDefinition || source.identity || target.identity ||
      source.isUserDefined || target.isUserDefined || source.defaultDefinition !== target.defaultDefinition ||
      source.collation !== target.collation || source.sparse !== target.sparse || source.rowguidcol !== target.rowguidcol) return false;
  if (table.indexes.some(index => [...index.keys, ...index.includes.map(name => ({ name }))].some(item => item.name === source.name))) return false;
  if (table.foreignKeys?.some(fk => fk.columns.includes(source.name))) return false;
  if (table.incomingForeignKeys?.some(fk => fk.referencedColumns.includes(source.name))) return false;
  if (table.checks?.length) return false;
  if (table.schemaBoundDependencies?.some(dep => !dep.columnName || dep.columnName === source.name)) return false;
  const sourceType = columnType(source);
  const targetType = columnType(target);
  if (!sourceType || !targetType || !renderColumn(source)) return false;
  if (sourceType !== targetType) {
    const type = String(source.typeName).toLowerCase();
    if (type !== String(target.typeName).toLowerCase() || !['varchar', 'nvarchar', 'varbinary', 'char', 'nchar', 'binary'].includes(type)) return false;
    if (Number(source.maxLength) < Number(target.maxLength) || Number(source.maxLength) === -1 || Number(target.maxLength) === -1) return false;
  }
  if (target.nullable && !source.nullable) return false;
  return true;
}

function renderAlterTable(entry) {
  const fullName = `${sqlName(entry.schema)}.${sqlName(entry.name)}`;
  const statements = [];
  const issues = [];
  for (const change of entry.columns || []) {
    if (change.action === 'target-only') continue;
    const source = change.source;
    if (change.action === 'add') {
      const column = renderColumn(source);
      if (!column || source.identity || (!source.nullable && !source.defaultDefinition && !source.computedDefinition)) {
        issues.push(`Column ${source.name} needs a manual ADD statement.`);
      } else statements.push(`ALTER TABLE ${fullName} ADD ${column}${!source.nullable && source.defaultDefinition ? ' WITH VALUES' : ''};\nGO`);
    } else if (canAlterColumn(source, change.target, entry.target)) {
      const type = columnType(source);
      statements.push(`ALTER TABLE ${fullName} ALTER COLUMN ${sqlName(source.name)} ${type}${source.collation ? ` COLLATE ${source.collation}` : ''} ${source.nullable ? 'NULL' : 'NOT NULL'};\nGO`);
    } else if (entry.target.schemaBoundDependencies?.some(dep => !dep.columnName || dep.columnName === source.name)) {
      issues.push(`Column ${source.name} has a schema-bound dependency; review that dependency before altering the column.`);
    } else issues.push(`Column ${source.name} needs manual review before it can be altered.`);
  }
  return { statements, issues };
}

function renderView(entry) {
  const definition = String(entry.source.definition || '').trim();
  if (entry.target?.indexed || entry.source.indexed) return { issue: 'Indexed views need manual scripting.' };
  const match = definition.match(/^(CREATE(?:\s+OR\s+ALTER)?|ALTER)(\s+VIEW\b)/i);
  if (!match) return { issue: 'View definition could not be converted to CREATE or ALTER VIEW.' };
  const action = entry.status === 'create' ? 'CREATE' : 'ALTER';
  return { statement: `${action}${definition.slice(match[1].length)}\nGO` };
}

export function schemaDiffChangeReview(entry) {
  if (entry.status === 'manual') return entry.notes;
  if (entry.type === 'table') return (entry.status === 'create'
    ? renderCreateTable(entry, schemaDiffOptions()) : renderAlterTable(entry)).issues;
  const view = renderView(entry);
  return view.issue ? [view.issue] : [];
}

export function selectSchemaDiffChanges(comparison, selectedKeys) {
  if (!Array.isArray(selectedKeys) || selectedKeys.length === 0) throw new Error('Select at least one difference to script.');
  const available = new Map(comparison.changes.map(entry => [objectKey(entry), entry]));
  const selected = new Set();
  for (const key of selectedKeys) {
    if (typeof key !== 'string' || selected.has(key) || !available.has(key)) throw new Error('Invalid schema diff selection.');
    selected.add(key);
  }
  const changes = comparison.changes.filter(entry => selected.has(objectKey(entry)));
  const neededSchemas = new Set(changes.filter(entry => entry.status === 'create').map(entry => entry.schema));
  return { ...comparison, changes,
    missingSchemas: comparison.missingSchemas.filter(schema => neededSchemas.has(schema)), targetOnly: [] };
}

function describeColumn(column) {
  if (!column) return '';
  const type = columnType(column) || `${column.typeSchema || ''}.${column.typeName || 'unknown'}`;
  const extra = column.computedDefinition ? ` AS ${column.computedDefinition}` :
    `${column.nullable ? ' NULL' : ' NOT NULL'}${column.identity ? ' IDENTITY' : ''}${column.defaultDefinition ? ` DEFAULT ${column.defaultDefinition}` : ''}`;
  return `${type}${extra}`;
}

function viewLineDifference(source, target) {
  const before = String(target || '').replace(/\r\n?/g, '\n').split('\n');
  const after = String(source || '').replace(/\r\n?/g, '\n').split('\n');
  let first = 0;
  while (first < before.length && first < after.length && before[first] === after[first]) first++;
  let oldEnd = before.length;
  let newEnd = after.length;
  while (oldEnd > first && newEnd > first && before[oldEnd - 1] === after[newEnd - 1]) { oldEnd--; newEnd--; }
  const lines = [];
  if (first) lines.push(`  ${first} unchanged line${first === 1 ? '' : 's'} before`);
  function append(mark, entries) {
    entries.slice(0, 80).forEach(line => lines.push(`${mark} ${line}`));
    if (entries.length > 80) lines.push(`  … ${entries.length - 80} more ${mark === '-' ? 'target' : 'source'} lines; open the full definition`);
  }
  append('-', before.slice(first, oldEnd).filter(line => target || line));
  append('+', after.slice(first, newEnd).filter(line => source || line));
  if (after.length - newEnd) lines.push(`  ${after.length - newEnd} unchanged line${after.length - newEnd === 1 ? '' : 's'} after`);
  return lines.join('\n') || 'No textual change.';
}

export function previewSchemaDiffChange(comparison, key, options) {
  const selected = selectSchemaDiffChanges(comparison, [key]);
  const entry = selected.changes[0];
  const columns = entry.type === 'table'
    ? (entry.status === 'create' ? entry.source.columns.map(column => ({ name: column.name, action: 'add', source: column })) : entry.columns || [])
      .map(change => ({ name: change.name, action: change.action,
        before: describeColumn(change.target), after: describeColumn(change.source) })) : [];
  const script = generateSqlServerScript(selected, options);
  return { schema: entry.schema, name: entry.name, type: entry.type, status: entry.status,
    notes: entry.notes, columns, sourceDefinition: entry.type === 'view' ? entry.source.definition || '' : '',
    targetDefinition: entry.type === 'view' ? entry.target?.definition || '' : '',
    viewDifference: entry.type === 'view' ? viewLineDifference(entry.source.definition, entry.target?.definition) : '',
    sql: script.sql, complete: script.complete, manual: script.manual };
}

export function schemaDiffOptions(input = {}) {
  const defaults = { includeIndexes: true, includeChecks: true, includeForeignKeys: true, refreshDependentViews: true };
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid script options.');
  for (const [key, value] of Object.entries(input)) {
    if (!Object.hasOwn(defaults, key) || typeof value !== 'boolean') throw new Error('Invalid script options.');
  }
  return { ...defaults, ...input };
}

export function generateSqlServerScript(comparison, { sourceName, targetName, sourceDatabase, targetDatabase, targetCatalog, scriptOptions }) {
  const options = schemaDiffOptions(scriptOptions);
  const appliedObjects = new Set();
  const statements = [
    '-- DB Studio schema diff',
    `-- Source: ${commentText(sourceName)} (${commentText(sourceDatabase)})`,
    `-- Target: ${commentText(targetName)} (${commentText(targetDatabase)})`,
    '-- Review this script before running it. DB Studio has not executed any statements.',
    ...Object.entries(options).filter(([, enabled]) => !enabled).map(([key]) => `-- Script option disabled: ${key}`),
    `IF DB_NAME() <> ${sqlString(targetDatabase)} THROW 51000, 'Wrong target database for DB Studio schema diff.', 1;`,
    'GO'
  ];
  const manual = [];
  const deferredFks = [];
  for (const schema of comparison.missingSchemas) {
    statements.push(`IF SCHEMA_ID(${sqlString(schema)}) IS NULL EXEC(${sqlString(`CREATE SCHEMA ${sqlName(schema)}`)});\nGO`);
  }
  const tables = comparison.changes.filter(entry => entry.type === 'table');
  const views = comparison.changes.filter(entry => entry.type === 'view');
  for (const entry of tables) {
    const label = `${entry.schema}.${entry.name}`;
    if (entry.status === 'manual') { manual.push(`${label}: ${entry.notes.join(' ')}`); continue; }
    const result = entry.status === 'create' ? renderCreateTable(entry, options) : renderAlterTable(entry);
    statements.push(...result.statements);
    if (result.statements.length) appliedObjects.add(objectKey(entry));
    deferredFks.push(...(result.foreignKeys || []));
    for (const issue of result.issues) manual.push(`${label}: ${issue}`);
    for (const column of (entry.columns || []).filter(item => item.action === 'target-only')) {
      statements.push(`-- Target-only column left unchanged: ${commentText(label)}.${commentText(column.name)}`);
    }
  }
  const availableTables = new Set(targetCatalog.objects.filter(object => object.type === 'table').map(objectKey));
  for (const entry of tables.filter(item => item.status === 'create' && appliedObjects.has(objectKey(item)))) availableTables.add(objectKey(entry));
  for (const { tableName, fk } of deferredFks) {
    if (!availableTables.has(JSON.stringify([fk.referencedSchema, fk.referencedTable]))) {
      manual.push(`${tableName}: foreign key ${fk.name} references a table absent from the target and this script.`);
      continue;
    }
    const refs = fk.columns.map(sqlName).join(', ');
    const targets = fk.referencedColumns.map(sqlName).join(', ');
    let ddl = `ALTER TABLE ${tableName} WITH CHECK ADD CONSTRAINT ${sqlName(fk.name)} FOREIGN KEY (${refs}) REFERENCES ${sqlName(fk.referencedSchema)}.${sqlName(fk.referencedTable)} (${targets})`;
    if (fk.deleteAction && fk.deleteAction !== 'NO_ACTION') ddl += ` ON DELETE ${fk.deleteAction.replaceAll('_', ' ')}`;
    if (fk.updateAction && fk.updateAction !== 'NO_ACTION') ddl += ` ON UPDATE ${fk.updateAction.replaceAll('_', ' ')}`;
    statements.push(`${ddl};\nGO`);
  }
  const availableObjects = new Set(targetCatalog.objects.map(objectKey));
  for (const entry of tables.filter(item => item.status === 'create' && appliedObjects.has(objectKey(item)))) availableObjects.add(objectKey(entry));
  // Use one dependency order for definition changes and existing target views.
  // An unchanged SELECT * view may need refreshing before a selected view can
  // refer to a newly added column through it.
  const viewByKey = new Map(targetCatalog.objects.filter(object => object.type === 'view').map(view =>
    [objectKey(view), { ...view, source: view, refreshOnly: true }]));
  for (const view of views) viewByKey.set(objectKey(view), view);
  const refreshedViews = [];
  const affected = new Set(appliedObjects);
  const orderedViews = [];
  const visiting = new Set();
  const visited = new Set();
  const cycles = new Set();
  const stack = [];
  function visitView(entry) {
    const key = objectKey(entry);
    if (visited.has(key)) return;
    if (visiting.has(key)) {
      const start = stack.indexOf(key);
      for (const cyclic of stack.slice(start)) cycles.add(cyclic);
      return;
    }
    visiting.add(key);
    stack.push(key);
    for (const dep of entry.source.dependencies || []) {
      if (dep.referencedDatabase || dep.referencedServer) continue;
      const dependency = viewByKey.get(JSON.stringify([dep.referencedSchema, dep.referencedName]));
      if (dependency) visitView(dependency);
    }
    stack.pop();
    visiting.delete(key);
    visited.add(key);
    orderedViews.push(entry);
  }
  for (const view of viewByKey.values()) visitView(view);
  for (const entry of orderedViews) {
    const label = `${entry.schema}.${entry.name}`;
    if (entry.refreshOnly) {
      const dependsOnChange = (entry.source.dependencies || []).some(dep => !dep.referencedDatabase && !dep.referencedServer &&
        affected.has(JSON.stringify([dep.referencedSchema, dep.referencedName])));
      if (!dependsOnChange) continue;
      affected.add(objectKey(entry));
      if (entry.source.schemaBound) continue;
      if (cycles.has(objectKey(entry))) {
        manual.push(`${label}: circular target view dependency needs manual refresh.`);
      } else if (!options.refreshDependentViews) {
        manual.push(`${label}: dependent view metadata refresh was disabled; run sys.sp_refreshview after reviewing dependencies.`);
      } else {
        statements.push(`-- Refresh dependent target view; preserve its existing definition.\nEXEC sys.sp_refreshview @viewname = ${sqlString(`${sqlName(entry.schema)}.${sqlName(entry.name)}`)};\nGO`);
        refreshedViews.push({ schema: entry.schema, name: entry.name });
      }
      continue;
    }
    if (entry.status === 'manual') { manual.push(`${label}: ${entry.notes.join(' ')}`); continue; }
    if (cycles.has(objectKey(entry))) { manual.push(`${label}: circular view dependency needs manual ordering.`); continue; }
    const missingDependency = (entry.source.dependencies || []).find(dep =>
      dep.referencedDatabase || dep.referencedServer || dep.unresolved ||
      (dep.referencedType && !availableObjects.has(JSON.stringify([dep.referencedSchema, dep.referencedName]))));
    if (missingDependency) { manual.push(`${label}: view references another database or an object absent from the target and this script.`); continue; }
    const result = renderView(entry);
    if (result.issue) manual.push(`${label}: ${result.issue}`);
    else {
      statements.push(result.statement);
      appliedObjects.add(objectKey(entry));
      affected.add(objectKey(entry));
      availableObjects.add(objectKey(entry));
    }
  }
  if (comparison.targetOnly.length) {
    statements.push('-- Present only in the target; left unchanged:');
    statements.push(...comparison.targetOnly.map(item => `-- ${commentText(item.type)}: ${commentText(item.schema)}.${commentText(item.name)}`));
  }
  if (manual.length) {
    statements.push('-- MANUAL CHANGES REQUIRED. This script is incomplete:');
    statements.push(...manual.map(issue => `-- ${commentText(issue)}`));
  }
  return { sql: statements.filter(Boolean).join('\n\n') + '\n', complete: manual.length === 0, manual, refreshedViews };
}

export { objectKey };
