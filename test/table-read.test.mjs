import assert from 'node:assert/strict';
import test from 'node:test';
import { tableReadPlan, tableColumnCapabilities } from '../backend/table-read.mjs';

const definition = { columns: [
  {name: 'tenant', type: 'varchar(10)', primaryKey: true},
  {name: 'id', type: 'integer', primaryKey: true},
  {name: 'name', type: 'varchar(200)'},
  {name: 'amount', type: 'numeric(20,4)'},
  {name: 'data', type: 'jsonb'},
  {name: 'tags', type: 'text[]'}
] };
for (const type of ['postgres', 'mysql', 'sqlserver', 'azure_sql']) {
  test(`${type}: default pages order by composite keys and append keys to chosen sort`, () => {
    const base = tableReadPlan(type, 'public', 'people', definition, {limit:100,offset:200});
    assert.deepEqual(base.order, [{column:'tenant',direction:'asc'},{column:'id',direction:'asc'}]);
    assert.equal(base.stableOrder, true);
    const sorted = tableReadPlan(type, 'public', 'people', definition, {limit:100,offset:200,sort:{column:'name',direction:'desc'}});
    assert.deepEqual(sorted.order.map(c => c.column), ['name','tenant','id']);
    assert.match(sorted.sql, /ORDER BY .*name.* DESC, .*tenant.* ASC, .*id.* ASC/);
    const sortedKey = tableReadPlan(type, 'public', 'people', definition, {limit:10,offset:0,sort:{column:'id',direction:'desc'}});
    assert.deepEqual(sortedKey.order, [{column:'id',direction:'desc'},{column:'tenant',direction:'asc'}]);
  });
  test(`${type}: filters are server-side, escaped as literals, and parameterized`, () => {
    const input = "O'Reilly_%[!'; DROP TABLE users; --";
    const read = tableReadPlan(type, 'public', 'people', definition, {limit:20,offset:40,filter:{column:'name',operator:'contains',value:input}});
    assert.equal(read.sql.includes(input), false);
    assert.match(read.sql, / WHERE .* LIKE .* ESCAPE '!'.* ORDER BY /);
    assert.equal(read.params[0], "%O'Reilly!_!%![!!'; DROP TABLE users; --%");
    if (type === 'mysql') { assert.match(read.sql, /LIMIT 21 OFFSET 40$/); assert.equal(read.params.length, 1); }
    else assert.deepEqual(read.params.slice(-2), type === 'postgres' ? [21,40] : [40,21]);
  });
}

test('empty text, NULL checks, numeric precision and quoted names survive planning', () => {
  const read = filter => tableReadPlan('postgres','public','people',definition,{limit:10,offset:0,filter});
  assert.equal(read({column:'name',operator:'equals',value:''}).params[0], '');
  const isNull = read({column:'name',operator:'isNull'});
  assert.match(isNull.sql, /"name" IS NULL/);
  assert.equal(isNull.params.length, 2);
  assert.match(read({column:'name',operator:'notNull'}).sql, /"name" IS NOT NULL/);
  assert.equal(read({column:'amount',operator:'greaterThan',value:'9007199254740993.1234'}).params[0], '9007199254740993.1234');
  const quoted = {columns:[{name:'a"b',type:'integer'}]};
  assert.match(tableReadPlan('postgres','we"ird','t"able',quoted,{limit:10,offset:0,sort:{column:'a"b',direction:'asc'}}).sql, /"we""ird"\."t""able" ORDER BY "a""b"/);
});

test('invalid columns, operators, directions, complex types and page injection fail closed', () => {
  for (const changes of [
    {sort:{column:'missing',direction:'asc'}}, {sort:{column:'name',direction:'asc; DELETE FROM t'}},
    {sort:{column:'data',direction:'asc'}}, {sort:{column:'tags',direction:'asc'}},
    {filter:{column:'name',operator:'constructor',value:'x'}}, {filter:{column:'name',operator:'equals',value:{}}},
    {filter:{column:'id',operator:'contains',value:'1'}}, {filter:{column:'name',operator:'equals',value:'x'.repeat(2001)}},
    {filter:{column:'name',operator:'equals',value:Infinity}}, {filter:{column:'name',operator:'equals',value:null}},
    {limit:'20; SELECT 1'}, {offset:-1}, {limit:1001}
  ]) assert.throws(() => tableReadPlan('postgres','public','people',definition,{limit:10,offset:0,...changes}), /Invalid/);
});

test('metadata fallback retains legacy browsing without falsely promising stable order', () => {
  const plan = tableReadPlan('sqlserver','dbo','view',null,{limit:10,offset:0});
  assert.match(plan.sql, /ORDER BY \(SELECT NULL\)/);
  assert.equal(plan.stableOrder,false);
  assert.equal(tableColumnCapabilities({type:'text'}, 'postgres').sortable, true);
  assert.equal(tableColumnCapabilities({type:'text'}, 'mysql').sortable, true);
  assert.equal(tableColumnCapabilities({type:'text'}, 'sqlserver').sortable, false);
  assert.equal(tableColumnCapabilities({type:'text[]'}, 'postgres').filterable, false);
});
