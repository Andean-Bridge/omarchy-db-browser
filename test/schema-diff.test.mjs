import assert from 'node:assert/strict';
import test from 'node:test';
import { compareCatalogs, compareDefinitions, generateSqlServerScript, objectKey, previewSchemaDiffChange, selectSchemaDiffChanges } from '../backend/schema-diff.mjs';

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
