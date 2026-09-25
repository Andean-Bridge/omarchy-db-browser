#!/usr/bin/env node
import readline from 'node:readline';
import { createReadStream, writeSync } from 'node:fs';
import { ProfileStore } from './profiles.mjs';
import { boundedNumber, databaseName, identifier, openDatabase, openSwitchedDatabase, tableReadError } from './drivers.mjs';
import { SettingsStore, resultLimit } from './settings.mjs';

if (Number(process.versions.node.split('.')[0]) < 20) {
  process.stderr.write('DB Studio requires Node.js 20 or newer.\n');
  process.exit(1);
}

const profiles = new ProfileStore();
const settings = new SettingsStore();
const connections = new Map();
const running = new Map();

function respond(id, ok, value) {
  const body = ok ? { id, ok: true, data: value } : { id, ok: false, error: value };
  writeSync(1, JSON.stringify(body) + '\n');
}

function safeError(error) {
  const message = typeof error?.message === 'string' ? error.message : '';
  const safe = /^(Connection |Invalid |Select |Enter |Put |Port |Password |The connection |The database |The SQL Server |The old |Saved connection |Secure keyring |Could not |SQL Server driver |PostgreSQL driver |MySQL driver |Query failed|Query cancelled|Query timed out|Unsupported |Limit |Offset |Timeout |Settings |Connection name|Host |Database |User |The previously saved)/;
  return safe.test(message) ? message : 'Operation failed. Check the connection and try again.';
}

function requireConnection(id) {
  const connection = connections.get(id);
  if (!connection) throw new Error('Connection is closed.');
  return connection;
}

function publicConnection(connection) {
  return {
    connectionId: connection.id,
    profile: { ...connection.meta, database: connection.profile.database }
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
    : connection.profile.type === 'postgres' ? 'public' : 'dbo';
}

async function handle(id, action, payload) {
  switch (action) {
    case 'settings.get': return settings.get();
    case 'settings.save': return settings.save(payload);
    case 'profiles.list': return { profiles: await profiles.list() };
    case 'profiles.save': return profiles.save(payload);
    case 'profiles.duplicate': return profiles.duplicate(payload.profileId);
    case 'profiles.delete': return profiles.delete(payload.profileId);
    case 'connection.open': {
      const { meta, profile, password } = await profiles.credentials(payload.profileId, payload);
      const opened = await openDatabase({ ...profile, id: meta.id }, password);
      const connection = { ...opened, password, meta };
      connections.set(connection.id, connection);
      return publicConnection(connection);
    }
    case 'connection.close': {
      const connection = requireConnection(payload.connectionId);
      cancelConnectionTasks(connection.id);
      connections.delete(connection.id);
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
    case 'table.rows': {
      const connection = requireConnection(payload.connectionId);
      const schema = schemaFor(connection, payload.schema);
      const name = identifier(payload.name, 'table name');
      const limit = resultLimit(payload.limit, (await settings.get()).defaultLimit);
      const offset = boundedNumber(payload.offset, 0, 0, 10000000, 'Offset');
      try { return await connection.adapter.rows(schema, name, limit, offset); }
      catch (error) { throw tableReadError(error, connection.profile.type, 'data', connection.password); }
    }
    case 'query.run': {
      const connection = requireConnection(payload.connectionId);
      if (typeof payload.sql !== 'string' || !payload.sql.trim() || payload.sql.length > 200000) {
        throw new Error('Enter a SQL query under 200 KB.');
      }
      const limit = resultLimit(payload.limit, (await settings.get()).defaultLimit);
      const timeoutMs = boundedNumber(payload.timeoutMs, 30000, 1000, 120000, 'Timeout');
      const task = { connectionId: connection.id, cancel: null, cancelRequested: false };
      running.set(id, task);
      const start = Date.now();
      try {
        const result = await connection.adapter.run(payload.sql, limit, timeoutMs, cancel => {
          task.cancel = cancel;
          if (task.cancelRequested) cancel();
        });
        return { ...result, durationMs: Date.now() - start };
      } finally {
        running.delete(id);
      }
    }
    case 'query.cancel': {
      const targetId = payload.targetId;
      if (!Number.isSafeInteger(targetId)) throw new Error('Invalid query ID.');
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
    respond(null, false, 'Invalid request.');
    return;
  }
  const payload = request.payload && typeof request.payload === 'object' && !Array.isArray(request.payload)
    ? request.payload : {};
  handle(request.id, request.action, payload)
    .then(result => respond(request.id, true, result))
    .catch(error => respond(request.id, false, safeError(error)));
});

async function shutdown() {
  for (const task of running.values()) task.cancel?.();
  await Promise.allSettled([...connections.values()].map(connection => connection.adapter.close()));
}
lines.on('close', () => { void shutdown(); });
