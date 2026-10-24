#!/usr/bin/env node
import readline from 'node:readline';
import { createReadStream } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { ProfileStore } from './profiles.mjs';
import { CellValueStore } from './cell-values.mjs';
import { RowEditStore, planRowUpdate } from './row-edit.mjs';
import { tableReadPlan } from './table-read.mjs';
import { exportTable } from './table-export.mjs';
import { generateTableScript } from './table-scripts.mjs';
import { readSqlFile, saveSqlFile } from './sql-files.mjs';
import { isLoopbackHost } from './connection-string.mjs';
import { queryError, boundedNumber, databaseName, identifier, openDatabase, openSwitchedDatabase, tableReadError } from './drivers.mjs';
import { createLineWriter } from './protocol.mjs';
import { SettingsStore, resultLimit } from './settings.mjs';
import { aiAvailability, generateAiQuery } from './ai.mjs';
import { compareCatalogs, compareDefinitions, generateSqlServerScript, objectKey, previewSchemaDiffChange, selectSchemaDiffChanges, schemaDiffOptions, schemaDiffChangeReview } from './schema-diff.mjs';

if (Number(process.versions.node.split('.')[0]) < 20) {
  process.stderr.write('DB Studio requires Node.js 20 or newer.\n');
  process.exit(1);
}

const profiles = new ProfileStore();
const settings = new SettingsStore();
const connections = new Map();
let shuttingDown = false;
const running = new Map();
const cellValues = new CellValueStore();
const rowEdits = new RowEditStore();
const diffComparisons = new Map();
const writeLine = createLineWriter();

function respond(id, ok, value) {
  const body = ok ? { id, ok: true, data: value } : { id, ok: false, error: value };
  let line;
  try { line = JSON.stringify(body); }
  catch { line = JSON.stringify({ id, ok: false, error: 'Operation failed. Check the connection and try again.' }); }
  return writeLine(line);
}

function outputFailure() {
  process.stderr.write('DB Studio could not write a worker response.\n');
  process.exit(1);
}

function safeError(error) {
  const message = typeof error?.message === 'string' ? error.message : '';
  const safe = /^(AI |Cell value |Connection |Invalid |Select |Choose |Generate |Schema diff |Enter |Put |Port |Password |The connection |The database |The SQL Server |The old |Saved connection |Secure keyring |Could not |SQL Server driver |PostgreSQL driver |MySQL driver |Query failed|Query cancelled|Query timed out|Unsupported |SQL files |Limit |Offset |Timeout |Settings |Connection name|Host |Database |User |Cloudflare |The previously saved)/;
  return safe.test(message) ? message : 'Operation failed. Check the connection and try again.';
}

function requireConnection(id) {
  const connection = connections.get(id);
  if (!connection) throw new Error('Connection is closed.');
  return connection;
}

function publicConnection(connection) {
  const { type, host, ssl, encrypt } = connection.profile;
  return {
    connectionId: connection.id,
    profile: {
      ...connection.meta,
      database: connection.profile.database,
      transportSecure: type === 'cloudflare_d1' || (type === 'postgres' || type === 'mysql' ? Boolean(ssl) : Boolean(encrypt)),
      localConnection: isLoopbackHost(host)
    }
  };
}

function cancelConnectionTasks(connectionId) {
  for (const task of running.values()) {
    if (task.connectionId === connectionId) {
      task.cancelRequested = true;
      task.cancel?.();
    }
  }
}

function schemaFor(connection, schema) {
  if (schema) return identifier(schema, 'schema');
  return connection.profile.type === 'mysql' ? connection.profile.database
    : connection.profile.type === 'postgres' ? 'public' : connection.profile.type === 'cloudflare_d1' ? 'main' : 'dbo';
}

async function withDiffConnections(sourceProfileId, targetProfileId, callback) {
  if (!sourceProfileId || !targetProfileId || sourceProfileId === targetProfileId) {
    throw new Error('Select two different SQL Server connections.');
  }
  let source;
  let target;
  try {
    const sourceCredentials = await profiles.credentials(sourceProfileId);
    const targetCredentials = await profiles.credentials(targetProfileId);
    const supported = new Set(['sqlserver', 'azure_sql']);
    if (!supported.has(sourceCredentials.profile.type) || !supported.has(targetCredentials.profile.type)) {
      throw new Error('Schema diff supports SQL Server and Azure SQL connections.');
    }
    source = await openDatabase({ ...sourceCredentials.profile, id: sourceProfileId }, sourceCredentials.password);
    target = await openDatabase({ ...targetCredentials.profile, id: targetProfileId }, targetCredentials.password);
    return await callback({ source, target, sourceName: sourceCredentials.meta.name, targetName: targetCredentials.meta.name });
  } finally {
    await Promise.allSettled([source?.adapter?.close(), target?.adapter?.close()].filter(Boolean));
  }
}

async function handle(id, action, payload) {
  switch (action) {
    case 'sql.open': return readSqlFile(payload.filePath);
    case 'sql.save': return saveSqlFile(payload.filePath, payload.sql, { expectedRevision: payload.revision, overwrite: payload.overwrite === true });
    case 'settings.get': return settings.get();
    case 'ai.status': return aiAvailability().catch(() => ({ available: false, agent: '' }));
    case 'settings.save': return settings.save(payload);
    case 'profiles.list': return { profiles: await profiles.list() };
    case 'profiles.save': return profiles.save(payload);
    case 'profiles.duplicate': return profiles.duplicate(payload.profileId);
    case 'profiles.delete': return profiles.delete(payload.profileId);
    case 'schemaDiff.catalog': return withDiffConnections(payload.sourceProfileId, payload.targetProfileId,
      async ({ source, target, sourceName, targetName }) => {
        const [sourceCatalog, targetCatalog] = await Promise.all([
          source.adapter.diffCatalog(), target.adapter.diffCatalog()
        ]);
        const publicCatalog = (catalog, sourceSide) => ({ schemas: sourceSide
          ? catalog.schemas.filter(schema => catalog.objects.some(object => object.schema === schema.name))
          : catalog.schemas,
          objects: catalog.objects.map(({ schema, name, type }) => ({ schema, name, type })) });
        return { source: publicCatalog(sourceCatalog, true), target: publicCatalog(targetCatalog, false),
          sourceName, targetName, sourceDatabase: source.profile.database, targetDatabase: target.profile.database };
      });
    case 'schemaDiff.compare': return withDiffConnections(payload.sourceProfileId, payload.targetProfileId,
      async ({ source, target, sourceName, targetName }) => {
        const [sourceCatalog, targetCatalog] = await Promise.all([
          source.adapter.diffCatalog(), target.adapter.diffCatalog()
        ]);
        const selection = compareCatalogs(sourceCatalog, targetCatalog,
          payload.selectedSchemas, payload.selectedObjects);
        if (!selection.selected.length) throw new Error('Select at least one object to compare.');
        const targetObjects = selection.selected.map(object => selection.targetMap.get(objectKey(object))).filter(Boolean);
        const [sourceById, targetById] = await Promise.all([
          source.adapter.diffDetails(selection.selected), target.adapter.diffDetails(targetObjects)
        ]);
        const keyed = (objects, details) => Object.fromEntries(objects.map(object => [objectKey(object), details[object.objectId]]));
        const comparison = compareDefinitions({ sourceCatalog, targetCatalog,
          sourceDetails: keyed(selection.selected, sourceById), targetDetails: keyed(targetObjects, targetById),
          selectedSchemas: payload.selectedSchemas, selectedObjects: payload.selectedObjects });
        diffComparisons.clear();
        diffComparisons.set(comparison.id, { comparison, targetCatalog, sourceName, targetName,
          sourceDatabase: source.profile.database, targetDatabase: target.profile.database, script: null });
        return { comparisonId: comparison.id, selectedCount: comparison.selectedCount,
          unchanged: comparison.unchanged, missingSchemas: comparison.missingSchemas,
          targetOnly: comparison.targetOnly,
          changes: comparison.changes.map(entry => {
            const review = schemaDiffChangeReview(entry);
            return { schema: entry.schema, name: entry.name, type: entry.type, status: entry.status,
              notes: [...entry.notes, ...review.filter(note => !entry.notes.includes(note))],
              reviewRequired: review.length > 0, targetExists: !!entry.target,
              columns: (entry.columns || []).map(({ name, action }) => ({ name, action })) };
          }) };
      });
    case 'schemaDiff.preview': {
      const saved = diffComparisons.get(payload.comparisonId);
      if (!saved) throw new Error('Schema diff expired. Compare again.');
      return previewSchemaDiffChange(saved.comparison, payload.objectKey, { ...saved, scriptOptions: schemaDiffOptions(payload.scriptOptions) });
    }
    case 'schemaDiff.script': {
      const saved = diffComparisons.get(payload.comparisonId);
      if (!saved) throw new Error('Schema diff expired. Compare again.');
      saved.script = generateSqlServerScript(selectSchemaDiffChanges(saved.comparison, payload.selectedKeys), { ...saved, scriptOptions: schemaDiffOptions(payload.scriptOptions) });
      return saved.script;
    }
    case 'schemaDiff.save': {
      const saved = diffComparisons.get(payload.comparisonId);
      if (!saved?.script) throw new Error('Generate the schema diff script before saving it.');
      const filePath = payload.filePath;
      if (typeof filePath !== 'string' || filePath.length > 2048 || !path.isAbsolute(filePath) ||
          path.extname(filePath).toLowerCase() !== '.sql') throw new Error('Choose an absolute .sql file path.');
      try { await writeFile(filePath, saved.script.sql, { mode: 0o600 }); }
      catch { throw new Error('Could not save the schema diff script.'); }
      return { saved: true };
    }
    case 'connection.open':
    case 'agent.connection.open': {
      const agentRequest = action === 'agent.connection.open';
      if (agentRequest && (payload.password !== undefined || payload.connectionString !== undefined)) {
        throw new Error('Invalid agent connection request.');
      }
      const { meta, profile, password } = await profiles.credentials(payload.profileId,
        { ...payload, requireAgentAccess: agentRequest });
      const opened = await openDatabase({ ...profile, id: meta.id }, password);
      if (shuttingDown) {
        await opened.adapter.close().catch(() => {});
        throw new Error('Connection is closed.');
      }
      const connection = { ...opened, password, meta };
      connections.set(connection.id, connection);
      return publicConnection(connection);
    }
    case 'connection.close': {
      const connection = requireConnection(payload.connectionId);
      cancelConnectionTasks(connection.id);
      connections.delete(connection.id);
      cellValues.clearConnection(connection.id);
      rowEdits.clearConnection(connection.id);
      await connection.adapter.close();
      return { closed: true };
    }
    case 'databases.list': {
      const connection = requireConnection(payload.connectionId);
      if (!connection.adapter.databases) {
        throw new Error('Database switching is supported for SQL Server and Azure SQL.');
      }
      return connection.adapter.databases();
    }
    case 'connection.switchDatabase': {
      const previous = requireConnection(payload.connectionId);
      if (!['azure_sql', 'sqlserver'].includes(previous.profile.type)) {
        throw new Error('Database switching is supported for SQL Server and Azure SQL.');
      }
      const database = databaseName(payload.database);
      if (previous.profile.database === database) return { ...publicConnection(previous), unchanged: true };
      const replacement = await openSwitchedDatabase(previous, database);
      // A close or another switch may have completed while the new pool opened.
      if (connections.get(previous.id) !== previous) {
        await replacement.adapter.close().catch(() => {});
        throw new Error('Connection is closed.');
      }
      connections.set(replacement.id, replacement);
      connections.delete(previous.id);
      cancelConnectionTasks(previous.id);
      cellValues.clearConnection(previous.id);
      rowEdits.clearConnection(previous.id);
      await previous.adapter.close().catch(() => {});
      return publicConnection(replacement);
    }
    case 'schemas.list': {
      const connection = requireConnection(payload.connectionId);
      try { return { schemas: await connection.adapter.schemas() }; }
      catch { throw new Error('Could not load schemas.'); }
    }
    case 'objects.list': {
      const connection = requireConnection(payload.connectionId);
      const schema = payload.schema ? identifier(payload.schema, 'schema') : undefined;
      try { return { objects: await connection.adapter.objects(schema) }; }
      catch { throw new Error('Could not load tables and views.'); }
    }
    case 'table.describe': {
      const connection = requireConnection(payload.connectionId);
      const schema = schemaFor(connection, payload.schema);
      const name = identifier(payload.name, 'table name');
      try { return await connection.adapter.describe(schema, name); }
      catch (error) { throw tableReadError(error, connection.profile.type, 'definition', connection.password); }
    }
    case 'table.script': {
      const connection = requireConnection(payload.connectionId);
      const schema = schemaFor(connection, payload.schema);
      const name = identifier(payload.name, 'table name');
      try { return await generateTableScript(connection.adapter, connection.profile.type, schema, name, payload.script); }
      catch (error) { throw queryError(error, '', connection.password); }
    }
    case 'table.rows': {
      const connection = requireConnection(payload.connectionId);
      const schema = schemaFor(connection, payload.schema);
      const name = identifier(payload.name, 'table name');
      const offset = boundedNumber(payload.offset, 0, 0, 10000000, 'Offset');
      const task = { connectionId: connection.id, cancel: null, cancelRequested: false };
      const cellBatch = cellValues.begin(connection.id);
      const editBatch = rowEdits.beginPage(connection.id, schema, name);
      cellBatch.captureRow = connection.adapter.updateCell ? editBatch.captureRow : undefined;
      running.set(id, task);
      try {
        const limit = resultLimit(payload.limit, (await settings.get()).defaultLimit);
        let definition;
        try { definition = await connection.adapter.describe(schema, name); }
        catch (error) {
          if (payload.sort != null || payload.filter != null) throw new Error('Could not load the column details needed to sort or filter this table.');
        }
        if (task.cancelRequested) throw new Error('Query cancelled.');
        const plan = tableReadPlan(connection.profile.type, schema, name, definition, { limit, offset, sort: payload.sort, filter: payload.filter });
        const result = await connection.adapter.rows(schema, name, limit, offset, cancel => {
          task.cancel = cancel;
          if (task.cancelRequested) cancel();
        }, cellBatch, plan);
        if (task.cancelRequested) throw new Error('Query cancelled.');
        if (connections.get(connection.id) !== connection || !cellBatch.commit()) throw new Error('Connection is closed.');
        if (!editBatch.commitPage(result.columns)) throw new Error('Connection is closed.');
        return { ...result, editHandles: editBatch.handlesForRows, order: plan.order, stableOrder: plan.stableOrder };
      } catch (error) {
        if (task.cancelRequested) throw new Error('Query cancelled.');
        if (error?.code === 'ROW_TOO_LARGE' || /^(Invalid |Could not load the column)/.test(error?.message || '')) throw error;
        throw tableReadError(error, connection.profile.type, 'data', connection.password);
      } finally {
        cellBatch.discard();
        editBatch.discard();
        running.delete(id);
      }
    }
    case 'table.export': {
      const connection = requireConnection(payload.connectionId);
      const schema = schemaFor(connection, payload.schema);
      const name = identifier(payload.name, 'table name');
      const task = { connectionId: connection.id, cancel: null, cancelRequested: false };
      running.set(id, task);
      try {
        const definition = await connection.adapter.describe(schema, name);
        const checkCancelled = () => {
          if (task.cancelRequested) throw new Error('Query cancelled.');
          if (connections.get(connection.id) !== connection) throw new Error('Connection is closed.');
        };
        checkCancelled();
        const timeoutMs = boundedNumber(payload.timeoutMs, 30000, 1000, 1000000, 'Timeout');
        return await exportTable({ adapter: connection.adapter, type: connection.profile.type, schema, name, definition,
          format: payload.format, columns: payload.columns, filter: payload.filter, sort: payload.sort,
          filePath: payload.filePath, overwrite: payload.overwrite === true, timeoutMs, checkCancelled,
          onReady: cancel => { task.cancel = cancel; if (task.cancelRequested) cancel(); } });
      } catch (error) {
        if (task.cancelRequested) throw new Error('Query cancelled.');
        throw error;
      } finally { running.delete(id); }
    }
    case 'table.updateRow':
    case 'table.updateCell': {
      const connection = requireConnection(payload.connectionId);
      if (!connection.adapter.updateCell) throw new Error('Could not edit row: use SQL to change values in this database.');
      let snapshot;
      try { snapshot = rowEdits.snapshot(connection.id, payload.handle); }
      catch (error) { throw new Error('Could not edit row: ' + error.message); }
      const { schema, name } = snapshot;
      const capturedColumns = snapshot.columns;
      const changes = action === 'table.updateCell' ? [{ column: identifier(payload.column, 'column'), value: payload.value }] : payload.changes;
      // Consume the snapshot before awaiting anything so duplicate saves cannot
      // race. Failed edits require a refresh rather than a blind retry.
      rowEdits.remove(payload.handle);
      try {
        const objects = await connection.adapter.objects(schema);
        if (!objects.some(object => object.name === name && object.type === 'table')) throw new Error('Only base tables can be edited.');
        const definition = await connection.adapter.describe(schema, name);
        // Column order is supplied by the captured table read, never by the UI.
        if (!capturedColumns) throw new Error('Refresh the table before editing.');
        const plan = planRowUpdate(connection.profile.type, schema, name, definition, capturedColumns, snapshot, changes);
        if (connections.get(connection.id) !== connection) throw new Error('Connection is closed.');
        return await connection.adapter.updateCell(plan, schema, name);
      } catch (error) {
        throw new Error(queryError(error, '', connection.password).message);
      }
    }
    case 'query.run': {
      const connection = requireConnection(payload.connectionId);
      if (typeof payload.sql !== 'string' || !payload.sql.trim() || payload.sql.length > 200000) {
        throw new Error('Enter a SQL query under 200 KB.');
      }
      const limit = resultLimit(payload.limit, (await settings.get()).defaultLimit);
      const timeoutMs = boundedNumber(payload.timeoutMs, 30000, 1000, 1000000, 'Timeout');
      if (connections.get(connection.id) !== connection) throw new Error('Connection is closed.');
      const task = { connectionId: connection.id, cancel: null, cancelRequested: false };
      const cellBatch = cellValues.begin(connection.id);
      running.set(id, task);
      const start = Date.now();
      try {
        const result = await connection.adapter.run(payload.sql, limit, timeoutMs, cancel => {
          task.cancel = cancel;
          if (task.cancelRequested) cancel();
        }, cellBatch);
        if (task.cancelRequested) throw new Error('Query cancelled.');
        if (connections.get(connection.id) !== connection || !cellBatch.commit()) throw new Error('Connection is closed.');
        return { ...result, durationMs: Date.now() - start };
      } finally {
        cellBatch.discard();
        running.delete(id);
      }
    }
    case 'ai.generate': {
      const connection = requireConnection(payload.connectionId);
      const controller = new AbortController();
      const task = { kind: 'ai', connectionId: connection.id, cancelRequested: false,
        cancel: () => controller.abort() };
      running.set(id, task);
      try {
        const result = await generateAiQuery({
          connection,
          instruction: payload.instruction,
          sql: payload.sql,
          error: payload.error,
          selected: payload.selected,
          signal: controller.signal
        });
        if (task.cancelRequested || connections.get(connection.id) !== connection) {
          throw new Error('AI request cancelled.');
        }
        return result;
      } finally {
        running.delete(id);
      }
    }
    case 'ai.cancel': {
      const targetId = payload.targetId;
      if (!Number.isSafeInteger(targetId)) throw new Error('Invalid operation ID.');
      const task = running.get(targetId);
      if (!task || task.kind !== 'ai') return { cancelled: false };
      task.cancelRequested = true;
      task.cancel();
      return { cancelled: true };
    }
    case 'cell.get': {
      const connection = requireConnection(payload.connectionId);
      const value = cellValues.get(connection.id, payload.handle);
      if (!value) throw new Error('Cell value is no longer available. Refresh the results and try again.');
      return value;
    }
    case 'query.cancel': {
      const targetId = payload.targetId;
      if (!Number.isSafeInteger(targetId)) throw new Error('Invalid operation ID.');
      const task = running.get(targetId);
      if (!task) return { cancelled: false };
      task.cancelRequested = true;
      task.cancel?.();
      return { cancelled: true };
    }
    default: throw new Error('Unsupported action.');
  }
}

const lines = readline.createInterface({ input: createReadStream(null, { fd: 0, autoClose: false }), crlfDelay: Infinity });
lines.on('line', line => {
  let request;
  try {
    if (line.length > 1048576) throw new Error('Request is too large.');
    request = JSON.parse(line);
    if (!request || !Number.isSafeInteger(request.id) || typeof request.action !== 'string') {
      throw new Error('Invalid request.');
    }
  } catch {
    void respond(null, false, 'Invalid request.').catch(outputFailure);
    return;
  }
  const payload = request.payload && typeof request.payload === 'object' && !Array.isArray(request.payload)
    ? request.payload : {};
  handle(request.id, request.action, payload)
    .then(
      result => respond(request.id, true, result),
      error => respond(request.id, false, safeError(error))
    )
    .catch(outputFailure);
});

async function shutdown() {
  shuttingDown = true;
  const opened = [...connections.values()];
  connections.clear();
  for (const task of running.values()) task.cancel?.();
  cellValues.dispose();
  rowEdits.dispose();
  await Promise.allSettled(opened.map(connection => connection.adapter.close()));
}
lines.on('close', () => { void shutdown(); });
