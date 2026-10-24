import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, cp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { WorkerClient } from '../backend/worker-client.mjs';

test('shared worker keeps session-only connections independent and closes connections opened during shutdown', async t => {
  const directory=await mkdtemp(path.join(tmpdir(),'db-studio-connection-lifecycle-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const backend=path.join(directory,'backend');
  const log=path.join(directory,'connections.jsonl');
  await cp(new URL('../backend',import.meta.url),backend,{recursive:true});
  const original=new URL('../backend/drivers.mjs',import.meta.url).href;
  await writeFile(path.join(backend,'drivers.mjs'),`
    export { boundedNumber, databaseName, identifier, queryError, tableReadError, openSwitchedDatabase } from ${JSON.stringify(original)};
    import { appendFile } from 'node:fs/promises';
    import { randomUUID } from 'node:crypto';
    const tasks=new Map();
    export async function openDatabase(profile) {
      if(profile.name==='Slow open') await new Promise(resolve=>setTimeout(resolve,120));
      const id=randomUUID();
      let closed=false;
      const heartbeat=setInterval(()=>{},1000);
      await appendFile(${JSON.stringify(log)},JSON.stringify({opened:id})+'\\n');
      return {id,profile,adapter:{
        async close() {
          closed=true;
          clearInterval(heartbeat);
          for(const [key,cancel] of tasks) if(key.startsWith(id)) cancel();
          await appendFile(${JSON.stringify(log)},JSON.stringify({closed:id})+'\\n');
        },
        async run(sql,limit,timeout,onReady) {
          if(closed) await appendFile(${JSON.stringify(log)},JSON.stringify({ranAfterClose:id})+'\\n');
          return new Promise((resolve,reject)=>{
            const key=id+sql;
            const timer=setTimeout(()=>{tasks.delete(key);resolve({columns:[{name:'connection'}],rows:[[id]],rowCount:1});},200);
            const cancel=()=>{clearTimeout(timer);tasks.delete(key);reject(new Error('Query cancelled.'));};
            tasks.set(key,cancel);onReady(cancel);
          });
        }
      }};
    }
  `);
  const worker=new WorkerClient({spawnWorker:()=>spawn(process.execPath,[path.join(backend,'worker.mjs')],{
    env:{...process.env,XDG_CONFIG_HOME:path.join(directory,'config')},stdio:['pipe','pipe','pipe']
  })});
  t.after(()=>worker.close());
  const save=name=>worker.call('profiles.save',{profile:{name,type:'postgres',host:'localhost',database:'fixture',user:'fixture',ssl:false},password:'fixture',savePassword:false});
  const {profile:a}=await save('Staging');
  const {profile:b}=await save('Production');
  assert.equal(a.hasStoredConnection,false);
  assert.equal(b.hasStoredConnection,false);
  const first=await worker.call('connection.open',{profileId:a.id});
  const second=await worker.call('connection.open',{profileId:b.id});
  assert.notEqual(first.connectionId,second.connectionId);
  const queryA=worker.call('query.run',{connectionId:first.connectionId,sql:'A'});
  // Install the rejection handler before cancellation can resolve asynchronously.
  const cancelled=assert.rejects(queryA,/cancelled|closed/);
  const queryB=worker.call('query.run',{connectionId:second.connectionId,sql:'B'});
  await new Promise(resolve=>setTimeout(resolve,30));
  await worker.call('connection.close',{connectionId:first.connectionId});
  await cancelled;
  assert.deepEqual((await queryB).rows,[[second.connectionId]]);
  const extra=await worker.call('connection.open',{profileId:b.id});
  assert.notEqual(extra.connectionId,second.connectionId);
  const closingQuery=worker.call('query.run',{connectionId:extra.connectionId,sql:'RACE'});
  const rejectedClose=assert.rejects(closingQuery,/closed|cancelled/);
  await worker.call('connection.close',{connectionId:extra.connectionId});
  await rejectedClose;
  const {profile:slow}=await save('Slow open');
  const late=worker.call('connection.open',{profileId:slow.id});
  const rejected=assert.rejects(late,/Connection is closed/);
  const exited=once(worker.child,'close');
  worker.child.stdin.end();
  await rejected;
  const code=await Promise.race([exited,new Promise((_,reject)=>{
    const timer=setTimeout(()=>reject(new Error('Worker leaked a connection during shutdown.')),1500);
    timer.unref();
  })]);
  assert.equal(code[0],0);
  const records=(await readFile(log,'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(records.some(row=>row.ranAfterClose),false);
  const opened=records.filter(row=>row.opened).map(row=>row.opened).sort();
  const closed=records.filter(row=>row.closed).map(row=>row.closed).sort();
  assert.equal(opened.length,4);
  assert.deepEqual(closed,opened);
});
