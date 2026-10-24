import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, cp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { WorkerClient } from '../backend/worker-client.mjs';

// Exercise the real JSON protocol and snapshot lifecycle with an isolated,
// deterministic adapter. This never opens a user's database or profile store.
test('worker edits only captured rows; rejects conflicting, repeated, and disconnected saves', async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'db-studio-row-edit-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const backend = path.join(root, 'backend');
  await cp(fileURLToPath(new URL('../backend', import.meta.url)), backend, { recursive: true });
  const original = new URL('../backend/drivers.mjs', import.meta.url).href;
  await writeFile(path.join(backend, 'drivers.mjs'), `
    export { boundedNumber, databaseName, identifier, queryError, tableReadError, openSwitchedDatabase } from ${JSON.stringify(original)};
    import { appendRow } from ${JSON.stringify(original)};
    import { commitSingleCell } from './row-edit.mjs';
    export async function openDatabase(profile, password) {
      let value = 'Original';
      let active = false;
      let metadataAvailable = true;
      const columns = [{name:'id',type:'integer',primaryKey:true}, {name:'name',type:'varchar',nullable:true}, {name:'active',type:'boolean',nullable:false}];
      return { id: crypto.randomUUID(), profile, password, meta: {name:'Fixture'}, adapter: {
        async close() {},
        async objects() { return [{schema:'public',name:'people',type:'table'}]; },
        async describe() { if (!metadataAvailable) throw new Error("metadata denied"); return {columns}; },
        async rows(schema,name,limit,offset,onReady,batch,readPlan) {
          const rows = []; appendRow(rows,[7,value,active],{bytes:0},[],batch);
          return {columns,rows,cellRefs:[],offset,hasMore:false,readPlan};
        },
        async run(sql) { if (sql === 'deny metadata') metadataAvailable = false; else if (sql === 'change active') active = !active; else value = 'External change'; return {}; },
        async updateCell(plan) {
          let next;
          return commitSingleCell({
            async begin() {}, async rollback() {}, async commit() { value = next.name; active = next.active; },
            async update() {
              const [set, where] = plan.sql.split(' SET ')[1].split(' WHERE ');
              const current = {id:7,name:value,active};
              // Read the actual bound predicates, including all changed columns.
              for (const match of where.matchAll(/"(\\w+)" (IS NULL|= \\$([0-9]+))/g)) {
                const expected = match[2] === 'IS NULL' ? null : plan.params[Number(match[3])-1];
                if (current[match[1]] !== expected) return 0;
              }
              next = {...current};
              for (const match of set.matchAll(/"(\\w+)" = \\$([0-9]+)/g)) next[match[1]] = plan.params[Number(match[2])-1];
              return 1;
            }
          }, plan);
        }
      }};
    }
  `);
  const worker = new WorkerClient({ spawnWorker: () => spawn(process.execPath, [path.join(backend, 'worker.mjs')], {
    env: { ...process.env, XDG_CONFIG_HOME: path.join(root, 'config') }, stdio: ['pipe', 'pipe', 'pipe']
  }) });
  t.after(() => worker.close());
  const { profile } = await worker.call('profiles.save', { profile: {name:'Fixture',type:'postgres',host:'localhost',database:'fixture',user:'fixture',ssl:false}, password:'fixture-password',savePassword:false });
  const { connectionId } = await worker.call('connection.open', { profileId: profile.id });
  const read = () => worker.call('table.rows', {connectionId,schema:'public',name:'people',limit:20});
  const update = (handle, value, extra = {}) => worker.call('table.updateCell', {connectionId,handle,column:'name',value,...extra});
  let result = await read();
  assert.equal(result.editHandles.length, 1);
  await assert.rejects(worker.call('table.updateCell', {connectionId,handle:result.editHandles[0],column:'id',value:99}), /read-only/);
  result = await read();
  // A fake client-side column order or table name cannot change the captured identity.
  await update(result.editHandles[0], '', {columns:['name','id'],schema:'evil',name:'other'});
  await assert.rejects(update(result.editHandles[0], 'Duplicate'), /expired/);
  result = await read();
  assert.deepEqual(result.rows, [[7,'',false]]);
  await update(result.editHandles[0], null);
  result = await read();
  assert.deepEqual(result.rows, [[7,null,false]]);
  // Use a non-null original for the fake adapter's simple equality check.
  await update(result.editHandles[0], 'Before conflict');
  result = await read();
  await worker.call('query.run', {connectionId,sql:'simulate external update'});
  await assert.rejects(update(result.editHandles[0], 'Stale overwrite'), /changed or was deleted/);
  result = await read();
  assert.deepEqual(result.rows, [[7,'External change',false]]);
  const filtered = await worker.call('table.rows', {connectionId,schema:'public',name:'people',limit:20,offset:40,sort:{column:'name',direction:'desc'},filter:{column:'name',operator:'contains',value:'External'}});
  assert.match(filtered.readPlan.sql, /WHERE .* LIKE .* ORDER BY "name" DESC, "id" ASC/);
  assert.deepEqual(filtered.readPlan.params, ['%External%',21,40]);
  assert.equal(filtered.stableOrder,true);
  const updateRow = (handle, changes) => worker.call('table.updateRow',{connectionId,handle,changes});
  result = await read();
  await updateRow(result.editHandles[0],[{column:'name',value:'Saved together'},{column:'active',value:true}]);
  await assert.rejects(updateRow(result.editHandles[0],[{column:'name',value:'Duplicate'}]), /expired/);
  result = await read();
  assert.deepEqual(result.rows,[[7,'Saved together',true]]);
  await worker.call('query.run',{connectionId,sql:'change active'});
  await assert.rejects(updateRow(result.editHandles[0],[{column:'name',value:'Must not partially save'},{column:'active',value:false}]), /changed or was deleted/);
  result = await read();
  assert.deepEqual(result.rows,[[7,'Saved together',false]]);
  await assert.rejects(updateRow(result.editHandles[0],[{column:'name',value:'Must not save'},{column:'id',value:8}]), /read-only/);
  result = await read();
  assert.deepEqual(result.rows,[[7,'Saved together',false]]);
  const second = await worker.call('connection.open', { profileId: profile.id });
  await assert.rejects(worker.call('table.updateCell', {connectionId:second.connectionId,handle:result.editHandles[0],column:'name',value:'Wrong connection'}), /expired/);
  await worker.call('query.run', {connectionId,sql:'deny metadata'});
  assert.equal((await read()).stableOrder,false);
  await assert.rejects(worker.call('table.rows', {connectionId,schema:'public',name:'people',sort:{column:'name',direction:'asc'}}), /column details/);
  await worker.call('connection.close', {connectionId});
  await assert.rejects(update(result.editHandles[0], 'After close'), /closed/);
});
