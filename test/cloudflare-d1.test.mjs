import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { cloudflareD1 } from '../backend/cloudflare-d1.mjs';
import { normalizeProfile, parseConnectionString } from '../backend/connection-string.mjs';
import { ProfileStore } from '../backend/profiles.mjs';
import { tableReadPlan } from '../backend/table-read.mjs';
import { CellValueStore } from '../backend/cell-values.mjs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { WorkerClient } from '../backend/worker-client.mjs';

const profile = { name: 'D1 fixture', type: 'cloudflare_d1', accountId: 'a'.repeat(32), databaseId: '12345678-1234-1234-1234-123456789abc' };
const token = 'fixture-cloudflare-token';
const response = (result, status = 200) => Response.json({ success: true, result }, { status });
const raw = (columns, rows, changes = 0) => [{ success: true, results: { columns, rows }, meta: { changes } }];

test('D1 profiles validate IDs, protect tokens in keyring, and preserve agent consent', async t => {
  assert.equal(normalizeProfile({ ...profile, type: 'd1' }).type, 'cloudflare_d1');
  for (const fields of [{accountId:'../bad'}, {databaseId:'name'}, {accountId:'a'.repeat(33)}]) {
    assert.throws(() => normalizeProfile({ ...profile, ...fields }), /Cloudflare/);
  }
  assert.throws(() => parseConnectionString('Server=x;Password=y', 'd1'), /Cloudflare/);
  const directory = await mkdtemp(path.join(tmpdir(), 'db-studio-d1-profile-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const filePath = path.join(directory, 'profiles.json');
  const secrets = new Map();
  const keyring = { async store(id, secret) { secrets.set(id, secret); }, async lookup(id) { return secrets.get(id); } };
  const store = new ProfileStore({ filePath, keyring });
  const { profile: saved } = await store.save({ profile, password: token, savePassword: true });
  const disk = await readFile(filePath, 'utf8');
  for (const secret of [token, profile.accountId, profile.databaseId]) assert.equal(disk.includes(secret), false);
  assert.equal(saved.agentAccess, false);
  await assert.rejects(store.credentials(saved.id, { requireAgentAccess: true }), /not found/);
  const reopened = new ProfileStore({ filePath, keyring });
  assert.equal((await reopened.credentials(saved.id)).password, token);
  await reopened.save({ profile: { id: saved.id, name: 'Renamed', type: 'd1' }, agentAccess: true });
  assert.equal((await reopened.credentials(saved.id, {requireAgentAccess:true})).profile.databaseId, profile.databaseId);
  const copy = await reopened.duplicate(saved.id);
  assert.equal(copy.profile.agentAccess, false);
  assert.equal((await reopened.credentials(copy.profile.id)).password, token);
  for (const password of ['', 'token\nheader', 'token with spaces']) {
    await assert.rejects(store.save({ profile, password, savePassword:false }), /Cloudflare API token/);
  }
});

test('D1 browses SQLite metadata, binds filters, preserves empty/duplicate columns, and caps displayed results', async () => {
  const calls = [];
  const adapter = await cloudflareD1(profile, token, { fetchApi: async (url, options) => {
    calls.push({ url, options });
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    assert.equal(options.redirect, 'error');
    if (options.method === 'GET') return response({ name: 'my-d1-database' });
    const { sql, params } = JSON.parse(options.body);
    if (sql.startsWith('PRAGMA')) return response(raw(['name','type','notnull','pk','hidden','dflt_value'], [
      ['id','INTEGER',0,1,0,null], ['name','TEXT',0,0,0,"'hello'"], ['computed','TEXT',0,0,3,null], ['internal','TEXT',0,0,1,null]
    ]));
    if (sql.includes("type = 'index'")) { assert.deepEqual(params, ['peo"ple']); return response(raw(['name','definition'], [['ix_name','CREATE INDEX ix_name ON people(name)']])); }
    if (sql.includes("AS schema")) return response(raw(['schema','name','type'], [['main','people','table'],['main','people_view','view']]));
    if (sql === 'SELECT empty') return response(raw(['id','name'], []));
    if (sql === 'SELECT duplicates') return response(raw(['x','x'], [[1,2]]));
    if (sql === 'UPDATE people SET name = NULL') return response(raw([], [], 3));
    if (sql === 'SELECT long') return response(raw(['name'], [['x'.repeat(5000)]]));
    if (sql.startsWith('SELECT *')) {
      assert.deepEqual(params, ["%O'Reilly!_!%![%", 3, 40]);
      assert.match(sql, /FROM "main"\."peo""ple" WHERE "name" LIKE \? ESCAPE '!' ORDER BY "name" DESC, "id" ASC LIMIT \? OFFSET \?$/);
      return response(raw(['id','name'], [[1,'one'],[2,'two'],[3,'three']]));
    }
    throw new Error('Unexpected SQL');
  } });
  assert.equal(adapter.databaseName, 'my-d1-database');
  assert.equal(calls.length, 1); // Connection verification does not run SQL.
  assert.deepEqual(await adapter.schemas(), [{name:'main'}]);
  assert.equal((await adapter.objects())[1].type, 'view');
  await assert.rejects(adapter.objects('other'), /Invalid D1 schema/);
  const definition = await adapter.describe('main', 'peo"ple');
  assert.equal(definition.columns.length, 3);
  assert.equal(definition.columns[0].primaryKey, true);
  assert.equal(definition.columns[2].generated, true);
  assert.equal(adapter.updateCell, undefined);
  const plan = tableReadPlan('cloudflare_d1','main','peo"ple',definition,{limit:2,offset:40,
    sort:{column:'name',direction:'desc'},filter:{column:'name',operator:'contains',value:"O'Reilly_%["}});
  const page = await adapter.rows('main','peo"ple',2,40,undefined,undefined,plan);
  assert.deepEqual(page.rows, [[1,'one'],[2,'two']]);
  assert.equal(page.hasMore, true);
  assert.equal(page.offset, 40);
  assert.deepEqual((await adapter.run('SELECT empty', 100)).columns, [{name:'id'},{name:'name'}]);
  assert.deepEqual((await adapter.run('SELECT duplicates', 100)).rows, [[1,2]]);
  assert.equal((await adapter.run('UPDATE people SET name = NULL', 100)).rowCount, 3);
  const store = new CellValueStore();
  const batch = store.begin('connection');
  const long = await adapter.run('SELECT long',100,1000,undefined,batch);
  batch.commit();
  assert.equal(store.get('connection',long.cellRefs[0].handle).text.length, 5000);
  assert.ok(long.rows[0][0].length < 5000);
  await adapter.close();
  await assert.rejects(adapter.run('SELECT empty',100), /Connection is closed/);
});

test('D1 reports permission, SQL, and malformed response errors without credentials or retries', async () => {
  for (const failure of [
    () => response({},403),
    () => Response.json({success:false,errors:[{message:`SQL error: ${token} near SELECT secret`} ]},{status:400}),
    () => Response.json({success:true,result:[{success:false,error:`SQL error: ${token}`}]}),
    () => new Response('not json'),
    () => response({bad:'shape'}),
    () => { throw new Error(`network ${token}`); }
  ]) {
    let calls = 0;
    const adapter = await cloudflareD1(profile,token,{fetchApi:async () => ++calls === 1 ? response({name:'fixture'}) : failure()});
    await assert.rejects(adapter.run('SELECT secret',100), error => {
      assert.match(error.message,/Query failed/);
      assert.equal(error.message.includes(token),false);
      assert.equal(error.message.includes('SELECT secret'),false);
      return true;
    });
    assert.equal(calls,2);
  }
});

test('D1 cancels, times out, and closes HTTP requests without retrying SQL', async () => {
  let mode = 'success', calls = 0;
  const adapter = await cloudflareD1(profile,token,{fetchApi:async (url,{signal}) => {
    calls++;
    if (mode === 'success') return response({name:'fixture'});
    return new Promise((resolve,reject) => signal.addEventListener('abort',() => reject(new Error('aborted')),{once:true}));
  }});
  mode = 'pending';
  let cancel;
  const running = adapter.run('UPDATE fixture SET x=1',100,1000,fn => { cancel = fn; });
  cancel();
  await assert.rejects(running,/Query cancelled/);
  await assert.rejects(adapter.run('SELECT 1',100,5),/Query timed out.*may still finish/);
  const closing = adapter.run('SELECT 1',100,1000);
  await adapter.close();
  await assert.rejects(closing,/Query cancelled/);
  assert.equal(calls,4);
});

test('D1 limits response bytes and identifies multiple statements without implying rollback', async () => {
  let mode = 'multiple';
  const adapter = await cloudflareD1(profile,token,{fetchApi:async (url,options) => {
    if (options.method === 'GET') return response({name:'fixture'});
    if (mode === 'multiple') return response([...raw([],[],2),...raw(['id'],[[1],[2],[3]])]);
    return new Response(new ReadableStream({start(controller) { controller.enqueue(new Uint8Array(32*1024*1024+1)); controller.close(); }}));
  }});
  const result = await adapter.run('UPDATE fixture SET x=1; SELECT id FROM fixture',2);
  assert.match(result.message,/2 SQL statements executed/);
  assert.deepEqual(result.rows,[[1],[2]]);
  assert.equal(result.hasMore,true);
  mode = 'large';
  await assert.rejects(adapter.run('SELECT * FROM huge',100),/exceeds 32 MB/);
});

test('D1 works through the real worker protocol with a local SQLite-backed API fixture', async t => {
  try { await import('node:sqlite'); }
  catch { return t.skip('Node SQLite is required for the isolated Cloudflare API fixture.'); }
  const directory = await mkdtemp(path.join(tmpdir(),'db-studio-d1-worker-'));
  t.after(() => rm(directory,{recursive:true,force:true}));
  const preload = path.join(directory,'cloudflare-fixture.mjs');
  await writeFile(preload, `
    import { DatabaseSync } from 'node:sqlite';
    const db = new DatabaseSync(':memory:');
    db.exec("CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, enabled BOOLEAN); INSERT INTO people VALUES (1, 'First', 1), (2, 'Second', 0), (3, 'Third', 1); CREATE VIEW names AS SELECT name FROM people; CREATE TABLE _cf_KV(key TEXT);");
    globalThis.fetch = async (url, options) => {
      if (!url.startsWith('https://api.cloudflare.com/client/v4/accounts/')) throw new Error('Unexpected host');
      if (options.headers.Authorization !== 'Bearer ${token}') return Response.json({success:false},{status:403});
      if (options.method === 'GET') return Response.json({success:true,result:{name:'fixture-database'}});
      const {sql,params} = JSON.parse(options.body);
      try {
        const statement = db.prepare(sql);
        const columns = statement.columns().map(column => column.name);
        const rows = statement.all(...params).map(row => columns.map(column => row[column]));
        return Response.json({success:true,result:[{success:true,results:{columns,rows},meta:{changes:db.prepare('SELECT changes() AS n').get().n}}]});
      } catch (error) { return Response.json({success:false,errors:[{message:error.message}]},{status:400}); }
    };
  `);
  const worker = new WorkerClient({spawnWorker:() => spawn(process.execPath,['--import',preload,fileURLToPath(new URL('../backend/worker.mjs',import.meta.url))],{
    env:{...process.env,XDG_CONFIG_HOME:path.join(directory,'config')},stdio:['pipe','pipe','pipe']
  })});
  t.after(() => worker.close());
  const { profile: saved } = await worker.call('profiles.save',{profile,password:token,savePassword:false});
  await assert.rejects(worker.call('agent.connection.open',{profileId:saved.id}),/not found/);
  const opened = await worker.call('connection.open',{profileId:saved.id});
  assert.equal(opened.profile.transportSecure,true);
  assert.equal(opened.profile.database,'fixture-database');
  assert.equal(JSON.stringify(opened).includes(token),false);
  const connectionId = opened.connectionId;
  assert.deepEqual(await worker.call('schemas.list',{connectionId}),{schemas:[{name:'main'}]});
  const catalog = await worker.call('objects.list',{connectionId});
  assert.deepEqual(catalog.objects.map(object => object.name),['names','people']);
  const definition = await worker.call('table.describe',{connectionId,name:'people'});
  assert.equal(definition.columns[0].primaryKey,true);
  const first = await worker.call('table.rows',{connectionId,name:'people',limit:2});
  assert.deepEqual(first.rows,[[1,'First',1],[2,'Second',0]]);
  assert.equal(first.hasMore,true);
  assert.deepEqual(first.editHandles || [],[]);
  const filtered = await worker.call('table.rows',{connectionId,name:'people',limit:2,sort:{column:'name',direction:'desc'},filter:{column:'enabled',operator:'equals',value:true}});
  assert.deepEqual(filtered.rows,[[3,'Third',1],[1,'First',1]]);
  const literal = await worker.call('table.rows',{connectionId,name:'people',filter:{column:'name',operator:'contains',value:"%_['; DROP TABLE people;--"}});
  assert.deepEqual(literal.rows,[]);
  await assert.rejects(worker.call('table.updateCell',{connectionId,handle:'fake',column:'name',value:'Oops'}),/use SQL|Unsupported action/);
  assert.equal((await worker.call('query.run',{connectionId,sql:"UPDATE people SET name = 'Changed' WHERE id = 1"})).rowCount,1);
  assert.deepEqual((await worker.call('query.run',{connectionId,sql:'SELECT name FROM people WHERE id = 1'})).rows,[['Changed']]);
  await assert.rejects(worker.call('query.run',{connectionId,sql:'SELECT missing FROM people'}),/no such column/);
  await worker.call('connection.close',{connectionId});
});
