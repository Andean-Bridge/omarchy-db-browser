import assert from 'node:assert/strict';
import test from 'node:test';
import { generateTableScript, postgresCreateScript } from '../backend/table-scripts.mjs';
import { sqlServerCreateScript } from '../backend/schema-diff.mjs';
import { cloudflareD1 } from '../backend/cloudflare-d1.mjs';

const columns = [{name:'id',type:'integer',primaryKey:true,identity:true},
  {name:'tenant',type:'integer',primaryKey:true}, {name:'a"b`]\nSELECT',type:'text',nullable:true},
  {name:'created',type:'timestamp',default:'now()'}, {name:'computed',type:'text',generated:true}];
const adapter = (schema, name, cols = columns) => ({
  async objects(s) { assert.equal(s,schema); return [{schema,name,type:'table'}]; },
  async describe() { return {columns:cols}; },
  async createScript() { return 'CREATE TABLE complete (id integer PRIMARY KEY);'; },
  async run() { assert.fail('Generating scripts must never execute them'); }
});

test('INSERT and UPDATE quote names for every dialect, omit generated fields, and require placeholders', async () => {
  for (const type of ['sqlserver','azure_sql','postgres','mysql','cloudflare_d1']) {
    const a = adapter('odd"`]', 'ta"`]', columns.concat([{name:'serial',type:'int',extra:'auto_increment'}, {name:'gen',type:'int',extra:'STORED GENERATED'}]));
    const insert = (await generateTableScript(a,type,'odd"`]','ta"`]','insert')).sql;
    assert.match(insert,/<value_3>/);
    assert.doesNotMatch(insert,/computed|serial|\bgen\b/);
    assert.match(insert,/INSERT INTO/);
    assert.match(insert,/VALUES \(/);
    if (!['sqlserver','azure_sql'].includes(type)) assert.match(insert,/<value_4>/); // Timestamps are writable outside SQL Server.
    const update = (await generateTableScript(a,type,'odd"`]','ta"`]','update')).sql;
    assert.match(update,/WHERE .* = <key_1>\n  AND .* = <key_2>;/);
    assert.doesNotMatch(update,/SET .*tenant/);
    if (type === 'postgres') assert.ok(insert.includes('"odd""`]"."ta""`]"'));
    if (type === 'mysql') assert.ok(insert.includes('`odd"``]`.`ta"``]`'));
    if (type === 'sqlserver') assert.ok(insert.includes('[odd"`]]].[ta"`]]]'));
    // An identifier containing a newline must not escape the placeholder comment.
    assert.ok(insert.includes('-- <value_3>: a"b`] SELECT (text), nullable'));
  }
});

test('templates handle keyless tables, all-default inserts, rowversions and empty updates', async () => {
  const a = adapter('dbo','t',[{name:'id',type:'int',primaryKey:true,identity:true},{name:'rv',type:'rowversion'},{name:'ts',type:'timestamp'}]);
  assert.match((await generateTableScript(a,'sqlserver','dbo','t','insert')).sql,/DEFAULT VALUES/);
  await assert.rejects(generateTableScript(a,'sqlserver','dbo','t','update'),/no writable/);
  const keyless = adapter('public','t',[{name:'v',type:'text'}]);
  assert.match((await generateTableScript(keyless,'postgres','public','t','update')).sql,/WHERE <row_condition>;/);
  assert.match((await generateTableScript(adapter('db','t',[]),'mysql','db','t','alter')).sql,/ADD COLUMN <column_name> <data_type>/);
  assert.match((await generateTableScript(a,'sqlserver','dbo','t','alter')).sql,/ADD <column_name>/);
  assert.match((await generateTableScript(adapter('db','t',[{name:'id',extra:'auto_increment'}]),'mysql','db','t','insert')).sql,/\(\) VALUES \(\)/);
});

test('CREATE preserves complete DDL, rejects unavailable or oversized definitions and non-table objects', async () => {
  const a = adapter('public','t');
  assert.equal((await generateTableScript(a,'postgres','public','t','create')).sql,'CREATE TABLE complete (id integer PRIMARY KEY);\n');
  await assert.rejects(generateTableScript(a,'postgres','public','t','drop'),/Invalid/);
  a.createScript = async () => '';
  await assert.rejects(generateTableScript(a,'postgres','public','t','create'),/complete CREATE/);
  a.createScript = async () => 'x'.repeat(200001);
  await assert.rejects(generateTableScript(a,'postgres','public','t','create'),/editor limit/);
  a.objects = async () => [{schema:'public',name:'t',type:'view'}];
  await assert.rejects(generateTableScript(a,'postgres','public','t','create'),/existing table/);
});

test('SQL Server CREATE includes exact types, identity, computed columns, defaults, keys, checks, indexes and foreign keys', () => {
  const definition = {columns:[{name:'id',typeName:'int',identity:true,identitySeed:'10',identityIncrement:'2'},
    {name:'name',typeName:'nvarchar',maxLength:80,nullable:true,defaultName:'DF_name',defaultDefinition:"N'ok'"},
    {name:'calc',typeName:'int',computedDefinition:'([id]+1)',persisted:true}],
    indexes:[{name:'PK_t',constraintName:'PK_t',type:'CLUSTERED',primaryKey:true,keys:[{name:'id'}]},
      {name:'IX_t',type:'NONCLUSTERED',keys:[{name:'name',descending:true}],includes:['id'],filterDefinition:'[name] IS NOT NULL'}],
    checks:[{name:'CK_id',definition:'([id]>0)'}], foreignKeys:[{name:'FK_t',columns:['id'],referencedSchema:'dbo',referencedTable:'parent',referencedColumns:['id'],deleteAction:'CASCADE'}]};
  const sql = sqlServerCreateScript('dbo','t]',definition);
  for (const text of ['[dbo].[t]]]', 'IDENTITY(10,2)', '[nvarchar](40)', "DEFAULT N'ok'", 'AS ([id]+1) PERSISTED',
    'PRIMARY KEY CLUSTERED', 'CHECK ([id]>0)', 'CREATE NONCLUSTERED INDEX', 'INCLUDE ([id])', 'WHERE [name] IS NOT NULL', 'REFERENCES [dbo].[parent]', 'ON DELETE CASCADE']) assert.ok(sql.includes(text),text);
  assert.throws(() => sqlServerCreateScript('dbo','t',{...definition,properties:{temporal:1}}),/complete CREATE/);
});

test('PostgreSQL CREATE reconstructs sequences, identity, generated columns, constraints and independent indexes using only catalog reads', async () => {
  const calls = [];
  const seq = {sequenceSchema:'public',sequenceName:'t_id_seq',sequenceType:'integer',seqstart:'7',seqincrement:'2',seqmin:'1',seqmax:'2147483647',seqcache:'1',seqcycle:false};
  const results = [[{relkind:'r',relreplident:'d',relpersistence:'u',reloptions:['fillfactor=80'],tablespace:'fast'}],
    [{name:'id',type:'integer',notNull:true,expression:"nextval('public.t_id_seq'::regclass)",...seq},
      {name:'identity',type:'integer',identity:'a',...seq,sequenceName:'t_identity_seq'},
      {name:'calc',type:'integer',generated:'s',expression:'id + 1'},
      {name:'label',type:'character varying(30)',collation:'"pg_catalog"."C"',expression:"'ok'::text"}],
    [{name:'PK_t',definition:'PRIMARY KEY (id)'},{name:'FK_t',definition:'FOREIGN KEY (id) REFERENCES public.parent(id)'}],
    [{definition:'CREATE INDEX ix_t ON public.t USING btree (label)',valid:true}]];
  const sql = await postgresCreateScript(async (sql,params) => { calls.push(sql); assert.deepEqual(params,['public','t']); return results.shift(); },'public','t');
  for (const text of ['CREATE SEQUENCE "public"."t_id_seq" AS integer START WITH 7 INCREMENT BY 2', 'CREATE UNLOGGED TABLE "public"."t"',
    'GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME "public"."t_identity_seq"', 'GENERATED ALWAYS AS (id + 1) STORED',
    'COLLATE "pg_catalog"."C"', 'CONSTRAINT "PK_t" PRIMARY KEY (id)', 'FOREIGN KEY (id)',
    'WITH (fillfactor=80) TABLESPACE "fast"', 'OWNED BY "public"."t"."id"', 'CREATE INDEX ix_t']) assert.ok(sql.includes(text),text);
  assert.equal(calls.length,4);
  for (const relation of [{relkind:'p'},{relkind:'r',triggers:true},{relkind:'r',relrowsecurity:true}]) {
    await assert.rejects(postgresCreateScript(async () => [{relreplident:'d',...relation}],'public','t'),/complete CREATE/);
  }
});

test('D1 CREATE reads original table SQL and includes indexes and triggers without generated autoindexes', async () => {
  const profile = {name:'Fixture',type:'cloudflare_d1',accountId:'a'.repeat(32),databaseId:'12345678-1234-1234-1234-123456789abc'};
  const adapter = await cloudflareD1(profile,'fixture-token',{fetchApi:async (url,options) => {
    if (options.method === 'GET') return Response.json({success:true,result:{name:'fixture'}});
    const {sql,params} = JSON.parse(options.body);
    assert.ok(sql.startsWith('SELECT type, sql FROM main.sqlite_schema'));
    assert.deepEqual(params,["t'able"]);
    return Response.json({success:true,result:[{success:true,results:{columns:['type','sql'],rows:[
      ['table',`CREATE TABLE "t'able" (id INTEGER PRIMARY KEY, name TEXT UNIQUE) STRICT`],
      ['index',`CREATE INDEX ix_t ON "t'able"(name)`],
      ['trigger',`CREATE TRIGGER trg AFTER INSERT ON "t'able" BEGIN SELECT 1; END`]
    ]}}]});
  }});
  const sql = await adapter.createScript('main',"t'able");
  assert.match(sql,/STRICT;/);
  assert.match(sql,/CREATE INDEX ix_t/);
  assert.match(sql,/CREATE TRIGGER trg/);
  await adapter.close();
});
