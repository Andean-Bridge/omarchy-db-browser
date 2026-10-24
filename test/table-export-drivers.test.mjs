import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, cp, writeFile, readFile, rm, readdir } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { exportTable } from '../backend/table-export.mjs';

// Keep the real adapters' streaming, cancellation and error lifecycles. Only
// their network drivers are replaced, so no saved profile or database is used.
test('native database adapters export raw rows beyond display limits and propagate sink errors and cancellation', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'db-studio-export-drivers-'));
  t.after(() => rm(directory,{recursive:true,force:true}));
  await cp(new URL('../backend',import.meta.url),path.join(directory,'backend'),{recursive:true});
  const fixture = path.join(directory,'driver-fixture.mjs');
  await writeFile(fixture, `
    import { EventEmitter } from 'node:events';
    export const state = { queries:[], released:[], destroyed:0 };
    const fields = ['id','name','amount','created_at','payload'].map(name => ({name,type:{name:'text'},dataTypeID:25,columnType:253}));
    function stream(emitter, event, options) {
      state.queries.push(options);
      let stopped = false, index = 0;
      const operation = { cancel() { if (!stopped) { stopped = true; setImmediate(() => emitter.emit('error',new Error('cancelled by server'))); } } };
      state.active = operation;
      setImmediate(function next() {
        if (stopped) return;
        if (index === 0) { emitter.emit('recordset',fields); emitter.emit('fields',fields); }
        for (let n=0;n<100 && index<1505 && !stopped;n++,index++) {
          emitter.emit(event,[index,'x'.repeat(6000),'9007199254740993.1234','2026-10-20T12:34:56.1234567',Buffer.from([0,255])],{fields});
        }
        if (stopped) return;
        if (index < 1505) return setImmediate(next);
        stopped = true;
        emitter.emit('end',{fields}); emitter.emit('done');
      });
      return operation;
    }
    class ConnectionPool { async connect() {} async close() {} }
    class Request extends EventEmitter {
      input() {} cancel() { this.operation?.cancel(); }
      query(sql) {
        return new Promise((resolve,reject) => {
          this.once('done',resolve); this.once('error',reject);
          this.operation = stream(this,'row',{sql});
        });
      }
    }
    class Query extends EventEmitter { constructor(options) { super(); this.options = options; } }
    class Pool extends EventEmitter {
      async connect() { return {
        processID:7, release(destroy) { state.released.push(destroy); },
        query(query) {
          if (typeof query === 'string') { state.queries.push(query); return Promise.resolve({}); }
          stream(query,'row',query.options);
        }
      }; }
      async query(sql) { if (sql.includes('pg_cancel_backend')) state.active?.cancel(); return {}; }
      async end() {}
    }
    function createPool() { return {
      getConnection(callback) { callback(null, {
        threadId:7,
        execute(options) { const query = new EventEmitter(); stream(query,'result',options); return query; },
        destroy() { state.destroyed++; }
      }); },
      promise() { return {
        async getConnection() { return {release(){}}; },
        async end() {},
        async query(sql) { if (typeof sql === 'string' && sql.includes('KILL QUERY')) state.active?.cancel(); return [[]]; }
      }; },
      end(callback) { callback?.(); }
    }; }
    export default {ConnectionPool,Request,Pool,Query,createPool};
  `);
  for (const name of ['mssql','pg','mysql2']) {
    const modulePath = path.join(directory,'node_modules',name);
    await mkdir(modulePath,{recursive:true});
    await writeFile(path.join(modulePath,'package.json'),JSON.stringify({name,type:'module',main:'index.js'}));
    await writeFile(path.join(modulePath,'index.js'),`export {default} from ${JSON.stringify(pathToFileURL(fixture).href)};`);
  }
  const { openDatabase } = await import(pathToFileURL(path.join(directory,'backend/drivers.mjs')).href);
  const { state } = await import(pathToFileURL(fixture).href);
  for (const type of ['sqlserver','postgres','mysql']) {
    const {adapter} = await openDatabase({type,host:'localhost',database:'fixture',port:1,user:'fixture',ssl:false},'fixture');
    try {
      const columns = [{name:'id',type:'integer',primaryKey:true},{name:'name',type:'text'},{name:'amount',type:'numeric'},
        {name:'created_at',type:'datetime2'},{name:'payload',type:type==='postgres'?'bytea':'varbinary'}];
      const filePath = path.join(directory,type + '.csv');
      const options = {adapter,type,schema:'public',name:'people',definition:{columns},format:'csv',columns:columns.map(column => column.name),sort:{column:'amount',direction:'desc'},filePath,timeoutMs:30000};
      state.queries = [];
      const result = await exportTable(options);
      assert.equal(result.rowCount,1505,type);
      const csv = await readFile(filePath,'utf8');
      assert.ok(csv.includes('"1504",' + '"' + 'x'.repeat(6000) + '"'),type);
      assert.ok(csv.includes('"9007199254740993.1234","2026-10-20T12:34:56.1234567","0x00ff"'),type);
      const query = state.queries.find(query => typeof query === 'object');
      assert.doesNotMatch(query.sql || query.text,/\bLIMIT\b|\bOFFSET\b|FETCH NEXT/);
      if (type === 'sqlserver') {
        assert.match(query.sql,/CONVERT\(varchar\(100\), \[amount\], 2\)/);
        assert.match(query.sql,/ORDER BY \[people\]\.\[amount\] DESC/);
      }
      if (type === 'postgres') {
        assert.equal(query.types.getTypeParser(1184)('2026-10-20T12:34:56.1234567'),'2026-10-20T12:34:56.1234567');
        assert.ok(state.queries.includes('SET statement_timeout TO 30000'));
        assert.ok(state.queries.includes('SET statement_timeout TO 15000'));
      }
      if (type === 'mysql') {
        assert.equal(query.dateStrings,true);
        const json = '{"amount":9007199254740993.1234}';
        assert.equal(query.typeCast({type:'JSON',string:encoding => { assert.equal(encoding,'utf8'); return json; }},() => assert.fail('JSON must remain text')),json);
        assert.equal(query.typeCast({type:'INTEGER'},() => 7),7);
      }
      // Throw from a raw sink after the temporary output has received data.
      // Adapter-internal cancellation must not turn that failure into success.
      let count = 0;
      await assert.rejects(exportTable({...options,overwrite:true,checkCancelled() { if (++count > 110) throw new Error('Could not write: disk full.'); }}),/disk full/,type);
      assert.equal(await readFile(filePath,'utf8'),csv,type);
      let cancel;
      const cancelled = exportTable({...options,overwrite:true,onReady(fn) { cancel = fn; setImmediate(fn); }});
      await assert.rejects(cancelled,/Query cancelled/,type);
      assert.equal(typeof cancel,'function');
      assert.equal(await readFile(filePath,'utf8'),csv,type);
      assert.ok(!(await readdir(directory)).some(name => name.endsWith('.tmp')));
    } finally { await adapter.close(); }
  }
});
