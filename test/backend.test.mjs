import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { normalizeProfile, parseConnectionString } from '../backend/connection-string.mjs';
import { CellValueStore } from '../backend/cell-values.mjs';
import { ProfileStore } from '../backend/profiles.mjs';
import { appendRow, boundedNumber, cell, databaseName, identifier, openSwitchedDatabase, queryError, tableReadError } from '../backend/drivers.mjs';
import { DEFAULT_RESULT_LIMIT, MAX_RESULT_LIMIT, resultLimit, SettingsStore } from '../backend/settings.mjs';
import { createLineWriter } from '../backend/protocol.mjs';

async function fixture() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'db-browser-test-'));
  const secrets = new Map();
  const keyring = {
    async store(id, secret) { secrets.set(id, secret); },
    async lookup(id) { return secrets.get(id) || ''; },
    async clear(id) { secrets.delete(id); }
  };
  const filePath = path.join(root, 'omarchy', 'db-browser', 'connections.json');
  return { root, secrets, keyring, filePath, store: new ProfileStore({ filePath, keyring }) };
}

test('remembered Azure connection is a single keyring secret; metadata contains no connection details', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const connectionString = 'Server=tcp:private.database.windows.net,1433;Database=payroll;User ID=analyst;Password=SuperSecret123;Encrypt=True;TrustServerCertificate=False;';
  const saved = await f.store.save({ profile: { name: 'Work', type: 'azure_sql' }, connectionString, savePassword: true });
  assert.equal(saved.credentialSaved, true);
  assert.equal(saved.profile.hasStoredConnection, true);
  assert.equal(f.secrets.get(saved.profile.id), connectionString);

  const contents = await fs.readFile(f.filePath, 'utf8');
  assert.deepEqual(Object.keys(JSON.parse(contents).profiles[0]).sort(), ['agentAccess', 'id', 'name', 'type']);
  assert.equal(saved.profile.agentAccess, false);
  for (const sensitive of ['private.database.windows.net', 'payroll', 'analyst', 'SuperSecret123', 'Server=', 'Password=']) {
    assert.equal(contents.includes(sensitive), false, `${sensitive} leaked into metadata`);
  }
  assert.equal((await fs.stat(f.filePath)).mode & 0o777, 0o600);
  assert.equal((await fs.stat(path.dirname(f.filePath))).mode & 0o777, 0o700);

  const secondProcess = new ProfileStore({ filePath: f.filePath, keyring: f.keyring });
  assert.deepEqual(await secondProcess.list(), [saved.profile]);
  const credentials = await secondProcess.credentials(saved.profile.id);
  assert.equal(credentials.profile.host, 'private.database.windows.net');
  assert.equal(credentials.profile.database, 'payroll');
  assert.equal(credentials.password, 'SuperSecret123');
  assert.equal(credentials.profile.trustServerCertificate, false);
});

test('form fields become one canonical keyring secret, never public metadata', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const saved = await f.store.save({
    profile: { name: 'Reports', type: 'postgres', host: 'db.internal', port: 5432, database: 'reports', user: 'reader', ssl: true },
    password: 's3cret', savePassword: true
  });
  const secret = f.secrets.get(saved.profile.id);
  assert.match(secret, /^omarchy-db-browser:v1:/);
  assert.match(secret, /db\.internal/);
  assert.match(secret, /s3cret/);
  assert.equal((await fs.readFile(f.filePath, 'utf8')).includes('db.internal'), false);
  const resolved = await f.store.credentials(saved.profile.id);
  assert.equal(resolved.profile.ssl, true);
  assert.equal(resolved.password, 's3cret');
});

test('duplicating a saved connection creates an independent keyring entry and unique names', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const connectionString = 'Server=tcp:private.database.windows.net,1433;Database=payroll;User ID=analyst;Password=SuperSecret123;Encrypt=True;';
  const original = await f.store.save({
    profile: { name: 'Work', type: 'azure_sql' }, connectionString, savePassword: true
  });
  const reopened = new ProfileStore({ filePath: f.filePath, keyring: f.keyring });
  const first = await reopened.duplicate(original.profile.id);
  const second = await reopened.duplicate(original.profile.id);
  assert.notEqual(first.profile.id, original.profile.id);
  assert.notEqual(second.profile.id, first.profile.id);
  assert.equal(first.profile.name, 'Work copy');
  assert.equal(second.profile.name, 'Work copy 2');
  assert.equal(first.credentialSaved, true);
  assert.equal(f.secrets.get(original.profile.id), connectionString);
  assert.equal(f.secrets.get(first.profile.id), connectionString);
  assert.equal(f.secrets.get(second.profile.id), connectionString);
  assert.equal((await reopened.credentials(first.profile.id)).profile.database, 'payroll');
  const metadata = await fs.readFile(f.filePath, 'utf8');
  assert.equal(JSON.parse(metadata).profiles.length, 3);
  assert.equal(metadata.includes('private.database.windows.net'), false);
  assert.equal(metadata.includes('SuperSecret123'), false);

  await reopened.save({
    profile: { id: first.profile.id, name: first.profile.name, type: 'azure_sql' },
    connectionString: connectionString.replace('Database=payroll', 'Database=reports'),
    savePassword: true
  });
  assert.equal(f.secrets.get(original.profile.id), connectionString);
  assert.equal((await reopened.credentials(original.profile.id)).profile.database, 'payroll');
  assert.equal((await reopened.credentials(first.profile.id)).profile.database, 'reports');
});

test('duplicating a session-only connection keeps both copies in memory', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const original = await f.store.save({
    profile: { name: 'Session', type: 'mysql', host: 'localhost', database: 'devdb', user: 'root' },
    password: '', savePassword: false
  });
  const copy = await f.store.duplicate(original.profile.id);
  assert.equal(copy.profile.name, 'Session copy');
  assert.equal(copy.credentialSaved, false);
  assert.equal(copy.profile.hasStoredConnection, false);
  assert.equal((await f.store.credentials(copy.profile.id)).profile.database, 'devdb');
  assert.equal((await f.store.credentials(copy.profile.id)).password, '');
  assert.equal(f.secrets.size, 0);
  assert.deepEqual((await f.store.list()).map(profile => profile.name), ['Session', 'Session copy']);
  await assert.rejects(fs.stat(f.filePath), { code: 'ENOENT' });
});

test('keyring failure while duplicating leaves the original connection unchanged', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const original = await f.store.save({
    profile: { name: 'Work', type: 'postgres', host: 'db.internal', database: 'reports', user: 'reader' },
    password: 'SuperSecret123', savePassword: true
  });
  const originalSecret = f.secrets.get(original.profile.id);
  const failing = new ProfileStore({
    filePath: f.filePath,
    keyring: {
      async lookup(id) { return f.secrets.get(id); },
      async store() { throw new Error('SuperSecret123'); },
      async clear() {}
    }
  });
  await assert.rejects(failing.duplicate(original.profile.id), /Secure keyring is unavailable/);
  assert.deepEqual(await failing.list(), [original.profile]);
  assert.equal(f.secrets.get(original.profile.id), originalSecret);
  assert.equal((await fs.readFile(f.filePath, 'utf8')).includes('SuperSecret123'), false);
});

test('passwordless MySQL form fields connect from the keyring without exposing connection details', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const saved = await f.store.save({
    profile: { name: 'Local MySQL', type: 'mysql', host: 'localhost', database: 'devdb', user: 'root' },
    password: '', savePassword: true
  });
  assert.equal(saved.credentialSaved, true);
  const secret = f.secrets.get(saved.profile.id);
  assert.match(secret, /^omarchy-db-browser:v1:/);
  assert.match(secret, /"password":""/);
  assert.equal((await fs.readFile(f.filePath, 'utf8')).includes('localhost'), false);
  const nextProcess = new ProfileStore({ filePath: f.filePath, keyring: f.keyring });
  const resolved = await nextProcess.credentials(saved.profile.id);
  assert.equal(resolved.profile.type, 'mysql');
  assert.equal(resolved.profile.host, 'localhost');
  assert.equal(resolved.password, '');
});

test('passwordless MySQL URL and semicolon connection string resolve from the keyring', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const inputs = [
    'mysql://root@localhost/devdb',
    'Server=localhost;Port=3306;Database=devdb;Uid=root;Pwd=;SslMode=None;'
  ];
  for (const [index, connectionString] of inputs.entries()) {
    const saved = await f.store.save({
      profile: { name: `MySQL ${index}`, type: 'mysql' }, connectionString, savePassword: true
    });
    assert.equal(f.secrets.get(saved.profile.id), connectionString);
    const resolved = await new ProfileStore({ filePath: f.filePath, keyring: f.keyring }).credentials(saved.profile.id);
    assert.equal(resolved.profile.type, 'mysql');
    assert.equal(resolved.profile.database, 'devdb');
    assert.equal(resolved.profile.user, 'root');
    assert.equal(resolved.password, '');
  }
  assert.equal((await fs.readFile(f.filePath, 'utf8')).includes('localhost'), false);
});

test('SQL Server and PostgreSQL still require a password', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  for (const [type, connectionString] of [
    ['sqlserver', 'Server=localhost;Database=devdb;Uid=root;Pwd=;'],
    ['postgres', 'postgres://root@localhost/devdb']
  ]) {
    const saved = await f.store.save({
      profile: { name: type, type }, connectionString, savePassword: false
    });
    await assert.rejects(f.store.credentials(saved.profile.id), /Enter a password to connect/);
  }
});

test('keyring failure yields an explicit session-only connection and no disk profile', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const failed = new ProfileStore({
    filePath: f.filePath,
    keyring: { async store() { throw new Error('locked'); }, async lookup() { throw new Error('locked'); }, async clear() {} }
  });
  const saved = await failed.save({
    profile: { name: 'Local', type: 'mysql', host: 'localhost', database: 'devdb', user: 'dev' },
    password: 'temporary', savePassword: true
  });
  assert.equal(saved.credentialSaved, false);
  assert.match(saved.warning, /only until DB Studio closes/);
  assert.deepEqual(await failed.list(), [saved.profile]);
  assert.equal((await failed.credentials(saved.profile.id)).password, 'temporary');
  await assert.rejects(fs.stat(f.filePath), { code: 'ENOENT' });
  assert.deepEqual(await new ProfileStore({ filePath: f.filePath, keyring: f.keyring }).list(), []);
});

test('turning Remember off removes keyring entry and profile metadata', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const saved = await f.store.save({
    profile: { name: 'Local', type: 'mysql', host: 'localhost', database: 'devdb', user: 'dev' },
    password: 'temporary', savePassword: true
  });
  const changed = await f.store.save({ profile: { id: saved.profile.id, name: 'Local', type: 'mysql' }, savePassword: false });
  assert.equal(changed.profile.hasStoredConnection, false);
  assert.equal(f.secrets.has(saved.profile.id), false);
  assert.deepEqual(JSON.parse(await fs.readFile(f.filePath, 'utf8')).profiles, []);
  assert.equal((await f.store.credentials(saved.profile.id)).password, 'temporary');
});

test('failed keyring update preserves prior saved connection', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const saved = await f.store.save({
    profile: { name: 'Local', type: 'mysql', host: 'localhost', database: 'devdb', user: 'dev' },
    password: 'original', savePassword: true
  });
  const oldSecret = f.secrets.get(saved.profile.id);
  const failing = new ProfileStore({
    filePath: f.filePath,
    keyring: { async lookup(id) { return f.secrets.get(id); }, async store() { throw new Error('locked'); }, async clear() { throw new Error('locked'); } }
  });
  await assert.rejects(failing.save({
    profile: { id: saved.profile.id, name: 'Renamed', type: 'mysql', host: 'newhost', database: 'devdb', user: 'dev' },
    password: 'new', savePassword: true
  }), /left unchanged/);
  assert.equal(f.secrets.get(saved.profile.id), oldSecret);
  assert.equal((await f.store.list())[0].name, 'Local');
});

test('parser validates Azure TLS and separates credentials from metadata', () => {
  const parsed = parseConnectionString('Server=tcp:server.database.windows.net,1433;Database=test;UID=alice;PWD={p;ass};Encrypt=True;');
  assert.equal(parsed.profile.type, 'azure_sql');
  assert.equal(parsed.password, 'p;ass');
  assert.equal(parseConnectionString('Server=localhost;Database=test;UID=alice;PWD={ abc };').password, ' abc ');
  assert.equal(normalizeProfile({ ...parsed.profile, name: 'Test' }).trustServerCertificate, false);
  assert.throws(() => normalizeProfile({ ...parsed.profile, name: 'Test', trustServerCertificate: true }), /certificate validation/);
  const pg = parseConnectionString('postgres://alice:p%40ss@localhost:5432/test?sslmode=require');
  assert.equal(pg.password, 'p@ss');
  assert.equal(pg.profile.ssl, true);
  assert.equal(parseConnectionString('mysql://alice:secret@localhost/test').profile.type, 'mysql');
});

test('remote URL connections use verified TLS unless explicitly disabled', () => {
  const pg = 'postgres://alice:secret@db.example.com/reports';
  assert.equal(parseConnectionString(pg).profile.ssl, true);
  assert.equal(parseConnectionString(`${pg}?sslmode=verify-full`).profile.ssl, true);
  assert.equal(parseConnectionString(`${pg}?sslmode=disable`).profile.ssl, false);
  assert.throws(() => parseConnectionString(`${pg}?sslmode=prefer`), /Unsupported PostgreSQL SSL mode/);
  assert.throws(() => parseConnectionString(`${pg}?sslmode=disable&sslmode=require`), /Conflicting TLS/);

  const mysql = 'mysql://alice:secret@db.example.com/reports';
  assert.equal(parseConnectionString(mysql).profile.ssl, true);
  assert.equal(parseConnectionString(`${mysql}?sslmode=disable`).profile.ssl, false);
  assert.equal(parseConnectionString('mysql://root@localhost/devdb').profile.ssl, false);
  assert.equal(parseConnectionString('mysql://root@127.0.0.2/devdb').profile.ssl, false);
  assert.equal(parseConnectionString('mysql://root@127.999.999.999/devdb').profile.ssl, true);
  assert.equal(parseConnectionString('Server=db.example.com;Database=reports;Uid=alice;Pwd=secret;', 'mysql').profile.ssl, true);
  assert.equal(parseConnectionString('Server=db.example.com;Database=reports;Uid=alice;Pwd=secret;SslMode=None;', 'mysql').profile.ssl, false);
  assert.throws(
    () => parseConnectionString('Server=db.example.com;Database=reports;Uid=alice;Pwd=secret;SslMode=None;Ssl=True;', 'mysql'),
    /Conflicting TLS/
  );

  assert.equal(normalizeProfile({ name: 'Remote PG', type: 'postgres', host: 'db.example.com', database: 'reports', user: 'alice' }).ssl, true);
  assert.equal(normalizeProfile({ name: 'Remote MySQL', type: 'mysql', host: 'db.example.com', database: 'reports', user: 'alice' }).ssl, true);
  assert.equal(normalizeProfile({ name: 'Plaintext opt-out', type: 'mysql', host: 'db.example.com', database: 'reports', user: 'alice', ssl: false }).ssl, false);
});

test('remembered remote form connection preserves its effective TLS choice', async t => {
  const f = await fixture();
  t.after(() => fs.rm(f.root, { recursive: true, force: true }));
  const remote = await f.store.save({
    profile: { name: 'Remote', type: 'postgres', host: 'db.example.com', database: 'reports', user: 'alice' },
    password: 'secret', savePassword: true
  });
  assert.equal((await new ProfileStore({ filePath: f.filePath, keyring: f.keyring }).credentials(remote.profile.id)).profile.ssl, true);
  assert.match(f.secrets.get(remote.profile.id), /"ssl":true/);

  const plaintext = await f.store.save({
    profile: { name: 'Explicit plaintext', type: 'mysql', host: 'db.example.com', database: 'reports', user: 'alice', ssl: false },
    password: 'secret', savePassword: true
  });
  assert.equal((await f.store.credentials(plaintext.profile.id)).profile.ssl, false);
  const metadata = await fs.readFile(f.filePath, 'utf8');
  assert.equal(metadata.includes('db.example.com'), false);
  assert.equal(metadata.includes('secret'), false);
});

test('bounded result parameters and diagnostics never echo a password or query text', () => {
  assert.equal(boundedNumber(100, 20, 1, 500, 'Limit'), 100);
  assert.throws(() => boundedNumber(501, 20, 1, 500, 'Limit'));
  assert.equal(identifier('a]b', 'name'), 'a]b');
  assert.throws(() => identifier('a\nb', 'name'));
  assert.equal(cell('x'.repeat(5000)).length, 4097);
  const error = queryError(new Error("syntax error near 'SuperSecret123' in SELECT 'SuperSecret123'"), "SELECT 'SuperSecret123'", 'SuperSecret123');
  assert.equal(error.message.includes('SuperSecret123'), false);
  assert.match(error.message, /Query failed/);
});

test('large text cells retain their full value only after an accepted result commits', t => {
  const store = new CellValueStore();
  t.after(() => store.dispose());
  const batch = store.begin('connection-1');
  const rows = [];
  const refs = [];
  const budget = { bytes: 0 };
  const full = JSON.stringify({ message: 'é'.repeat(5000) });
  assert.equal(appendRow(rows, ['short', full, 42], budget, refs, batch), true);
  assert.equal(rows[0][0], 'short');
  assert.equal(rows[0][1].length, 4097);
  assert.equal(rows[0][2], 42);
  assert.equal(refs.length, 1);
  assert.deepEqual({ row: refs[0].row, column: refs[0].column, byteLength: refs[0].byteLength, complete: refs[0].complete },
    { row: 0, column: 1, byteLength: Buffer.byteLength(full), complete: false });
  assert.equal(store.get('connection-1', refs[0].handle), null, 'in-flight values must not be readable');
  assert.equal(batch.commit(), true);
  assert.deepEqual(store.get('connection-1', refs[0].handle), { text: full, byteLength: Buffer.byteLength(full) });
  assert.equal(store.get('connection-2', refs[0].handle), null, 'handles are connection scoped');

  const more = store.begin('connection-1');
  const otherRows = [];
  const otherRefs = [];
  const document = { nested: { message: 'v'.repeat(5000) } };
  assert.equal(appendRow(otherRows, [document, Buffer.alloc(5000)], { bytes: 0 }, otherRefs, more), true);
  assert.equal(otherRefs.length, 2);
  assert.equal(otherRefs[0].column, 0);
  assert.equal(otherRefs[1].column, 1);
  assert.equal(otherRefs[1].handle, null, 'binary previews do not become text handles');
  more.commit();
  assert.equal(store.get('connection-1', otherRefs[0].handle).text, JSON.stringify(document));

  const rejected = store.begin('connection-1');
  const rejectedRows = [];
  const rejectedRefs = [];
  const nearlyFull = { bytes: 5 * 1024 * 1024 - 50 };
  const before = store.totalBytes;
  assert.equal(appendRow(rejectedRows, [full], nearlyFull, rejectedRefs, rejected), false);
  assert.deepEqual(rejectedRows, []);
  assert.deepEqual(rejectedRefs, []);
  assert.equal(store.totalBytes, before, 'a row outside the response budget must not be cached');
  rejected.discard();

  const cancelled = store.begin('connection-1');
  const discardedHandle = cancelled.capture(full);
  cancelled.discard();
  assert.equal(store.get('connection-1', discardedHandle), null);
});

test('cell value cache enforces size, expiry, connection close, and zeroes evicted buffers', t => {
  let now = 1000;
  const store = new CellValueStore({ maxEntryBytes: 6000, maxTotalBytes: 10000, ttlMs: 100, now: () => now });
  t.after(() => store.dispose());
  const first = store.begin('A');
  const firstHandle = first.capture('x'.repeat(5000));
  const firstBuffer = store.entries.get(firstHandle).buffer;
  first.commit();
  const second = store.begin('A');
  const secondHandle = second.capture('y'.repeat(5000));
  second.commit();
  const third = store.begin('A');
  const thirdHandle = third.capture('z'.repeat(5000));
  third.commit();
  assert.equal(store.get('A', firstHandle), null, 'old completed values should be evicted');
  assert.equal(firstBuffer.every(byte => byte === 0), true, 'evicted value buffer must be wiped');
  assert.equal(store.get('A', secondHandle)?.byteLength, 5000);
  assert.equal(store.get('A', thirdHandle)?.byteLength, 5000);
  assert.equal(store.totalBytes, 10000);

  const tooLarge = store.begin('A');
  assert.equal(tooLarge.capture('w'.repeat(6001)), null);
  tooLarge.discard();

  now += 101;
  assert.equal(store.get('A', thirdHandle), null, 'expired values must not be returned');
  assert.equal(store.totalBytes, 0);

  const closing = store.begin('A');
  const closingHandle = closing.capture('closed'.repeat(1000));
  store.clearConnection('A');
  assert.equal(closing.commit(), false, 'a closed connection cannot commit pending values');
  assert.equal(store.get('A', closingHandle), null);
});

test('PostgreSQL table errors identify missing schema USAGE or table SELECT without leaking details', () => {
  const schemaDenied = tableReadError(
    { code: '42501', message: 'permission denied for schema rnacen' },
    'postgres', 'data', 'private-password'
  );
  assert.match(schemaDenied.message, /PostgreSQL 42501.*lacks USAGE on the selected schema/);
  assert.match(schemaDenied.message, /table or view SELECT/);
  assert.equal(schemaDenied.message.includes('rnacen'), false);

  const tableDenied = tableReadError(
    { code: '42501', message: 'permission denied for table secret_table' },
    'postgres', 'data', 'private-password'
  );
  assert.match(tableDenied.message, /lacks SELECT on the selected table or view/);
  assert.equal(tableDenied.message.includes('secret_table'), false);

  const definitionDenied = tableReadError(
    { code: '42501', message: 'permission denied for schema private_schema' },
    'postgres', 'definition', 'private-password'
  );
  assert.match(definitionDenied.message, /table definition.*lacks USAGE/);
  assert.equal(definitionDenied.message.includes('private_schema'), false);

  const otherFailure = tableReadError(
    { code: '42P01', message: 'relation "private-password" does not exist' },
    'postgres', 'data', 'private-password'
  );
  assert.match(otherFailure.message, /42P01/);
  assert.equal(otherFailure.message.includes('private-password'), false);
  assert.match(tableReadError({ code: '42501', message: 'permission denied' }, 'mysql', 'data').message, /^Could not load table data\.$/);
});

test('database switching opens a new SQL connection with the active in-memory credential', async () => {
  const profile = { id: 'profile-1', type: 'azure_sql', host: 'server.example', database: 'First', user: 'reader' };
  const previous = { id: 'connection-1', profileId: profile.id, profile, password: 'private-password', meta: { id: profile.id, name: 'Saved', type: 'azure_sql' } };
  let opened;
  const next = await openSwitchedDatabase(previous, 'Second DB', async (newProfile, password) => {
    opened = { newProfile, password };
    return { id: 'connection-2', profileId: profile.id, profile: newProfile, adapter: { close() {} } };
  });
  assert.equal(opened.password, 'private-password');
  assert.equal(opened.newProfile.database, 'Second DB');
  assert.equal(next.id, 'connection-2');
  assert.equal(next.password, 'private-password');
  assert.equal(next.meta, previous.meta);
  assert.equal(previous.profile.database, 'First');
  assert.equal(databaseName('A database with spaces'), 'A database with spaces');
  for (const value of ['', ' ', 'x'.repeat(129), 'invalid\nname', 7]) {
    assert.throws(() => databaseName(value), /Invalid database name/);
  }
  await assert.rejects(
    openSwitchedDatabase(previous, 'Denied', async () => { throw new Error('Could not connect to SQL Server.'); }),
    /Could not connect to SQL Server/
  );
  assert.equal(previous.profile.database, 'First');
  await assert.rejects(
    openSwitchedDatabase({ ...previous, profile: { ...profile, type: 'postgres' } }, 'Other', async () => {}),
    /supported for SQL Server and Azure SQL/
  );
});

test('result limits default to 100, allow 1000, and reject anything larger', () => {
  assert.equal(DEFAULT_RESULT_LIMIT, 100);
  assert.equal(MAX_RESULT_LIMIT, 1000);
  assert.equal(resultLimit(undefined), 100);
  assert.equal(resultLimit(undefined, 250), 250);
  assert.equal(resultLimit(1000), 1000);
  for (const value of [0, 1001, 1.5, 'all']) {
    assert.throws(() => resultLimit(value), /Limit must be between 1 and 1000/);
  }
});

test('default result limit persists privately and survives a new worker session', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'db-browser-settings-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const filePath = path.join(root, 'omarchy', 'db-browser', 'settings.json');
  const store = new SettingsStore({ filePath });
  assert.deepEqual(await store.get(), { defaultLimit: 100, reopenLastConnection: false, lastProfileId: null });
  assert.deepEqual(await store.save({ defaultLimit: 750 }), { defaultLimit: 750, reopenLastConnection: false, lastProfileId: null });
  assert.deepEqual(await new SettingsStore({ filePath }).get(), { defaultLimit: 750, reopenLastConnection: false, lastProfileId: null });
  assert.equal((await fs.stat(filePath)).mode & 0o777, 0o600);
  assert.equal((await fs.stat(path.dirname(filePath))).mode & 0o777, 0o700);
  assert.deepEqual(JSON.parse(await fs.readFile(filePath, 'utf8')), { version: 1, defaultLimit: 750, reopenLastConnection: false, lastProfileId: null });
  for (const value of [0, 1001, 1.5, undefined, '100', true, [100]]) {
    await assert.rejects(store.save({ defaultLimit: value }), /Limit must be between 1 and 1000/);
  }
  assert.deepEqual(await store.get(), { defaultLimit: 750, reopenLastConnection: false, lastProfileId: null });
});

test('reconnect setting preserves old settings and records only a profile ID', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'db-browser-reconnect-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const filePath = path.join(root, 'settings.json');
  await fs.writeFile(filePath, JSON.stringify({ version: 1, defaultLimit: 250 }));
  const store = new SettingsStore({ filePath });
  assert.deepEqual(await store.get(), { defaultLimit: 250, reopenLastConnection: false, lastProfileId: null });

  const id = '123e4567-e89b-42d3-a456-426614174000';
  await store.save({ reopenLastConnection: true });
  await store.save({ lastProfileId: id });
  await store.save({ defaultLimit: 500 });
  assert.deepEqual(await new SettingsStore({ filePath }).get(), {
    defaultLimit: 500, reopenLastConnection: true, lastProfileId: id
  });
  assert.deepEqual(JSON.parse(await fs.readFile(filePath, 'utf8')), {
    version: 1, defaultLimit: 500, reopenLastConnection: true, lastProfileId: id
  });
  await assert.rejects(store.save({ lastProfileId: 'server=private;password=secret' }), /Last connection ID is invalid/);
  await assert.rejects(store.save({ reopenLastConnection: 'yes' }), /Reopen last connection must be true or false/);
  await store.save({ lastProfileId: null });
  assert.equal((await store.get()).lastProfileId, null);
});

test('worker response lines survive short writes and stdout backpressure', async () => {
  const chunks = [];
  let attempts = 0;
  let waits = 0;
  const write = (fd, bytes, offset, length, position, callback) => {
    assert.equal(fd, 91);
    assert.equal(position, null);
    attempts += 1;
    if (attempts === 2 || attempts === 7) {
      const error = Object.assign(new Error('pipe is full'), { code: 'EAGAIN' });
      queueMicrotask(() => callback(error));
      return;
    }
    if (attempts === 4) {
      queueMicrotask(() => callback(null, 0));
      return;
    }
    const count = Math.min(length, 4093);
    chunks.push(Buffer.from(bytes.subarray(offset, offset + count)));
    queueMicrotask(() => callback(null, count));
  };
  const writeLine = createLineWriter({ fd: 91, write, wait: async () => { waits += 1; } });
  const responses = [
    { id: 1, ok: true, data: { rows: [['π'.repeat(70000)]] } },
    { id: 2, ok: true, data: { rows: [['next response']] } }
  ];

  await Promise.all(responses.map(response => writeLine(JSON.stringify(response))));
  const output = Buffer.concat(chunks).toString('utf8');
  assert.equal(output.endsWith('\n'), true);
  assert.deepEqual(output.trimEnd().split('\n').map(JSON.parse), responses);
  assert.equal(waits, 3);
  assert.ok(attempts > 30);
});

test('worker uses JSON lines and keeps session-only credentials off stdout', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'db-browser-worker-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const child = spawn(process.execPath, ['backend/worker.mjs'], {
    cwd: path.resolve(import.meta.dirname, '..'),
    env: { ...process.env, XDG_CONFIG_HOME: root },
    stdio: ['pipe', 'pipe', 'pipe']
  });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stdin.write(JSON.stringify({ id: 1, action: 'profiles.save', payload: {
    profile: { name: 'Session', type: 'postgres', host: 'localhost', database: 'db', user: 'u' },
    password: 'NeverPrintMe', savePassword: false
  } }) + '\n');
  child.stdin.write(JSON.stringify({ id: 2, action: 'profiles.list', payload: {} }) + '\n');
  child.stdin.write(JSON.stringify({ id: 3, action: 'settings.get', payload: {} }) + '\n');
  child.stdin.write(JSON.stringify({ id: 4, action: 'settings.save', payload: { defaultLimit: 1000 } }) + '\n');
  child.stdin.write(JSON.stringify({ id: 5, action: 'settings.get', payload: {} }) + '\n');
  child.stdin.end();
  await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`worker exited ${code}`)));
  });
  const lines = output.trim().split('\n').map(JSON.parse);
  assert.equal(lines.length, 5);
  assert.equal(lines.find(line => line.id === 1).ok, true);
  assert.equal(lines.find(line => line.id === 2).data.profiles.length, 1);
  assert.equal(lines.find(line => line.id === 3).data.defaultLimit, 100);
  assert.equal(lines.find(line => line.id === 4).data.defaultLimit, 1000);
  assert.equal(lines.find(line => line.id === 5).data.defaultLimit, 1000);
  assert.equal(output.includes('NeverPrintMe'), false);
  await assert.rejects(fs.stat(path.join(root, 'omarchy', 'db-browser', 'connections.json')), { code: 'ENOENT' });
  assert.equal(JSON.parse(await fs.readFile(path.join(root, 'omarchy', 'db-browser', 'settings.json'), 'utf8')).defaultLimit, 1000);
});
