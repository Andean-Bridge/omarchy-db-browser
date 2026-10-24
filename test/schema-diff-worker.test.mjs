import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, cp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { WorkerClient } from '../backend/worker-client.mjs';

test('schema diff protocol preserves object scope and script options through preview, generation and save', async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'db-studio-diff-worker-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  const backend = path.join(root, 'backend');
  await cp(new URL('../backend', import.meta.url), backend, {recursive:true});
  const original = new URL('../backend/drivers.mjs', import.meta.url).href;
  await writeFile(path.join(backend, 'drivers.mjs'), `
    export { boundedNumber, databaseName, identifier, queryError, tableReadError, openSwitchedDatabase } from ${JSON.stringify(original)};
    export async function openDatabase(profile) {
      const source = profile.database === 'source';
      const objects = [{objectId:1,schema:'dbo',name:'items',type:'table'},
        {objectId:2,schema:'dbo',name:'dependent',type:'view',dependencies:[{referencedSchema:'dbo',referencedName:'items'}]}];
      return {id:crypto.randomUUID(),profile,adapter:{
        async close() {},
        async diffCatalog() { return {schemas:[{name:'dbo'}],objects}; },
        async diffDetails(selected) {
          return Object.fromEntries(selected.map(o => [o.objectId, o.type === 'table' ? {
            columns:[{name:'id',typeName:'int',maxLength:4,precision:10,scale:0,nullable:false},
              ...(source ? [{name:'extra',typeName:'int',maxLength:4,precision:10,scale:0,nullable:true}] : [])],
            indexes:[],checks:[],foreignKeys:[],incomingForeignKeys:[]
          } : {definition:'CREATE VIEW dbo.dependent AS SELECT * FROM dbo.items'}]));
        }
      }};
    }
  `);
  const worker = new WorkerClient({spawnWorker:() => spawn(process.execPath,[path.join(backend,'worker.mjs')],{
    env:{...process.env,XDG_CONFIG_HOME:path.join(root,'config')},stdio:['pipe','pipe','pipe']
  })});
  t.after(() => worker.close());
  async function profile(name) {
    return (await worker.call('profiles.save',{profile:{name,type:'sqlserver',host:'localhost',database:name,user:'fixture',encrypt:false,trustServerCertificate:true},password:'fixture',savePassword:false})).profile.id;
  }
  const sourceProfileId = await profile('source');
  const targetProfileId = await profile('target');
  const selection = {sourceProfileId,targetProfileId,selectedSchemas:['dbo'],selectedObjects:['["dbo","items"]']};
  const catalog = await worker.call('schemaDiff.catalog',selection);
  assert.equal(catalog.source.objects.length,2);
  await assert.rejects(worker.call('schemaDiff.compare',{...selection,selectedObjects:[]}),/Select at least one object/);
  const comparison = await worker.call('schemaDiff.compare',selection);
  assert.equal(comparison.changes.length,1);
  const key = '["dbo","items"]';
  const preview = await worker.call('schemaDiff.preview',{comparisonId:comparison.comparisonId,objectKey:key,scriptOptions:{refreshDependentViews:false}});
  assert.equal(preview.complete,false);
  assert.match(preview.manual.join(' '),/refresh was disabled/);
  const script = await worker.call('schemaDiff.script',{comparisonId:comparison.comparisonId,selectedKeys:[key]});
  assert.equal(script.complete,true);
  assert.equal(script.refreshedViews[0].name,'dependent');
  const filePath = path.join(root,'comparison.sql');
  await worker.call('schemaDiff.save',{comparisonId:comparison.comparisonId,filePath});
  assert.equal(await readFile(filePath,'utf8'),script.sql);
  await assert.rejects(worker.call('schemaDiff.script',{comparisonId:comparison.comparisonId,selectedKeys:[key],scriptOptions:{refreshDependentViews:'false'}}),/Invalid script options/);
});
