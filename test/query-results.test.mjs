import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, cp, mkdir, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { QueryResults } from '../backend/query-results.mjs';
import { sqlServerBatches } from '../backend/sql-batches.mjs';
import { CellValueStore } from '../backend/cell-values.mjs';

test('GO separates SQL Server batches without touching multiline strings, quoted names, or nested comments', () => {
  const sql = "SELECT 'first\nGO\nlast', [odd\nGO\nname], \"other\nGO\nname\";\n/* outer\n/* nested */\nGO\n*/\nGO -- separator\nSELECT 'it''s GO';\ngo\r\nSELECT 3;\nGO\n";
  const batches = sqlServerBatches(sql);
  assert.equal(batches.length, 3);
  assert.ok(batches[0].sql.includes('/* nested */\nGO\n*/'));
  assert.equal(batches[1].sql.trim(), "SELECT 'it''s GO';");
  assert.equal(batches[1].line, 13);
  assert.equal(batches[2].sql.trim(), 'SELECT 3;');
  assert.throws(() => sqlServerBatches('SELECT 1\nGO 20\nSELECT 2'), /repeat counts/);
});

test('all result sets share the display budget and shortened values keep independent row references', () => {
  const store = new CellValueStore();
  try {
    const batch = store.begin('fixture');
    const results = new QueryResults(1000, batch);
    const first = results.begin([{ name: 'value' }]);
    const second = results.begin([{ name: 'value' }]);
    results.row(first, ['a'.repeat(5000)]);
    results.row(second, ['b'.repeat(5000)]);
    batch.commit();
    assert.equal(first.cellRefs[0].row, 0);
    assert.equal(second.cellRefs[0].row, 0);
    assert.equal(store.get('fixture', second.cellRefs[0].handle).text, 'b'.repeat(5000));
    const row = Array(100).fill('x'.repeat(4000));
    for (let i = 0; i < 100; i++) results.row(first, row);
    const last = results.begin([{ name: 'last' }]);
    for (let i = 0; i < 100; i++) results.row(last, row);
    assert.ok(results.budget.bytes <= 5 * 1024 * 1024);
    assert.ok(first.hasMore && last.hasMore);
    assert.ok(first.rows.length < 100 && last.rows.length < 100);
    for (let i = 0; i < 110; i++) results.begin([{ name: 'empty' }]);
    const response = results.finish();
    assert.equal(response.resultSets.length, 100);
    assert.match(response.message, /13 additional result sets omitted/);
  } finally { store.dispose(); }
});

// Replace network clients only; exercise the production adapters and their
// real event contracts, including empty sets and statement completion metadata.
test('database adapters preserve all results after row caps, DML, and empty SELECTs; cancellation and errors still reject', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'db-studio-query-drivers-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await cp(new URL('../backend', import.meta.url), path.join(directory, 'backend'), { recursive: true });
  const fixture = path.join(directory, 'fixture.mjs');
  await writeFile(fixture, `
    import { EventEmitter } from 'node:events';
    export const state = { statements:[], calls:[], cancelled:0, acquired:0, released:0, failed:false };
    const fields = names => names.map(name => ({name,type:{name:'text'},dataTypeID:25,columnType:253}));
    function stream(emitter, type) {
      let stopped = false;
      const cancel = () => { if (stopped) return; stopped = true; state.cancelled++; setImmediate(() => {
        emitter.emit('error', Object.assign(new Error('cancelled'), {code:'ECANCEL'}));
        emitter.emit('done', {rowsAffected:[]});
      }); };
      state.cancel = cancel;
      setImmediate(() => {
        if (stopped) return;
        if (state.failed) {
          stopped = true;
          emitter.emit('error', Object.assign(new Error('later statement failed'), {lineNumber:2}));
          emitter.emit('done', {rowsAffected:[]});
          return;
        }
        const complete = [], affected = [];
        for (const statement of state.statements) {
          const meta = {fields:fields(statement.columns || []),rowCount:statement.columns ? statement.rows.length : statement.affected,command:statement.columns?'SELECT':'UPDATE'};
          complete.push(meta);
          affected.push(meta.rowCount);
          if (statement.columns) {
            if (type === 'sqlserver') emitter.emit('recordset',meta.fields);
            if (type === 'mysql') emitter.emit('fields',meta.fields);
            for (const row of statement.rows) {
              if (stopped) return;
              emitter.emit(type === 'mysql' ? 'result' : 'row',row,meta);
            }
          } else if (type === 'mysql') {
            emitter.emit('fields',undefined);
            emitter.emit('result',{affectedRows:statement.affected});
          }
        }
        stopped = true;
        if (type === 'sqlserver') emitter.emit('done',{rowsAffected:affected});
        else emitter.emit('end',type === 'postgres' ? complete : undefined);
      });
      return cancel;
    }
    class ConnectionPool {
      config = {}; connected = true;
      async connect() {} async close() {}
      async acquire() { state.acquired++; return {session:'reserved'}; }
      release() { state.released++; }
    }
    class Request extends EventEmitter {
      constructor(parent) { super(); this.parent = parent; }
      cancel() { this.stop?.(); }
      query(sql) { return this.run(sql,'query'); }
      batch(sql) { return this.run(sql,'batch'); }
      run(sql,method) {
        state.calls.push({sql,method,parent:this.parent});
        return new Promise(resolve => {
          this.once('done',resolve);
          this.stop = stream(this,'sqlserver');
        });
      }
    }
    class Query extends EventEmitter { constructor(options) { super(); this.options = options; } }
    class Pool extends EventEmitter {
      async connect() { return {
        processID:7, release() {},
        query(query) {
          if (typeof query === 'string') return Promise.resolve({});
          state.calls.push(query.options); stream(query,'postgres');
        }
      }; }
      async query() { state.cancel?.(); }
      async end() {}
    }
    function createPool(config) { state.mysqlConfig = config; return {
      getConnection(callback) { callback(null, {
        threadId:7, destroy() {},
        query(options) { state.calls.push(options); const query = new EventEmitter(); stream(query,'mysql'); return query; }
      }); },
      promise() { return {
        async getConnection() { return {release(){}}; },
        async query() { state.cancel?.(); }, async end() {}
      }; }
    }; }
    export default {ConnectionPool,Request,Pool,Query,createPool};
  `);
  for (const name of ['mssql', 'pg', 'mysql2']) {
    const modulePath = path.join(directory, 'node_modules', name);
    await mkdir(modulePath, { recursive: true });
    await writeFile(path.join(modulePath, 'package.json'), JSON.stringify({ name, type: 'module', main: 'index.js' }));
    await writeFile(path.join(modulePath, 'index.js'), `export {default} from ${JSON.stringify(pathToFileURL(fixture).href)};`);
  }
  const { openDatabase } = await import(pathToFileURL(path.join(directory, 'backend/drivers.mjs')).href);
  const { state } = await import(pathToFileURL(fixture).href);
  for (const type of ['sqlserver', 'postgres', 'mysql']) {
    const { adapter } = await openDatabase({ type, host: 'localhost', database: 'fixture', user: 'fixture', ssl: false }, 'fixture');
    try {
      state.statements = [
        { columns: ['empty'], rows: [] },
        { affected: 4 },
        { columns: ['id'], rows: [[1], [2], [3]] },
        { columns: ['id', 'id'], rows: [[9, 10]] },
        { columns: ['last'], rows: [] }
      ];
      state.calls = []; state.cancelled = 0;
      const result = await adapter.run('fixture SQL', 2, 1000, () => {});
      assert.deepEqual(result.resultSets.map(set => set.columns.map(column => column.name)), [['empty'], ['id'], ['id', 'id'], ['last']], type);
      assert.deepEqual(result.resultSets.map(set => set.rows), [[], [[1], [2]], [[9, 10]], []], type);
      assert.deepEqual(result.resultSets.map(set => set.hasMore), [false, true, false, false], type);
      assert.equal(result.affectedRows, 4, type);
      assert.equal(state.cancelled, 0, type);
      if (type === 'mysql') assert.equal(state.mysqlConfig.multipleStatements, true);
      state.statements = [{ affected: 7 }];
      assert.equal((await adapter.run('UPDATE fixture', 2, 1000, () => {})).rowCount, 7, type);
      let cancel;
      const running = adapter.run('fixture SQL', 2, 1000, fn => { cancel = fn; setImmediate(fn); });
      await assert.rejects(running, /Query cancelled/, type);
      assert.equal(typeof cancel, 'function');
      state.failed = true;
      await assert.rejects(adapter.run('fixture SQL', 2, 1000, () => {}), /later statement failed/, type);
      state.failed = false;
      if (type === 'sqlserver') {
        state.calls = []; state.acquired = 0; state.released = 0;
        const response = await adapter.run('CREATE TABLE #fixture(id int);\nGO\nSELECT * FROM #fixture;', 2, 1000, () => {});
        assert.equal(response.affectedRows, 14);
        assert.equal(state.calls.length, 2);
        assert.ok(state.calls.every(call => call.method === 'batch'));
        assert.equal(state.calls[0].parent, state.calls[1].parent);
        assert.equal(state.acquired, 1); assert.equal(state.released, 1);
        state.failed = true;
        await assert.rejects(adapter.run('SELECT broken\nGO\nSELECT 2', 2, 1000, () => {}), /line 2/);
        assert.equal(state.released, 2);
        state.failed = false;
      }
    } finally { await adapter.close(); }
  }
});
