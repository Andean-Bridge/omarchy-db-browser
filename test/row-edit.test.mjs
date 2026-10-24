import assert from 'node:assert/strict';
import test from 'node:test';
import { RowEditStore, editableColumn, planCellUpdate, planRowUpdate, commitSingleCell } from '../backend/row-edit.mjs';

const definition = { columns: [
  { name: 'tenant', type: 'varchar', primaryKey: true },
  { name: 'id', type: 'integer', primaryKey: true },
  { name: 'name', type: 'varchar', nullable: true },
  { name: 'computed', type: 'integer', generated: true },
  { name: 'blob', type: 'bytea' }
] };
const columns = definition.columns;
const snapshot = { schema: 'public', name: 'people', values: [{ value: 'a' }, { value: 7 }, { value: "Original's value" }, { value: 2 }, null] };

for (const type of ['postgres', 'mysql', 'sqlserver', 'azure_sql']) {
  test(`${type}: binds values and all composite key parts, preserving original value`, () => {
    const injected = "x'; DELETE FROM people; --";
    const plan = planCellUpdate(type, 'public', 'people', definition, columns, snapshot, 'name', injected);
    assert.equal(plan.sql.includes(injected), false);
    assert.deepEqual(plan.params, [injected, 'a', 7, "Original's value"]);
    assert.match(plan.sql, /UPDATE .* SET .* WHERE .*tenant.* AND .*id.* AND .*name/);
    if (type === 'mysql') assert.match(plan.sql, /AS BINARY/);
    if (type === 'sqlserver' || type === 'azure_sql') assert.match(plan.sql, /varbinary/);
  });
}

test('NULL, empty strings, identifier quoting, and column order remain distinct', () => {
  const originalNull = { ...snapshot, values: [snapshot.values[0], snapshot.values[1], { value: null }] };
  const plan = planCellUpdate('postgres', 'public', 'people', definition, columns, originalNull, 'name', '');
  assert.match(plan.sql, /"name" IS NULL$/);
  assert.deepEqual(plan.params, ['', 'a', 7]);
  const quoted = { ...definition, columns: definition.columns.map(c => c.name === 'name' ? { ...c, name: 'a"b' } : c) };
  const quotedPlan = planCellUpdate('postgres', 'public', 'people', quoted, quoted.columns, snapshot, 'a"b', 'ok');
  assert.match(quotedPlan.sql, /"a""b"/);
});

test('keys, generated columns, unsupported types, missing keys, and stale identity fail closed', () => {
  for (const name of ['tenant', 'id', 'computed', 'blob', 'missing']) {
    assert.throws(() => planCellUpdate('postgres', 'public', 'people', definition, columns, snapshot, name, 'x'), /read-only/);
  }
  const noKeys = { columns: definition.columns.map(c => ({ ...c, primaryKey: false })) };
  assert.throws(() => planCellUpdate('postgres', 'public', 'people', noKeys, columns, snapshot, 'name', 'x'), /primary key/);
  assert.throws(() => planCellUpdate('postgres', 'public', 'other', definition, columns, snapshot, 'name', 'x'), /does not match/);
  const noOriginal = { ...snapshot, values: [snapshot.values[0], snapshot.values[1], null] };
  assert.throws(() => planCellUpdate('postgres', 'public', 'people', definition, columns, noOriginal, 'name', 'x'), /original value/);
  assert.equal(editableColumn({ type: 'int', identity: true }), false);
  assert.equal(editableColumn({ type: 'varchar(10)', extra: 'STORED GENERATED' }), false);
  assert.equal(editableColumn({ type: 'timestamp' }), false);
});

test('invalid NULL, complex values, unsafe numeric input, and oversized edits are rejected', () => {
  const strict = { columns: definition.columns.map(c => ({ ...c, nullable: false })) };
  for (const value of [null, {}, [], Number.NaN, Number.MAX_SAFE_INTEGER + 1, 'x'.repeat(65537)]) {
    assert.throws(() => planCellUpdate('postgres', 'public', 'people', strict, columns, snapshot, 'name', value));
  }
});

test('row snapshots are bounded, preserve bigint, reject lossy values, and expire by connection', () => {
  let now = 0;
  const store = new RowEditStore({ now: () => now, ttlMs: 100, maxTotalBytes: 1000 });
  try {
    const batch = store.beginPage('connection-a', 'public', 'people');
    batch.captureRow([9007199254740993n, new Date(), Buffer.from('secret'), 9007199254740992, null, '', false]);
    assert.throws(() => store.snapshot('connection-a', batch.handlesForRows[0]), /expired/);
    batch.commit();
    const handle = batch.handlesForRows[0];
    assert.deepEqual(store.snapshot('connection-a', handle).values, [{ value: '9007199254740993' }, null, null, null, { value: null }, { value: '' }, { value: false }]);
    assert.throws(() => store.snapshot('connection-b', handle), /expired/);
    now = 101;
    assert.throws(() => store.snapshot('connection-a', handle), /expired/);
    const cancelled = store.beginPage('connection-a', 'public', 'people');
    cancelled.captureRow(['value']);
    cancelled.discard();
    assert.throws(() => store.snapshot('connection-a', cancelled.handlesForRows[0]), /expired/);
    const closed = store.beginPage('connection-a', 'public', 'people');
    closed.captureRow(['value']); closed.commit();
    store.clearConnection('connection-a');
    assert.throws(() => store.snapshot('connection-a', closed.handlesForRows[0]), /expired/);
  } finally { store.dispose(); }
});

for (const count of [0, 1, 2]) {
  test(`cell transaction ${count === 1 ? 'commits' : 'rolls back'} when ${count} rows match`, async () => {
    const calls = [];
    const transaction = {
      async begin() { calls.push('begin'); }, async commit() { calls.push('commit'); }, async rollback() { calls.push('rollback'); },
      async update() { calls.push('update'); return count; }
    };
    if (count === 1) assert.deepEqual(await commitSingleCell(transaction, {}), { updated: true });
    else await assert.rejects(commitSingleCell(transaction, {}), /changed or was deleted/);
    assert.deepEqual(calls, ['begin', 'update', count === 1 ? 'commit' : 'rollback']);
  });
}

test('driver failures roll back and preserve the original error', async () => {
  const calls = [];
  await assert.rejects(commitSingleCell({
    async begin() {}, async update() { throw new Error('permission denied'); },
    async commit() { calls.push('commit'); }, async rollback() { calls.push('rollback'); }
  }, {}), /permission denied/);
  assert.deepEqual(calls, ['rollback']);
});

for (const type of ['postgres', 'mysql', 'sqlserver', 'azure_sql']) {
  test(`${type}: saves multiple cells in one statement and checks every original`, () => {
    const extra = {name:'enabled',type:'boolean',nullable:false};
    const rowDefinition = {columns:[...columns,extra]};
    const rowSnapshot = {...snapshot,values:[...snapshot.values,{value:false}]};
    const changes = [{column:'name',value:null},{column:'enabled',value:true}];
    const plan = planRowUpdate(type,'public','people',rowDefinition,rowDefinition.columns,rowSnapshot,changes);
    assert.deepEqual(plan.params,[null,true,'a',7,"Original's value",false]);
    assert.match(plan.sql,/^UPDATE .* SET .*name.* = .*, .*enabled.* = .* WHERE .*tenant.* AND .*id.* AND .*name.* AND .*enabled/);
    assert.equal((plan.sql.match(/UPDATE /g) || []).length,1);
    const nullOriginal = {...rowSnapshot,values:rowSnapshot.values.map((entry,index) => index === 2 ? {value:null} : entry)};
    const nullPlan = planRowUpdate(type,'public','people',rowDefinition,rowDefinition.columns,nullOriginal,changes);
    assert.match(nullPlan.sql,/name["\]`]? IS NULL/);
    assert.deepEqual(nullPlan.params,[null,true,'a',7,false]);
  });
}

test('row edits reject malformed, duplicate, and unsafe changes before producing a plan', () => {
  for (const changes of [undefined,{},[],[null],[{column:'name',value:'a'},{column:'name',value:'b'}],
    [{column:'name',value:'valid'},{column:'computed',value:3}], [{column:'name',value:'valid'},{column:'blob',value:'unsafe'}]]) {
    assert.throws(() => planRowUpdate('postgres','public','people',definition,columns,snapshot,changes));
  }
  const noOriginal = {...snapshot,values:[...snapshot.values.slice(0,2),null]};
  assert.throws(() => planRowUpdate('postgres','public','people',definition,columns,noOriginal,[{column:'name',value:'new'}]), /original value/);
});
