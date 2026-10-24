import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, writeFile, readdir, stat, symlink, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { exportTable, csvValue, sqlValue } from '../backend/table-export.mjs';

const definition = { columns: [{name:'id',type:'integer',primaryKey:true,identity:true}, {name:'name',type:'text'},
  {name:'amount',type:'numeric(30,4)'}, {name:'computed',type:'text',generated:true}] };
async function setup(t) {
  const directory = await mkdtemp(path.join(tmpdir(), 'db-studio-export-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}
const options = { type:'postgres', schema:'public', name:'people', definition, format:'csv', columns:['id','name'] };

test('full export streams more than the grid cap and keeps long values, NULL, empty text, and CSV quoting', async t => {
  const directory = await setup(t), filePath = path.join(directory, 'people.csv');
  const value = 'a,"quote"\r\n' + 'é'.repeat(6000);
  const result = await exportTable({ ...options, filePath, filter:{column:'name',operator:'contains',value:"O'Reilly_%"},
    sort:{column:'name',direction:'desc'}, adapter:{
      async rows(schema, name, limit, offset, onReady, batch, plan) {
        assert.doesNotMatch(plan.sql, /\bLIMIT\b|\bOFFSET\b|\bFETCH NEXT\b/);
        assert.match(plan.sql, /SELECT "id", "name" FROM "public"\."people" WHERE "name" LIKE \$1.* ORDER BY "people"\."name" DESC, "people"\."id" ASC/);
        assert.deepEqual(plan.params, ["%O'Reilly!_!%%"]);
        assert.equal(batch, null);
        for (let i = 0; i < 1505; i++) plan.exportRow([i, i === 0 ? null : i === 1 ? '' : value]);
        return { rows:[], hasMore:false };
      }
    } });
  const contents = await readFile(filePath, 'utf8');
  assert.ok(contents.startsWith('"id","name"\r\n"0",\r\n"1",""\r\n'));
  assert.ok(contents.endsWith('"1504",' + csvValue(value, 'postgres') + '\r\n'));
  assert.equal(result.rowCount, 1505);
  assert.equal(result.columnCount, 2);
  assert.equal(result.bytesWritten, Buffer.byteLength(contents));
  assert.equal((await stat(filePath)).mode & 0o777, 0o600);
  assert.deepEqual(await readdir(directory), ['people.csv']);
});

test('SQL exports quote identifiers, preserve precision, and handle identities for each dialect', async t => {
  const directory = await setup(t);
  for (const type of ['postgres','sqlserver','azure_sql','mysql','cloudflare_d1']) {
    let plan;
    const filePath = path.join(directory, type + '.sql');
    await exportTable({ ...options, type, name:'peo"ple', format:'sql', columns:['id','name','amount'], filePath,
      adapter:{ async rows(...args) { plan = args[6]; plan.exportRow([7n,"O'Reilly \\ 💚",'9007199254740993.1234']); } } });
    const sql = await readFile(filePath, 'utf8');
    assert.match(sql, /INSERT INTO/);
    assert.doesNotMatch(sql, /CREATE TABLE|DROP TABLE/);
    assert.match(sql, /9007199254740993\.1234|393030373139393235343734303939332e31323334/);
    assert.doesNotMatch(plan.sql, /\bLIMIT\b|\bOFFSET\b|\bFETCH NEXT\b/);
    if (type === 'postgres') {
      assert.match(sql, /"peo""ple" \("id", "name", "amount"\) OVERRIDING SYSTEM VALUE/);
      assert.ok(sql.includes("E'O''Reilly \\\\ 💚'"));
    }
    if (type === 'sqlserver' || type === 'azure_sql') assert.match(sql, /SET IDENTITY_INSERT .* ON;[\s\S]*SET IDENTITY_INSERT .* OFF;/);
  }
  assert.equal(sqlValue(Buffer.from([0,255]), 'postgres', {type:'bytea'}), "decode('00ff', 'hex')");
  assert.equal(sqlValue('\\x00ff', 'postgres', {type:'bytea'}), "decode('00ff', 'hex')");
  assert.equal(sqlValue(Buffer.from([0,255]), 'mysql'), "X'00ff'");
  assert.equal(sqlValue(Buffer.from([0,255]), 'sqlserver'), '0x00ff');
  assert.equal(sqlValue([0,255], 'cloudflare_d1', {type:'BLOB'}), "X'00ff'");
  assert.equal(sqlValue(null,'postgres'),'NULL');
  assert.equal(sqlValue(true,'postgres'),'TRUE');
  assert.equal(sqlValue(false,'sqlserver'),'0');
  assert.equal(csvValue('', 'postgres'),'""');
  assert.equal(csvValue(null, 'postgres'),'');
  assert.throws(() => sqlValue(Infinity,'mysql'), /non-finite/);
  assert.throws(() => sqlValue({lat:1},'sqlserver'), /complex SQL Server/);
});

test('invalid selections, filters, formats and paths fail before reading data or creating a file', async t => {
  const directory = await setup(t);
  const base = { ...options, filePath:path.join(directory,'people.csv'), adapter:{async rows() { assert.fail('must not read'); }} };
  for (const changes of [ {columns:[]}, {columns:['missing']}, {columns:['id','id']}, {columns:['id; DROP TABLE people']},
    {filter:{column:'name',operator:'rawSQL',value:'1=1'}}, {format:'xml'}, {filePath:'people.csv'}, {filePath:path.join(directory,'people.sql')},
    {format:'sql',filePath:path.join(directory,'people.sql'),columns:['computed']} ]) {
    await assert.rejects(exportTable({...base,...changes}), /Invalid |Choose /);
  }
  assert.deepEqual(await readdir(directory), []);
});

test('failure, cancellation, timeout, and destination changes preserve existing files and remove partial exports', async t => {
  const directory = await setup(t), filePath = path.join(directory, 'people.csv');
  const base = { ...options, filePath, overwrite:true };
  for (const mode of ['failure','cancel','timeout','changed']) {
    await writeFile(filePath, 'original');
    let cancelled = false;
    await assert.rejects(exportTable({ ...base, timeoutMs:mode === 'timeout' ? 1 : 30000,
      checkCancelled() { if (cancelled) throw new Error('Query cancelled.'); },
      adapter:{async rows(...args) {
        const plan = args[6];
        plan.exportRow([1, 'x'.repeat(70000)]);
        if (mode === 'cancel') { cancelled = true; return; }
        if (mode === 'changed') { await writeFile(filePath, 'external change'); return; }
        if (mode === 'timeout') { await new Promise(resolve => setTimeout(resolve, 10)); return; }
        throw new Error('database connection failed');
      }}
    }), /Could not |Query cancelled|Query timed out/);
    assert.equal(await readFile(filePath, 'utf8'), mode === 'changed' ? 'external change' : 'original');
    assert.deepEqual(await readdir(directory), ['people.csv']);
  }
  await assert.rejects(exportTable({ ...base, overwrite:false, adapter:{} }), /already exists/);
  const linked = path.join(directory,'linked.csv');
  await symlink(filePath, linked);
  await assert.rejects(exportTable({...base,filePath:linked,adapter:{}}), /symbolic link/);
});
