import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, cp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { WorkerClient } from '../backend/worker-client.mjs';

test('worker generates table scripts through metadata only, validates actions and connection, and propagates definition failures', async t => {
  const root = await mkdtemp(path.join(tmpdir(),'db-studio-table-scripts-'));
  t.after(() => rm(root,{recursive:true,force:true}));
  await cp(new URL('../backend',import.meta.url),path.join(root,'backend'),{recursive:true});
  const original = new URL('../backend/drivers.mjs',import.meta.url).href;
  await writeFile(path.join(root,'backend/drivers.mjs'), `
    export { boundedNumber, databaseName, identifier, queryError, tableReadError, openSwitchedDatabase } from ${JSON.stringify(original)};
    export async function openDatabase(profile,password) {
      return {id:crypto.randomUUID(),profile,password,meta:{name:'Fixture'},adapter:{
        async close() {},
        async objects(schema) { return ['people','denied','view'].map(name => ({schema,name,type:name === 'view' ? 'view' : 'table'})); },
        async describe() { return {columns:[{name:'id',type:'integer',identity:true,primaryKey:true},{name:'name',type:'text'}]}; },
        async createScript(schema,name) { if (name === 'denied') throw new Error('Could not read metadata'); return 'CREATE TABLE "public"."people" ("id" integer PRIMARY KEY, "name" text);'; },
        async run() { throw new Error('GENERATOR EXECUTED SQL'); }
      }};
    }
  `);
  const worker = new WorkerClient({spawnWorker:() => spawn(process.execPath,[path.join(root,'backend/worker.mjs')],{
    env:{...process.env,XDG_CONFIG_HOME:path.join(root,'config')},stdio:['pipe','pipe','pipe']
  })});
  t.after(() => worker.close());
  const {profile} = await worker.call('profiles.save',{profile:{name:'Fixture',type:'postgres',host:'localhost',database:'fixture',user:'fixture',ssl:false},password:'fixture-password',savePassword:false});
  const {connectionId} = await worker.call('connection.open',{profileId:profile.id});
  const payload = {connectionId,schema:'public',name:'people'};
  for (const script of ['create','alter','insert','update']) {
    const result = await worker.call('table.script',{...payload,script});
    assert.equal(result.action,script);
    assert.match(result.sql,new RegExp(script.toUpperCase()));
  }
  await assert.rejects(worker.call('table.script',{...payload,script:'drop'}),/Invalid table script/);
  await assert.rejects(worker.call('table.script',{...payload,script:'create',name:'view'}),/existing table/);
  await assert.rejects(worker.call('table.script',{...payload,script:'create',name:'denied'}),/Could not read metadata/);
  await worker.call('connection.close',{connectionId});
  await assert.rejects(worker.call('table.script',{...payload,script:'create'}),/Connection is closed/);
});

test('MySQL adapter preserves native DDL options and qualifies CREATE with the selected database', async t => {
  const root = await mkdtemp(path.join(tmpdir(),'db-studio-mysql-script-'));
  t.after(() => rm(root,{recursive:true,force:true}));
  await cp(new URL('../backend',import.meta.url),path.join(root,'backend'),{recursive:true});
  const module = path.join(root,'node_modules/mysql2');
  await mkdir(module,{recursive:true});
  await writeFile(path.join(module,'package.json'),JSON.stringify({type:'module',main:'index.js'}));
  await writeFile(path.join(module,'index.js'), `
    import assert from 'node:assert/strict';
    export default {createPool() { return {promise() { return {
      async getConnection() { return {release(){}}; }, async end(){},
      async query({sql,values}) {
        assert.equal(sql,'SHOW CREATE TABLE \`other\`\`db\`.\`t\`\`able\`');
        assert.deepEqual(values,[]);
        return [[{'Create Table':'CREATE TABLE \`t\`\`able\` (id int NOT NULL, PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4'}]];
      }
    }; }}; }};
  `);
  const {openDatabase} = await import(pathToFileURL(path.join(root,'backend/drivers.mjs')).href);
  const {adapter} = await openDatabase({type:'mysql',host:'localhost',database:'fixture',user:'fixture',ssl:false},'fixture');
  t.after(() => adapter.close());
  assert.equal(await adapter.createScript('other`db','t`able'),
    'CREATE TABLE `other``db`.`t``able` (id int NOT NULL, PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;');
});
