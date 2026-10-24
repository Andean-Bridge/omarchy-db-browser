import assert from 'node:assert/strict';
import test from 'node:test';
import { compareCatalogs, compareDefinitions, generateSqlServerScript, objectKey, previewSchemaDiffChange, selectSchemaDiffChanges, schemaDiffChangeReview } from '../backend/schema-diff.mjs';

const column = (name, typeName = 'int', other = {}) => ({ name, typeName, maxLength: 4,
  precision: 10, scale: 0, nullable: false, defaultDefinition: null, computedDefinition: null,
  collation: null, identity: false, sparse: false, rowguidcol: false, ...other });
const table = (columns, other = {}) => ({ columns, indexes: [], checks: [], foreignKeys: [],
  incomingForeignKeys: [], properties: {}, ...other });
const catalog = (schemas, objects) => ({ schemas: schemas.map(name => ({ name })),
  objects: objects.map(([schema, name, type]) => ({ schema, name, type })) });
const source = catalog(['dbo', 'sales'], [['dbo', 'customers', 'table'], ['sales', 'orders', 'table'], ['sales', 'open_orders', 'view']]);
const target = catalog(['dbo', 'sales'], [['dbo', 'customers', 'table'], ['sales', 'legacy', 'table'], ['sales', 'open_orders', 'view']]);
const selected = source.objects.map(objectKey);

test('selection stays within source catalog and notes target-only objects without selecting them', () => {
  const selection = compareCatalogs(source, target, ['sales'], [objectKey(source.objects[1])]);
  assert.equal(selection.selected.length, 1);
  assert.deepEqual(selection.targetOnly, [{ schema: 'sales', name: 'legacy', type: 'table' }]);
  assert.throws(() => compareCatalogs(source, target, ['sales'], [objectKey(source.objects[0])]), /Invalid schema diff selection/);
});

test('table columns ignore order and view definitions ignore outer whitespace and CREATE versus ALTER', () => {
  const src = catalog(['dbo'], [['dbo', 't', 'table'], ['dbo', 'v', 'view']]);
  const dst = catalog(['dbo'], [['dbo', 't', 'table'], ['dbo', 'v', 'view']]);
  const details = {
    [objectKey(src.objects[0])]: table([column('a'), column('b')]),
    [objectKey(src.objects[1])]: { definition: 'CREATE VIEW [dbo].[v] AS SELECT a FROM dbo.t', indexed: false }
  };
  const targetDetails = {
    [objectKey(src.objects[0])]: table([column('b'), column('a')]),
    [objectKey(src.objects[1])]: { definition: '\r\n ALTER VIEW [dbo].[v] AS SELECT a FROM dbo.t \r\n', indexed: false }
  };
  const result = compareDefinitions({ sourceCatalog: src, targetCatalog: dst, sourceDetails: details,
    targetDetails, selectedSchemas: ['dbo'], selectedObjects: src.objects.map(objectKey) });
  assert.equal(result.unchanged, 2);
  assert.equal(result.changes.length, 0);
});

test('script creates missing table with keys and indexes, alters a view, and never drops target-only objects', () => {
  const key = objectKey(source.objects[1]);
  const customers = objectKey(source.objects[0]);
  const view = objectKey(source.objects[2]);
  const sourceDetails = {
    [customers]: table([column('id')]),
    [key]: table([
      column('id', 'int', { identity: true, identitySeed: '1', identityIncrement: '1' }),
      column('customer_id'),
      column('status', 'nvarchar', { maxLength: 80, nullable: true })
    ], {
      indexes: [
        { name: 'PK_orders', type: 'CLUSTERED', constraintName: 'PK_orders', primaryKey: true, keys: [{ name: 'id', descending: false }], includes: [], disabled: false, partitioned: false },
        { name: 'IX_orders_status', type: 'NONCLUSTERED', constraintName: null, unique: false, keys: [{ name: 'status', descending: false }], includes: ['customer_id'], disabled: false, partitioned: false }
      ],
      foreignKeys: [{ name: 'FK_orders_customers', columns: ['customer_id'], referencedSchema: 'dbo', referencedTable: 'customers', referencedColumns: ['id'], deleteAction: 'NO_ACTION', updateAction: 'NO_ACTION' }]
    }),
    [view]: { definition: 'CREATE VIEW [sales].[open_orders] AS SELECT id FROM sales.orders', indexed: false }
  };
  const targetDetails = {
    [customers]: table([column('id')]),
    [view]: { definition: 'CREATE VIEW [sales].[open_orders] AS SELECT 1 AS id', indexed: false }
  };
  const comparison = compareDefinitions({ sourceCatalog: source, targetCatalog: target,
    sourceDetails, targetDetails, selectedSchemas: ['dbo', 'sales'], selectedObjects: selected });
  assert.equal(comparison.changes.length, 2);
  const script = generateSqlServerScript(comparison, { sourceName: 'Staging', targetName: 'Production',
    sourceDatabase: 'Stage', targetDatabase: 'Prod', targetCatalog: target });
  assert.equal(script.complete, true);
  assert.match(script.sql, /CREATE TABLE \[sales\]\.\[orders\]/);
  assert.match(script.sql, /CONSTRAINT \[PK_orders\] PRIMARY KEY CLUSTERED/);
  assert.match(script.sql, /CREATE NONCLUSTERED INDEX \[IX_orders_status\]/);
  assert.match(script.sql, /ADD CONSTRAINT \[FK_orders_customers\] FOREIGN KEY/);
  assert.match(script.sql, /ALTER VIEW \[sales\]\.\[open_orders\]/);
  assert.match(script.sql, /legacy/);
  assert.doesNotMatch(script.sql, /\bDROP\b/i);
});

test('table changes add nullable columns and widen unindexed types; unsafe changes remain manual', () => {
  const src = catalog(['dbo'], [['dbo', 'people', 'table']]);
  const dst = catalog(['dbo'], [['dbo', 'people', 'table']]);
  const key = objectKey(src.objects[0]);
  const sourceDetails = { [key]: table([
    column('name', 'nvarchar', { maxLength: 200, nullable: true }),
    column('email', 'nvarchar', { maxLength: 200, nullable: true }),
    column('age', 'int', { nullable: false })
  ]) };
  const targetDetails = { [key]: table([
    column('name', 'nvarchar', { maxLength: 100, nullable: true }),
    column('age', 'int', { nullable: true }),
    column('obsolete')
  ]) };
  const comparison = compareDefinitions({ sourceCatalog: src, targetCatalog: dst,
    sourceDetails, targetDetails, selectedSchemas: ['dbo'], selectedObjects: [key] });
  const script = generateSqlServerScript(comparison, { sourceName: 'Stage', targetName: 'Prod',
    sourceDatabase: 'Stage', targetDatabase: 'Prod', targetCatalog: dst });
  assert.match(script.sql, /ADD \[email\] \[nvarchar\]\(100\) NULL/);
  assert.match(script.sql, /ALTER COLUMN \[name\] \[nvarchar\]\(100\) NULL/);
  assert.equal(script.complete, false);
  assert.match(script.manual.join(' '), /age/);
  assert.doesNotMatch(script.sql, /DROP COLUMN/);
});

test('unsupported new table cannot produce a partial CREATE TABLE', () => {
  const src = catalog(['dbo'], [['dbo', 'special', 'table']]);
  const dst = catalog(['dbo'], []);
  const key = objectKey(src.objects[0]);
  const comparison = compareDefinitions({ sourceCatalog: src, targetCatalog: dst,
    sourceDetails: { [key]: table([column('id')], { properties: { temporal: true } }) }, targetDetails: {},
    selectedSchemas: ['dbo'], selectedObjects: [key] });
  const script = generateSqlServerScript(comparison, { sourceName: 'Stage', targetName: 'Prod',
    sourceDatabase: 'Stage', targetDatabase: 'Prod', targetCatalog: dst });
  assert.equal(script.complete, false);
  assert.doesNotMatch(script.sql, /CREATE TABLE \[dbo\]\.\[special\]/);
  assert.match(script.sql, /MANUAL CHANGES REQUIRED/);
});

test('new views follow their selected dependencies and missing dependencies require manual work', () => {
  const src = catalog(['dbo'], [['dbo', 'base', 'table'], ['dbo', 'v1', 'view'], ['dbo', 'v2', 'view']]);
  const dst = catalog(['dbo'], []);
  const details = {
    [objectKey(src.objects[0])]: table([column('id')]),
    [objectKey(src.objects[1])]: { definition: 'CREATE VIEW [dbo].[v1] AS SELECT id FROM dbo.base', indexed: false,
      dependencies: [{ referencedSchema: 'dbo', referencedName: 'base', referencedType: 'table' }] },
    [objectKey(src.objects[2])]: { definition: 'CREATE VIEW [dbo].[v2] AS SELECT id FROM dbo.v1', indexed: false,
      dependencies: [{ referencedSchema: 'dbo', referencedName: 'v1', referencedType: 'view' }] }
  };
  const comparison = compareDefinitions({ sourceCatalog: src, targetCatalog: dst,
    sourceDetails: details, targetDetails: {}, selectedSchemas: ['dbo'], selectedObjects: src.objects.map(objectKey) });
  const script = generateSqlServerScript(comparison, { sourceName: 'Stage', targetName: 'Prod',
    sourceDatabase: 'Stage', targetDatabase: 'Prod', targetCatalog: dst });
  assert.equal(script.complete, true);
  assert.ok(script.sql.indexOf('CREATE TABLE [dbo].[base]') < script.sql.indexOf('CREATE VIEW [dbo].[v1]'));
  assert.ok(script.sql.indexOf('CREATE VIEW [dbo].[v1]') < script.sql.indexOf('CREATE VIEW [dbo].[v2]'));
  const onlyView = compareDefinitions({ sourceCatalog: src, targetCatalog: dst,
    sourceDetails: details, targetDetails: {}, selectedSchemas: ['dbo'], selectedObjects: [objectKey(src.objects[1])] });
  const incomplete = generateSqlServerScript(onlyView, { sourceName: 'Stage', targetName: 'Prod',
    sourceDatabase: 'Stage', targetDatabase: 'Prod', targetCatalog: dst });
  assert.equal(incomplete.complete, false);
  assert.doesNotMatch(incomplete.sql, /CREATE VIEW \[dbo\]\.\[v1\]/);
});

test('checked differences alone reach the generated script and preview exposes source and target', () => {
  const src = catalog(['dbo', 'sales'], [['dbo', 'new_table', 'table'], ['sales', 'changed_table', 'table'], ['sales', 'changed_view', 'view']]);
  const dst = catalog(['sales'], [['sales', 'changed_table', 'table'], ['sales', 'changed_view', 'view']]);
  const [newKey, tableKey, viewKey] = src.objects.map(objectKey);
  const comparison = compareDefinitions({ sourceCatalog: src, targetCatalog: dst, selectedSchemas: ['dbo', 'sales'],
    selectedObjects: [newKey, tableKey, viewKey],
    sourceDetails: {
      [newKey]: table([column('id')]),
      [tableKey]: table([column('id'), column('extra', 'nvarchar', { maxLength: 40, nullable: true })]),
      [viewKey]: { definition: 'CREATE VIEW [sales].[changed_view] AS SELECT 2 AS id', indexed: false }
    },
    targetDetails: {
      [tableKey]: table([column('id')]),
      [viewKey]: { definition: 'CREATE VIEW [sales].[changed_view] AS SELECT 1 AS id', indexed: false }
    } });
  const options = { sourceName: 'Stage', targetName: 'Prod', sourceDatabase: 'Stage', targetDatabase: 'Prod', targetCatalog: dst };
  const onlyView = selectSchemaDiffChanges(comparison, [viewKey]);
  const script = generateSqlServerScript(onlyView, options);
  assert.match(script.sql, /ALTER VIEW \[sales\]\.\[changed_view\]/);
  assert.doesNotMatch(script.sql, /CREATE SCHEMA|CREATE TABLE|ALTER TABLE/);
  assert.deepEqual(onlyView.missingSchemas, []);
  const onlyNew = generateSqlServerScript(selectSchemaDiffChanges(comparison, [newKey]), options);
  assert.match(onlyNew.sql, /CREATE SCHEMA \[dbo\]/);
  assert.match(onlyNew.sql, /CREATE TABLE \[dbo\]\.\[new_table\]/);
  assert.doesNotMatch(onlyNew.sql, /changed_table|changed_view/);
  const preview = previewSchemaDiffChange(comparison, tableKey, options);
  assert.deepEqual(preview.columns.map(item => item.name), ['extra']);
  assert.match(preview.columns[0].after, /\[nvarchar\]\(20\) NULL/);
  assert.match(preview.sql, /ALTER TABLE \[sales\]\.\[changed_table\] ADD/);
  const viewPreview = previewSchemaDiffChange(comparison, viewKey, options);
  assert.match(viewPreview.viewDifference, /- CREATE VIEW .*SELECT 1 AS id/);
  assert.match(viewPreview.viewDifference, /\+ CREATE VIEW .*SELECT 2 AS id/);
  assert.throws(() => selectSchemaDiffChanges(comparison, []), /Select at least one/);
  assert.throws(() => selectSchemaDiffChanges(comparison, [viewKey, viewKey]), /Invalid schema diff selection/);
  assert.throws(() => selectSchemaDiffChanges(comparison, ['["sales","unknown"]']), /Invalid schema diff selection/);
});

function refreshFixture() {
  const src = catalog(['dbo'], [['dbo', 'items', 'table'], ['dbo', 'selected_view', 'view']]);
  const dst = catalog(['dbo'], [['dbo', 'items', 'table'], ['dbo', 'outer_view', 'view'], ['dbo', 'base_view', 'view'], ['dbo', 'selected_view', 'view'], ['dbo', 'bound_view', 'view'], ['dbo', 'unrelated', 'view']]);
  const dep = name => ({ referencedSchema: 'dbo', referencedName: name, referencedType: name === 'items' ? 'table' : 'view' });
  dst.objects.find(o => o.name === 'base_view').dependencies = [dep('items')];
  dst.objects.find(o => o.name === 'outer_view').dependencies = [dep('base_view')];
  Object.assign(dst.objects.find(o => o.name === 'bound_view'), { schemaBound: true, dependencies: [dep('items')] });
  const [tableKey, viewKey] = src.objects.map(objectKey);
  const comparison = compareDefinitions({ sourceCatalog: src, targetCatalog: dst, selectedSchemas: ['dbo'], selectedObjects: [tableKey, viewKey],
    sourceDetails: { [tableKey]: table([column('id'), column('extra', 'int', { nullable: true })]),
      [viewKey]: {definition:'CREATE VIEW dbo.selected_view AS SELECT extra FROM dbo.outer_view', dependencies:[dep('outer_view')]} },
    targetDetails: { [tableKey]: table([column('id')]), [viewKey]: {definition:'CREATE VIEW dbo.selected_view AS SELECT 1 AS id'} } });
  const options = { sourceName:'Stage', targetName:'Prod', sourceDatabase:'Stage', targetDatabase:'Prod', targetCatalog:dst };
  return { comparison, options, tableKey, viewKey };
}

test('refreshes excluded and unchanged target views before selected consumers, in dependency order', () => {
  const { comparison, options, tableKey, viewKey } = refreshFixture();
  const result = generateSqlServerScript(comparison, options);
  assert.equal(result.complete, true);
  assert.deepEqual(result.refreshedViews.map(v => v.name), ['base_view', 'outer_view']);
  assert.ok(result.sql.indexOf('ALTER TABLE') < result.sql.indexOf("N'[dbo].[base_view]'"));
  assert.ok(result.sql.indexOf("N'[dbo].[base_view]'") < result.sql.indexOf("N'[dbo].[outer_view]'"));
  assert.ok(result.sql.indexOf("N'[dbo].[outer_view]'") < result.sql.indexOf('ALTER VIEW dbo.selected_view'));
  assert.doesNotMatch(result.sql, /sp_refreshview[^\n]*bound_view|sp_refreshview[^\n]*unrelated|sp_refreshview[^\n]*selected_view/);
  const tableOnly = generateSqlServerScript(selectSchemaDiffChanges(comparison, [tableKey]), options);
  assert.equal(tableOnly.refreshedViews.length, 2);
  const viewOnly = generateSqlServerScript(selectSchemaDiffChanges(comparison, [viewKey]), options);
  assert.equal(viewOnly.refreshedViews.length, 0);
  assert.doesNotMatch(viewOnly.sql, /ALTER TABLE/);
});

test('disabled refreshes are manual work; unapplied table changes do not refresh views', () => {
  const { comparison, options, tableKey } = refreshFixture();
  const disabled = generateSqlServerScript(selectSchemaDiffChanges(comparison, [tableKey]), { ...options, scriptOptions:{refreshDependentViews:false} });
  assert.equal(disabled.complete, false);
  assert.equal(disabled.refreshedViews.length, 0);
  assert.match(disabled.manual.join(' '), /base_view.*refresh was disabled/);
  comparison.changes[0].columns = [{name:'id',action:'alter',source:column('id'),target:column('id', 'bigint')}];
  const unsafe = generateSqlServerScript(selectSchemaDiffChanges(comparison, [tableKey]), options);
  assert.equal(unsafe.complete, false);
  assert.equal(unsafe.refreshedViews.length, 0);
});

test('schema-bound column dependencies block widening while independent additions remain scriptable', () => {
  const entry = {schema:'dbo',name:'items',type:'table',status:'alter',notes:[],
    source:table([]),target:table([], {schemaBoundDependencies:[{columnName:'name'}]}),
    columns:[{name:'name',action:'alter',source:column('name','nvarchar',{maxLength:80,nullable:true}),target:column('name','nvarchar',{maxLength:40,nullable:true})},
      {name:'extra',action:'add',source:column('extra','int',{nullable:true})}]};
  const result = generateSqlServerScript({changes:[entry],missingSchemas:[],targetOnly:[]}, {targetCatalog:catalog(['dbo'],[['dbo','items','table']]),targetDatabase:'Prod'});
  assert.equal(result.complete, false);
  assert.match(result.sql, /ADD \[extra\]/);
  assert.doesNotMatch(result.sql, /ALTER COLUMN \[name\]/);
  assert.match(schemaDiffChangeReview(entry).join(' '), /schema-bound dependency/);
});

test('new-table options omit optional indexes, checks and foreign keys, preserving keys and defaults', () => {
  const source = table([column('id'),column('flag','int',{defaultName:'DF_flag',defaultDefinition:'(0)'})], {
    indexes:[{name:'PK_items',constraintName:'PK_items',primaryKey:true,type:'CLUSTERED',keys:[{name:'id'}]},
      {name:'IX_flag',type:'NONCLUSTERED',keys:[{name:'flag'}]}],
    checks:[{name:'CK_flag',definition:'([flag]>=(0))'}],
    foreignKeys:[{name:'FK_missing',columns:['id'],referencedSchema:'dbo',referencedTable:'missing',referencedColumns:['id']}] });
  const comparison = {changes:[{schema:'dbo',name:'items',type:'table',status:'create',source}],missingSchemas:[],targetOnly:[]};
  const options = {targetDatabase:'Prod',targetCatalog:catalog(['dbo'],[])};
  const result = generateSqlServerScript(comparison, {...options,scriptOptions:{includeIndexes:false,includeChecks:false,includeForeignKeys:false}});
  assert.equal(result.complete, true);
  assert.match(result.sql, /PK_items.*PRIMARY KEY/);
  assert.match(result.sql, /DF_flag.*DEFAULT/);
  assert.doesNotMatch(result.sql, /IX_flag|CK_flag|FK_missing/);
  assert.equal(generateSqlServerScript(comparison, options).complete, false);
  assert.throws(() => generateSqlServerScript(comparison, {...options,scriptOptions:{includeIndexes:'false'}}), /Invalid script options/);
  assert.throws(() => generateSqlServerScript(comparison, {...options,scriptOptions:{unknown:true}}), /Invalid script options/);
});


test('target-only column preview shows the existing definition and leaves it unchanged', () => {
  const src = catalog(['dbo'], [['dbo','items','table']]);
  const key = objectKey(src.objects[0]);
  const comparison = compareDefinitions({sourceCatalog:src,targetCatalog:src,selectedSchemas:['dbo'],selectedObjects:[key],
    sourceDetails:{[key]:table([column('id')])},targetDetails:{[key]:table([column('id'),column('legacy','nvarchar',{maxLength:80,nullable:true})])}});
  const preview = previewSchemaDiffChange(comparison,key,{targetCatalog:src,targetDatabase:'Prod'});
  assert.equal(preview.columns[0].action,'target-only');
  assert.match(preview.columns[0].before,/nvarchar/);
  assert.equal(preview.columns[0].after,'');
  assert.match(preview.notes.join(' '),/left unchanged/);
  assert.doesNotMatch(preview.sql,/ALTER TABLE/);
});
