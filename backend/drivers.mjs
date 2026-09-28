import { randomUUID } from 'node:crypto';

const MAX_CELL_LENGTH = 4096;
const MAX_RESULT_BYTES = 5 * 1024 * 1024;

export function boundedNumber(value, fallback, min, max, label) {
  if (value === undefined || value === null || value === '') return fallback;
  const number = Number(value);
  if (!Number.isInteger(number) || number < min || number > max) throw new Error(`${label} must be between ${min} and ${max}.`);
  return number;
}

export function identifier(value, label) {
  if (typeof value !== 'string' || !value || value.length > 255 || /[\x00-\x1f]/.test(value)) {
    throw new Error(`Invalid ${label}.`);
  }
  return value;
}

export function databaseName(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 128 || /[\x00-\x1f]/.test(value)) {
    throw new Error('Invalid database name.');
  }
  return value;
}

const sqlIdentifier = value => `[${identifier(value, 'identifier').replaceAll(']', ']]')}]`;
const pgIdentifier = value => `"${identifier(value, 'identifier').replaceAll('"', '""')}"`;
const myIdentifier = value => `\`${identifier(value, 'identifier').replaceAll('`', '``')}\``;

function cellDetail(value) {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return value.toISOString();
  if (Buffer.isBuffer(value)) {
    const suffix = value.length > 4096 ? `… (${value.length} bytes)` : '';
    return value.length > 4096
      ? { preview: `0x${value.subarray(0, 4096).toString('hex')}${suffix}`, byteLength: value.length }
      : `0x${value.toString('hex')}`;
  }
  if (typeof value === 'bigint') return value.toString();
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  let text;
  if (typeof value === 'string') text = value;
  else {
    try { text = JSON.stringify(value); }
    catch { text = String(value); }
    if (typeof text !== 'string') text = String(value);
  }
  return text.length > MAX_CELL_LENGTH
    ? { preview: text.slice(0, MAX_CELL_LENGTH) + '…', text, byteLength: Buffer.byteLength(text, 'utf8') }
    : text;
}

export function cell(value) {
  const detail = cellDetail(value);
  return detail && typeof detail === 'object' && 'preview' in detail ? detail.preview : detail;
}

export function appendRow(rows, raw, budget, cellRefs = [], cellBatch = null) {
  const details = raw.map(cellDetail);
  const mapped = details.map(detail => detail && typeof detail === 'object' && 'preview' in detail ? detail.preview : detail);
  const rowIndex = rows.length;
  const refBytes = details.reduce((size, detail, columnIndex) => {
    if (!detail || typeof detail !== 'object' || !('preview' in detail)) return size;
    return size + Buffer.byteLength(JSON.stringify({
      row: rowIndex, column: columnIndex,
      handle: '00000000-0000-0000-0000-000000000000',
      byteLength: detail.byteLength, complete: false
    })) + 1;
  }, 0);
  const bytes = Buffer.byteLength(JSON.stringify(mapped)) + refBytes;
  if (budget.bytes + bytes > MAX_RESULT_BYTES) return false;
  budget.bytes += bytes;
  rows.push(mapped);
  details.forEach((detail, columnIndex) => {
    if (!detail || typeof detail !== 'object' || !('preview' in detail)) return;
    const handle = detail.text !== undefined ? cellBatch?.capture(detail.text, detail.byteLength) ?? null : null;
    cellRefs.push({ row: rowIndex, column: columnIndex, handle, byteLength: detail.byteLength, complete: false });
  });
  return true;
}

function oversizedRowError() {
  const error = new Error('Could not load table data: A row exceeds the 5 MB display limit.');
  error.code = 'ROW_TOO_LARGE';
  return error;
}

function column(name, type) {
  return { name: String(name), ...(type ? { type: String(type) } : {}) };
}

async function sqlserver(profile, password) {
  let mssql;
  try { mssql = (await import('mssql')).default; }
  catch { throw new Error('SQL Server driver is missing. Run npm ci --omit=dev.'); }
  const azureCatalog = profile.type === 'azure_sql' || profile.host.toLowerCase().endsWith('.database.windows.net');
  const pool = new mssql.ConnectionPool({
    server: profile.host,
    port: profile.port,
    database: profile.database,
    user: profile.user,
    password,
    options: { encrypt: profile.encrypt, trustServerCertificate: profile.trustServerCertificate },
    connectionTimeout: 15000,
    requestTimeout: 120000,
    pool: { max: 4, min: 0, idleTimeoutMillis: 30000 }
  });
  try { await pool.connect(); }
  catch { throw new Error('Could not connect to SQL Server. Check the address, credentials, and TLS settings.'); }

  const metadata = async (text, params = {}, timeoutMs = 10000) => {
    const request = new mssql.Request(pool);
    for (const [key, value] of Object.entries(params)) request.input(key, value);
    const timer = setTimeout(() => request.cancel(), timeoutMs);
    try {
      const result = await request.query(text);
      return result.recordset || [];
    } finally { clearTimeout(timer); }
  };

  const diffMetadata = async (sql, objectIds) => {
    const rows = [];
    for (let start = 0; start < objectIds.length; start += 250) {
      const batch = objectIds.slice(start, start + 250);
      const params = Object.fromEntries(batch.map((objectId, index) => [`id${index}`, objectId]));
      const placeholders = batch.map((_, index) => `@id${index}`).join(',');
      rows.push(...await metadata(sql.replaceAll('/*OBJECT_IDS*/', placeholders), params, 30000));
    }
    return rows;
  };

  return {
    type: profile.type,
    close: () => pool.close(),
    async databases() {
      // Azure SQL exposes the other databases only from master. A contained
      // database user may be unable to connect there, so retain the current
      // database and allow the UI to offer a manual database name as well.
      if (azureCatalog && profile.database.toLowerCase() !== 'master') {
        let master;
        try {
          master = await sqlserver({ ...profile, database: 'master' }, password);
          const result = await master.databases();
          const hasCurrent = result.databases.some(item => item.name.toLowerCase() === profile.database.toLowerCase());
          if (!hasCurrent) result.databases.push({ name: profile.database });
          result.databases.sort((a, b) => a.name.localeCompare(b.name));
          return { ...result, limited: result.limited || !hasCurrent };
        } catch {
          return { databases: [{ name: profile.database }], limited: true };
        } finally {
          await master?.close().catch(() => {});
        }
      }
      try {
        const rows = await metadata(`SELECT TOP (2000) name FROM sys.databases
          WHERE state = 0 ${azureCatalog ? '' : 'AND HAS_DBACCESS(name) = 1'}
          ORDER BY name`);
        const databases = rows.map(row => ({ name: String(row.name) }));
        const hasCurrent = databases.some(item => item.name.toLowerCase() === profile.database.toLowerCase());
        if (!hasCurrent) databases.push({ name: profile.database });
        databases.sort((a, b) => a.name.localeCompare(b.name));
        return { databases, limited: !hasCurrent };
      } catch {
        return { databases: [{ name: profile.database }], limited: true };
      }
    },
    async schemas() {
      return (await metadata("SELECT TOP (2000) name FROM sys.schemas WHERE name NOT IN ('sys','INFORMATION_SCHEMA') ORDER BY name"))
        .map(row => ({ name: row.name }));
    },
    async objects(schema) {
      return (await metadata(`SELECT TOP (2000) s.name AS [schema], o.name,
        CASE WHEN o.type = 'V' THEN 'view' ELSE 'table' END AS [type]
        FROM sys.objects o JOIN sys.schemas s ON o.schema_id = s.schema_id
        WHERE o.type IN ('U','V') AND (@schema IS NULL OR s.name = @schema)
        ORDER BY s.name, o.name`, { schema: schema || null }));
    },
    async describe(schema, name) {
      const columns = await metadata(`SELECT c.name, t.name AS [type], c.is_nullable AS nullable,
        dc.definition AS [default], c.max_length AS maxLength, c.precision, c.scale,
        CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic
          ON i.object_id=ic.object_id AND i.index_id=ic.index_id
          WHERE i.object_id=c.object_id AND i.is_primary_key=1 AND ic.column_id=c.column_id)
          THEN 1 ELSE 0 END AS primaryKey
        FROM sys.columns c JOIN sys.types t ON c.user_type_id=t.user_type_id
        JOIN sys.objects o ON c.object_id=o.object_id
        JOIN sys.schemas s ON o.schema_id=s.schema_id
        LEFT JOIN sys.default_constraints dc ON c.default_object_id=dc.object_id
        WHERE s.name=@schema AND o.name=@name AND o.type IN ('U','V')
        ORDER BY c.column_id`, { schema, name });
      const indexes = await metadata(`SELECT i.name, i.is_unique AS [unique], i.is_primary_key AS primaryKey,
        c.name AS columnName, ic.key_ordinal AS ordinal
        FROM sys.indexes i JOIN sys.objects o ON i.object_id=o.object_id
        JOIN sys.schemas s ON o.schema_id=s.schema_id
        JOIN sys.index_columns ic ON i.object_id=ic.object_id AND i.index_id=ic.index_id
        JOIN sys.columns c ON ic.object_id=c.object_id AND ic.column_id=c.column_id
        WHERE s.name=@schema AND o.name=@name AND i.name IS NOT NULL
        ORDER BY i.name, ic.key_ordinal`, { schema, name });
      return {
        columns: columns.map(row => ({
          name: row.name, type: row.type, nullable: Boolean(row.nullable), default: row.default,
          primaryKey: Boolean(row.primaryKey), maxLength: row.maxLength, precision: row.precision, scale: row.scale
        })),
        indexes: groupIndexes(indexes)
      };
    },
    async diffCatalog() {
      const [schemas, objects] = await Promise.all([
        metadata("SELECT TOP (2001) name FROM sys.schemas WHERE name NOT IN ('sys','INFORMATION_SCHEMA') ORDER BY name", {}, 30000),
        metadata(`SELECT TOP (10001) o.object_id AS objectId, s.name AS [schema], o.name,
          CASE WHEN o.type='V' THEN 'view' ELSE 'table' END AS [type]
          FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id
          WHERE o.type IN ('U','V') AND s.name NOT IN ('sys','INFORMATION_SCHEMA')
          ORDER BY s.name,o.name`, {}, 30000)
      ]);
      if (schemas.length > 2000 || objects.length > 10000) throw new Error('Could not compare schemas: database catalog exceeds the comparison limit.');
      return { schemas: schemas.map(row => ({ name: row.name })), objects };
    },
    async diffDetails(objects) {
      const ids = objects.map(object => object.objectId);
      const details = Object.fromEntries(ids.map(id => [id, {
        columns: [], indexes: [], checks: [], foreignKeys: [], incomingForeignKeys: [], dependencies: [],
        definition: null, indexed: false, properties: {}
      }]));
      if (!ids.length) return details;
      const [columns, indexes, checks, foreignKeys, views, tables, dependencies] = await Promise.all([
        diffMetadata(`SELECT c.object_id AS objectId, c.column_id AS columnId, c.name,
          t.name AS typeName, ts.name AS typeSchema, t.is_user_defined AS isUserDefined,
          c.max_length AS maxLength, c.precision, c.scale, c.is_nullable AS nullable,
          c.collation_name AS collation, c.is_identity AS [identity],
          CONVERT(nvarchar(100),ic.seed_value) AS identitySeed,
          CONVERT(nvarchar(100),ic.increment_value) AS identityIncrement,
          ic.is_not_for_replication AS identityNotForReplication,
          cc.definition AS computedDefinition, cc.is_persisted AS persisted,
          dc.name AS defaultName, dc.definition AS defaultDefinition,
          c.is_sparse AS sparse, c.is_rowguidcol AS [rowguidcol], c.is_filestream AS filestream,
          c.generated_always_type AS generatedAlwaysType, c.encryption_type AS encryptionType,
          c.xml_collection_id AS xmlCollectionId
          FROM sys.columns c
          JOIN sys.types t ON t.user_type_id=c.user_type_id
          JOIN sys.schemas ts ON ts.schema_id=t.schema_id
          LEFT JOIN sys.identity_columns ic ON ic.object_id=c.object_id AND ic.column_id=c.column_id
          LEFT JOIN sys.computed_columns cc ON cc.object_id=c.object_id AND cc.column_id=c.column_id
          LEFT JOIN sys.default_constraints dc ON dc.object_id=c.default_object_id
          WHERE c.object_id IN (/*OBJECT_IDS*/) ORDER BY c.object_id,c.column_id`, ids),
        diffMetadata(`SELECT i.object_id AS objectId, i.index_id AS indexId, i.name,
          i.type_desc AS [type], i.is_unique AS [unique], i.is_primary_key AS primaryKey,
          i.is_unique_constraint AS uniqueConstraint, i.is_disabled AS disabled,
          i.has_filter AS hasFilter, i.filter_definition AS filterDefinition,
          i.is_hypothetical AS hypothetical, ps.name AS partitionScheme,
          kc.name AS constraintName, ic.key_ordinal AS keyOrdinal,
          ic.is_included_column AS included, ic.is_descending_key AS descending,
          c.name AS columnName
          FROM sys.indexes i
          LEFT JOIN sys.key_constraints kc ON kc.parent_object_id=i.object_id AND kc.unique_index_id=i.index_id
          LEFT JOIN sys.partition_schemes ps ON ps.data_space_id=i.data_space_id
          LEFT JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
          LEFT JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
          WHERE i.object_id IN (/*OBJECT_IDS*/) AND i.index_id>0
          ORDER BY i.object_id,i.index_id,ic.key_ordinal,ic.index_column_id`, ids),
        diffMetadata(`SELECT parent_object_id AS objectId, name, definition,
          is_disabled AS disabled, is_not_trusted AS notTrusted
          FROM sys.check_constraints WHERE parent_object_id IN (/*OBJECT_IDS*/)`, ids),
        diffMetadata(`SELECT fk.parent_object_id AS objectId, fk.referenced_object_id AS referencedObjectId,
          fk.name, fk.delete_referential_action_desc AS deleteAction,
          fk.update_referential_action_desc AS updateAction,
          fk.is_disabled AS disabled, fk.is_not_trusted AS notTrusted,
          rs.name AS referencedSchema, ro.name AS referencedTable,
          fkc.constraint_column_id AS ordinal, pc.name AS columnName, rc.name AS referencedColumn
          FROM sys.foreign_keys fk
          JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id=fk.object_id
          JOIN sys.columns pc ON pc.object_id=fk.parent_object_id AND pc.column_id=fkc.parent_column_id
          JOIN sys.columns rc ON rc.object_id=fk.referenced_object_id AND rc.column_id=fkc.referenced_column_id
          JOIN sys.objects ro ON ro.object_id=fk.referenced_object_id
          JOIN sys.schemas rs ON rs.schema_id=ro.schema_id
          WHERE fk.parent_object_id IN (/*OBJECT_IDS*/) OR fk.referenced_object_id IN (/*OBJECT_IDS*/)
          ORDER BY fk.object_id,fkc.constraint_column_id`, ids),
        diffMetadata(`SELECT v.object_id AS objectId, sm.definition,
          CASE WHEN EXISTS(SELECT 1 FROM sys.indexes i WHERE i.object_id=v.object_id AND i.index_id>0) THEN 1 ELSE 0 END AS indexed
          FROM sys.views v LEFT JOIN sys.sql_modules sm ON sm.object_id=v.object_id
          WHERE v.object_id IN (/*OBJECT_IDS*/)`, ids),
        diffMetadata(`SELECT t.object_id AS objectId,
          t.temporal_type AS temporal, t.is_memory_optimized AS memoryOptimized,
          t.is_filetable AS fileTable,
          CASE WHEN EXISTS(SELECT 1 FROM sys.indexes i JOIN sys.partition_schemes ps ON ps.data_space_id=i.data_space_id WHERE i.object_id=t.object_id) THEN 1 ELSE 0 END AS partitioned,
          CASE WHEN EXISTS(SELECT 1 FROM sys.partitions p WHERE p.object_id=t.object_id AND p.data_compression<>0) THEN 1 ELSE 0 END AS compressed,
          CASE WHEN EXISTS(SELECT 1 FROM sys.triggers tr WHERE tr.parent_id=t.object_id AND tr.is_ms_shipped=0) THEN 1 ELSE 0 END AS hasTriggers
          FROM sys.tables t WHERE t.object_id IN (/*OBJECT_IDS*/)`, ids),
        diffMetadata(`SELECT d.referencing_id AS objectId,
          d.referenced_database_name AS referencedDatabase,
          d.referenced_server_name AS referencedServer,
          COALESCE(rs.name,d.referenced_schema_name) AS referencedSchema,
          COALESCE(ro.name,d.referenced_entity_name) AS referencedName,
          CASE WHEN d.referenced_id IS NULL THEN 1 ELSE 0 END AS unresolved,
          CASE WHEN ro.type='V' THEN 'view' WHEN ro.type='U' THEN 'table' ELSE NULL END AS referencedType
          FROM sys.sql_expression_dependencies d
          LEFT JOIN sys.objects ro ON ro.object_id=d.referenced_id
          LEFT JOIN sys.schemas rs ON rs.schema_id=ro.schema_id
          WHERE d.referencing_id IN (/*OBJECT_IDS*/)`, ids)
      ]);
      for (const column of columns) details[column.objectId]?.columns.push(column);
      for (const row of indexes) {
        const detail = details[row.objectId];
        if (!detail) continue;
        let index = detail.indexes.find(item => item.indexId === row.indexId);
        if (!index) {
          index = { indexId: row.indexId, name: row.name, type: row.type,
            unique: Boolean(row.unique), primaryKey: Boolean(row.primaryKey),
            constraintName: row.constraintName, disabled: Boolean(row.disabled),
            partitioned: Boolean(row.partitionScheme), hasFilter: Boolean(row.hasFilter),
            filterDefinition: row.filterDefinition, hypothetical: Boolean(row.hypothetical),
            keys: [], includes: [] };
          detail.indexes.push(index);
        }
        if (row.columnName && row.included) index.includes.push(row.columnName);
        else if (row.columnName && row.keyOrdinal > 0) index.keys.push({ name: row.columnName, descending: Boolean(row.descending) });
      }
      for (const check of checks) details[check.objectId]?.checks.push(check);
      const groupedFks = new Map();
      for (const row of foreignKeys) {
        let fk = groupedFks.get(row.name + ':' + row.objectId);
        if (!fk) {
          fk = { name: row.name, objectId: row.objectId, referencedObjectId: row.referencedObjectId,
            referencedSchema: row.referencedSchema, referencedTable: row.referencedTable,
            deleteAction: row.deleteAction, updateAction: row.updateAction,
            disabled: Boolean(row.disabled), notTrusted: Boolean(row.notTrusted),
            columns: [], referencedColumns: [] };
          groupedFks.set(row.name + ':' + row.objectId, fk);
        }
        fk.columns.push(row.columnName);
        fk.referencedColumns.push(row.referencedColumn);
      }
      for (const fk of groupedFks.values()) {
        details[fk.objectId]?.foreignKeys.push(fk);
        details[fk.referencedObjectId]?.incomingForeignKeys.push(fk);
      }
      for (const view of views) {
        if (details[view.objectId]) {
          details[view.objectId].definition = view.definition;
          details[view.objectId].indexed = Boolean(view.indexed);
        }
      }
      for (const table of tables) {
        if (details[table.objectId]) details[table.objectId].properties = table;
      }
      for (const dependency of dependencies) details[dependency.objectId]?.dependencies?.push(dependency);
      return details;
    },
    rows(schema, name, limit, offset, onReady = () => {}, cellBatch = null) {
      const request = new mssql.Request(pool);
      request.stream = true;
      request.arrayRowMode = true;
      request.input('offset', offset);
      request.input('count', limit + 1);
      const rows = [];
      const cellRefs = [];
      const budget = { bytes: 0 };
      let columns = [];
      let hasMore = false;
      let internalCancel = false;
      let oversizedRow = false;
      let userCancel = false;
      let timedOut = false;
      const cancel = () => { userCancel = true; try { request.cancel(); } catch {} };
      onReady(cancel);
      return new Promise((resolve, reject) => {
        let settled = false;
        let timer;
        const stop = () => { try { request.cancel(); } catch {} };
        const done = error => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (userCancel) reject(new Error('Query cancelled.'));
          else if (timedOut) reject(new Error('Query timed out.'));
          else if (oversizedRow) reject(oversizedRowError());
          else if (error && !internalCancel) reject(error);
          else resolve({ columns, rows, cellRefs, limit, offset, hasMore });
        };
        request.on('recordset', meta => {
          if (!columns.length) columns = meta.map(item => column(item.name, item.type?.name));
        });
        request.on('row', row => {
          if (internalCancel || userCancel || timedOut) return;
          if (rows.length < limit) {
            if (appendRow(rows, row, budget, cellRefs, cellBatch)) return;
            if (rows.length === 0) oversizedRow = true;
          }
          hasMore = true;
          internalCancel = true;
          stop();
        });
        request.on('error', done);
        request.on('done', () => done());
        if (userCancel) { done(new Error('Query cancelled.')); return; }
        timer = setTimeout(() => { timedOut = true; stop(); }, 15000);
        try {
          request.query(`SELECT * FROM ${sqlIdentifier(schema)}.${sqlIdentifier(name)} ORDER BY (SELECT NULL) OFFSET @offset ROWS FETCH NEXT @count ROWS ONLY`).catch(done);
        } catch (error) { done(error); }
      });
    },
    run(sql, limit, timeoutMs, onReady, cellBatch = null) {
      const request = new mssql.Request(pool);
      request.stream = true;
      request.arrayRowMode = true;
      const rows = [];
      const cellRefs = [];
      const budget = { bytes: 0 };
      let columns = [];
      let recordsets = 0;
      let rowCount = 0;
      let hasMore = false;
      let internalCancel = false;
      let userCancel = false;
      let timedOut = false;
      const cancel = () => { userCancel = true; request.cancel(); };
      onReady(cancel);
      return new Promise((resolve, reject) => {
        let settled = false;
        let timer;
        const done = (error, result) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (userCancel) reject(new Error('Query cancelled.'));
          else if (timedOut) reject(new Error('Query timed out.'));
          else if (error && !(internalCancel && error.code === 'ECANCEL')) reject(queryError(error, sql, password));
          else resolve({ columns, rows, cellRefs, rowCount: result?.rowsAffected?.reduce((a, b) => a + b, 0) ?? rowCount, hasMore });
        };
        request.on('recordset', meta => {
          recordsets += 1;
          if (recordsets === 1) columns = meta.map(item => column(item.name, item.type?.name));
        });
        request.on('row', row => {
          // A batch or stored procedure may return more than one result set.
          // Stop on the next set too, so later SELECTs cannot stream unbounded rows.
          if (recordsets !== 1) {
            if (!hasMore) { hasMore = true; internalCancel = true; request.cancel(); }
            return;
          }
          rowCount += 1;
          if (rows.length < limit && appendRow(rows, row, budget, cellRefs, cellBatch)) return;
          if (!hasMore) { hasMore = true; internalCancel = true; request.cancel(); }
        });
        request.on('error', error => done(error));
        request.on('done', result => done(null, result));
        if (userCancel) { done(new Error('Query cancelled.')); return; }
        timer = setTimeout(() => { timedOut = true; request.cancel(); }, timeoutMs);
        try { request.query(sql).catch(error => done(error)); }
        catch (error) { done(error); }
      });
    }
  };
}

function groupIndexes(rows) {
  const grouped = new Map();
  for (const row of rows) {
    let index = grouped.get(row.name);
    if (!index) {
      index = { name: row.name, unique: Boolean(row.unique), primaryKey: Boolean(row.primaryKey), columns: [] };
      grouped.set(row.name, index);
    }
    if (row.columnName) index.columns.push(row.columnName);
  }
  return [...grouped.values()];
}

async function postgres(profile, password) {
  let pg;
  try { pg = (await import('pg')).default; }
  catch { throw new Error('PostgreSQL driver is missing. Run npm ci --omit=dev.'); }
  const pool = new pg.Pool({
    host: profile.host, port: profile.port, database: profile.database,
    user: profile.user, password, ssl: profile.ssl ? { rejectUnauthorized: true } : false,
    max: 4, connectionTimeoutMillis: 15000, idleTimeoutMillis: 30000,
    statement_timeout: 15000
  });
  pool.on('error', () => {});
  const cancelPool = new pg.Pool({
    host: profile.host, port: profile.port, database: profile.database,
    user: profile.user, password, ssl: profile.ssl ? { rejectUnauthorized: true } : false,
    max: 1, connectionTimeoutMillis: 15000, idleTimeoutMillis: 30000
  });
  cancelPool.on('error', () => {});
  try { const client = await pool.connect(); client.release(); }
  catch {
    await Promise.allSettled([pool.end(), cancelPool.end()]);
    throw new Error('Could not connect to PostgreSQL. Check the address, credentials, and TLS settings.');
  }
  const metadata = async (text, params = []) => (await pool.query({ text, values: params, query_timeout: 20000 })).rows;
  return {
    type: profile.type,
    close: () => Promise.allSettled([pool.end(), cancelPool.end()]),
    async schemas() {
      return metadata("SELECT nspname AS name FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema' ORDER BY nspname LIMIT 2000");
    },
    async objects(schema) {
      return metadata(`SELECT n.nspname AS "schema", c.relname AS name,
        CASE WHEN c.relkind IN ('v','m') THEN 'view' ELSE 'table' END AS type
        FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid
        WHERE c.relkind IN ('r','p','f','v','m') AND ($1::text IS NULL OR n.nspname=$1)
        AND n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
        ORDER BY n.nspname,c.relname LIMIT 2000`, [schema || null]);
    },
    async describe(schema, name) {
      const columns = await metadata(`SELECT a.attname AS name,
        pg_catalog.format_type(a.atttypid,a.atttypmod) AS type,
        NOT a.attnotnull AS nullable,
        pg_catalog.pg_get_expr(d.adbin,d.adrelid) AS "default",
        EXISTS (SELECT 1 FROM pg_catalog.pg_constraint p
          WHERE p.conrelid=c.oid AND p.contype='p' AND a.attnum=ANY(p.conkey)) AS "primaryKey"
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace=n.oid
        JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid
        LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
        WHERE n.nspname=$1 AND c.relname=$2 AND a.attnum>0 AND NOT a.attisdropped
        ORDER BY a.attnum`, [schema, name]);
      const indexes = await metadata(`SELECT indexname AS name, indexdef AS definition
        FROM pg_indexes WHERE schemaname=$1 AND tablename=$2 ORDER BY indexname`, [schema, name]);
      return { columns, indexes };
    },
    async rows(schema, name, limit, offset, onReady = () => {}, cellBatch = null) {
      const client = await pool.connect();
      const rows = [];
      const cellRefs = [];
      const budget = { bytes: 0 };
      let columns = [];
      let hasMore = false;
      let internalCancel = false;
      let oversizedRow = false;
      let userCancel = false;
      let timedOut = false;
      let started = false;
      let cancelSent = false;
      let hardStopTimer;
      let reusable = false;
      const cancel = () => {
        if (cancelSent || !started) return;
        cancelSent = true;
        void cancelPool.query('SELECT pg_cancel_backend($1)', [client.processID])
          .catch(() => client.connection?.stream?.destroy());
        // A broken network can also stall the cancellation connection. Do not
        // let a table read hold a pooled client indefinitely in that case.
        hardStopTimer = setTimeout(() => client.connection?.stream?.destroy(), 1000);
      };
      try {
        onReady(() => { userCancel = true; cancel(); });
        if (userCancel) throw new Error('Query cancelled.');
        const query = new pg.Query({
          text: `SELECT * FROM ${pgIdentifier(schema)}.${pgIdentifier(name)} LIMIT $1 OFFSET $2`,
          values: [limit + 1, offset], rowMode: 'array'
        });
        const result = await new Promise((resolve, reject) => {
          const timer = setTimeout(() => { timedOut = true; cancel(); }, 15000);
          const finish = (callback, value) => { clearTimeout(timer); callback(value); };
          query.on('row', (row, meta) => {
            if (!columns.length && meta?.fields) columns = meta.fields.map(field => column(field.name, String(field.dataTypeID)));
            if (internalCancel || userCancel || timedOut) return;
            if (rows.length < limit) {
              if (appendRow(rows, row, budget, cellRefs, cellBatch)) return;
              if (rows.length === 0) oversizedRow = true;
            }
            hasMore = true;
            internalCancel = true;
            cancel();
          });
          query.on('error', error => finish(reject, error));
          query.on('end', value => finish(resolve, value));
          started = true;
          try { client.query(query); }
          catch (error) { finish(reject, error); }
        });
        if (!columns.length) columns = result.fields.map(field => column(field.name, String(field.dataTypeID)));
        if (userCancel) throw new Error('Query cancelled.');
        if (timedOut) throw new Error('Query timed out.');
        if (oversizedRow) throw oversizedRowError();
        reusable = !internalCancel;
        return { columns, rows, cellRefs, limit, offset, hasMore };
      } catch (error) {
        if (userCancel) throw new Error('Query cancelled.');
        if (timedOut) throw new Error('Query timed out.');
        if (oversizedRow) throw oversizedRowError();
        if (internalCancel) return { columns, rows, cellRefs, limit, offset, hasMore };
        throw error;
      } finally {
        clearTimeout(hardStopTimer);
        client.release(!reusable);
      }
    },
    async run(sql, limit, timeoutMs, onReady, cellBatch = null) {
      const client = await pool.connect();
      const rows = [];
      const cellRefs = [];
      const budget = { bytes: 0 };
      let columns = [];
      let rowCount = 0;
      let hasMore = false;
      let internalCancel = false;
      let userCancel = false;
      let cancelSent = false;
      const cancel = async () => {
        if (cancelSent) return;
        cancelSent = true;
        try { await cancelPool.query('SELECT pg_cancel_backend($1)', [client.processID]); }
        catch { client.connection?.stream?.destroy(); }
      };
      try {
        await client.query(`SET statement_timeout TO ${timeoutMs}`);
        onReady(() => { userCancel = true; void cancel(); });
        if (userCancel) throw new Error('Query cancelled.');
        const query = new pg.Query({ text: sql, rowMode: 'array' });
        let firstResult;
        const result = await new Promise((resolve, reject) => {
          query.on('row', (row, resultMeta) => {
            if (!firstResult) firstResult = resultMeta;
            if (resultMeta !== firstResult) {
              if (!hasMore) { hasMore = true; internalCancel = true; void cancel(); }
              return;
            }
            if (!columns.length && resultMeta?.fields) columns = resultMeta.fields.map(field => column(field.name, String(field.dataTypeID)));
            rowCount += 1;
            if (rows.length < limit && appendRow(rows, row, budget, cellRefs, cellBatch)) return;
            if (!hasMore) { hasMore = true; internalCancel = true; void cancel(); }
          });
          query.on('error', reject);
          query.on('end', resolve);
          client.query(query);
        });
        const displayResult = firstResult || (Array.isArray(result) ? result.find(item => item.fields?.length) || result[0] : result);
        if (!columns.length) columns = displayResult?.fields?.map(field => column(field.name, String(field.dataTypeID))) || [];
        if (userCancel) throw new Error('Query cancelled.');
        return { columns, rows, cellRefs, rowCount: displayResult?.rowCount ?? rowCount, hasMore };
      } catch (error) {
        if (userCancel) throw new Error('Query cancelled.');
        if (internalCancel && error.code === '57014') return { columns, rows, cellRefs, rowCount, hasMore };
        throw queryError(error, sql, password);
      } finally {
        client.release(true);
      }
    }
  };
}

async function mysql(profile, password) {
  let mysql2;
  try { mysql2 = (await import('mysql2')).default; }
  catch { throw new Error('MySQL driver is missing. Run npm ci --omit=dev.'); }
  const connectionConfig = {
    host: profile.host, port: profile.port, database: profile.database,
    user: profile.user, password, ssl: profile.ssl ? { rejectUnauthorized: true, verifyIdentity: true } : undefined,
    connectTimeout: 15000, multipleStatements: false,
    supportBigNumbers: true, bigNumberStrings: true
  };
  const pool = mysql2.createPool({ ...connectionConfig, connectionLimit: 4 });
  const cancelPool = mysql2.createPool({ ...connectionConfig, connectionLimit: 1 });
  const promisePool = pool.promise();
  const promiseCancelPool = cancelPool.promise();
  try { const connection = await promisePool.getConnection(); connection.release(); }
  catch {
    await Promise.allSettled([promisePool.end(), promiseCancelPool.end()]);
    throw new Error('Could not connect to MySQL. Check the address, credentials, and TLS settings.');
  }
  const metadata = async (text, params = []) => (await promisePool.query({
    sql: text, values: params, timeout: 15000
  }))[0];
  return {
    type: profile.type,
    close: () => Promise.allSettled([promisePool.end(), promiseCancelPool.end()]),
    async schemas() {
      return metadata('SELECT SCHEMA_NAME AS name FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME LIMIT 2000');
    },
    async objects(schema) {
      return metadata(`SELECT TABLE_SCHEMA AS \`schema\`, TABLE_NAME AS name,
        CASE WHEN TABLE_TYPE='VIEW' THEN 'view' ELSE 'table' END AS type
        FROM information_schema.TABLES WHERE (? IS NULL OR TABLE_SCHEMA=?)
        ORDER BY TABLE_SCHEMA,TABLE_NAME LIMIT 2000`, [schema || null, schema || null]);
    },
    async describe(schema, name) {
      const columns = await metadata(`SELECT COLUMN_NAME AS name, COLUMN_TYPE AS type,
        IS_NULLABLE='YES' AS nullable, COLUMN_DEFAULT AS \`default\`,
        COLUMN_KEY='PRI' AS primaryKey, EXTRA AS extra
        FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=?
        ORDER BY ORDINAL_POSITION`, [schema, name]);
      const indexes = await metadata(`SELECT INDEX_NAME AS name, NON_UNIQUE=0 AS \`unique\`,
        INDEX_NAME='PRIMARY' AS primaryKey, COLUMN_NAME AS columnName,
        SEQ_IN_INDEX AS ordinal
        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=? AND TABLE_NAME=?
        ORDER BY INDEX_NAME,SEQ_IN_INDEX`, [schema, name]);
      return { columns: columns.map(row => ({ ...row, nullable: Boolean(row.nullable), primaryKey: Boolean(row.primaryKey) })), indexes: groupIndexes(indexes) };
    },
    rows(schema, name, limit, offset, onReady = () => {}, cellBatch = null) {
      return new Promise((resolve, reject) => {
        pool.getConnection((connectionError, connection) => {
          if (connectionError) { reject(connectionError); return; }
          const rows = [];
          const cellRefs = [];
          const budget = { bytes: 0 };
          let columns = [];
          let hasMore = false;
          let internalCancel = false;
          let oversizedRow = false;
          let userCancel = false;
          let queryStarted = false;
          let settled = false;
          let cancelSent = false;
          let hardStopTimer;
          const cancel = () => {
            if (cancelSent) return;
            cancelSent = true;
            void promiseCancelPool.query(`KILL QUERY ${Number(connection.threadId)}`)
              .catch(() => connection.destroy());
            hardStopTimer = setTimeout(() => connection.destroy(), 1000);
          };
          const finish = error => {
            if (settled) return;
            settled = true;
            clearTimeout(hardStopTimer);
            connection.destroy();
            if (userCancel) reject(new Error('Query cancelled.'));
            else if (oversizedRow) reject(oversizedRowError());
            else if (error && !internalCancel) reject(error);
            else resolve({ columns, rows, cellRefs, limit, offset, hasMore });
          };
          try {
            onReady(() => { userCancel = true; if (queryStarted) cancel(); });
            if (userCancel) { finish(new Error('Query cancelled.')); return; }
            const query = connection.query({
              sql: `SELECT * FROM ${myIdentifier(schema)}.${myIdentifier(name)} LIMIT ? OFFSET ?`,
              values: [limit + 1, offset], rowsAsArray: true, timeout: 15000
            });
            queryStarted = true;
            query.on('fields', fields => { columns = fields.map(field => column(field.name, String(field.columnType))); });
            query.on('result', row => {
              if (internalCancel || userCancel) return;
              if (rows.length < limit) {
                if (appendRow(rows, row, budget, cellRefs, cellBatch)) return;
                if (rows.length === 0) oversizedRow = true;
              }
              hasMore = true;
              internalCancel = true;
              cancel();
            });
            query.on('error', finish);
            query.on('end', () => finish());
          } catch (error) { finish(error); }
        });
      });
    },
    run(sql, limit, timeoutMs, onReady, cellBatch = null) {
      return new Promise((resolve, reject) => {
        pool.getConnection((connectionError, connection) => {
          if (connectionError) { reject(queryError(connectionError, sql, password)); return; }
          const rows = [];
          const cellRefs = [];
          const budget = { bytes: 0 };
          let columns = [];
          let recordsets = 0;
          let rowCount = 0;
          let hasMore = false;
          let internalCancel = false;
          let userCancel = false;
          let queryStarted = false;
          let settled = false;
          const cancel = () => {
            promiseCancelPool.query(`KILL QUERY ${Number(connection.threadId)}`).catch(() => connection.destroy());
          };
          onReady(() => { userCancel = true; if (queryStarted) cancel(); });
          const finish = (error, result) => {
            if (settled) return;
            settled = true;
            connection.destroy();
            if (userCancel) reject(new Error('Query cancelled.'));
            else if (error && !(internalCancel && error.code === 'ER_QUERY_INTERRUPTED')) reject(queryError(error, sql, password));
            else resolve({ columns, rows, cellRefs, rowCount: result?.affectedRows ?? rowCount, hasMore });
          };
          if (userCancel) { finish(new Error('Query cancelled.')); return; }
          const query = connection.query({ sql, rowsAsArray: true, timeout: timeoutMs });
          queryStarted = true;
          query.on('fields', fields => {
            if (!Array.isArray(fields) || fields.length === 0) return;
            recordsets += 1;
            if (recordsets === 1) columns = fields.map(field => column(field.name, String(field.columnType)));
            else if (!hasMore) { hasMore = true; internalCancel = true; cancel(); }
          });
          query.on('result', row => {
            if (!Array.isArray(row)) { rowCount = row.affectedRows || rowCount; return; }
            if (recordsets > 1) {
              if (!hasMore) { hasMore = true; internalCancel = true; cancel(); }
              return;
            }
            rowCount += 1;
            if (rows.length < limit && appendRow(rows, row, budget, cellRefs, cellBatch)) return;
            if (!hasMore) { hasMore = true; internalCancel = true; cancel(); }
          });
          query.on('error', error => finish(error));
          query.on('end', result => finish(null, result));
        });
      });
    }
  };
}

export function queryError(error, sql = '', password = '') {
  const code = typeof error?.code === 'string' && /^[A-Z0-9_]{2,40}$/.test(error.code) ? ` (${error.code})` : '';
  let detail = typeof error?.message === 'string' ? error.message : '';
  if (sql) detail = detail.split(sql).join('[query]');
  if (password) {
    detail = detail.split(password).join('[redacted]');
    try { detail = detail.split(encodeURIComponent(password)).join('[redacted]'); } catch {}
  }
  detail = detail
    .replace(/(?:postgres(?:ql)?|mysql):\/\/\S+/gi, '[connection]')
    .replace(/\b(?:password|pwd)\s*[:=]\s*[^;,\s]+/gi, 'password=[redacted]')
    .replace(/(['"`])[^'"`]{1,200}\1/g, '[token]')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 300);
  const location = Number.isInteger(error?.lineNumber) ? ` line ${error.lineNumber}`
    : Number.isInteger(Number(error?.position)) ? ` position ${error.position}` : '';
  return new Error(`Query failed${code}${location}${detail ? `: ${detail}` : '.'}`);
}

export function tableReadError(error, type, operation, password = '') {
  const subject = operation === 'definition' ? 'table definition' : 'table data';
  if (type !== 'postgres') return new Error(`Could not load ${subject}.`);

  if (error?.code === '42501') {
    const message = typeof error.message === 'string' ? error.message : '';
    if (/permission denied for schema\b/i.test(message)) {
      return new Error(`Could not load ${subject} (PostgreSQL 42501): This login lacks USAGE on the selected schema. Ask an administrator to grant schema USAGE${operation === 'definition' ? '.' : ' and table or view SELECT.'}`);
    }
    if (operation !== 'definition' && /permission denied for (?:table|relation|view|materialized view|foreign table)\b/i.test(message)) {
      return new Error(`Could not load ${subject} (PostgreSQL 42501): This login lacks SELECT on the selected table or view. Ask an administrator to grant SELECT.`);
    }
    return new Error(`Could not load ${subject} (PostgreSQL 42501): This login lacks permission to access the selected object. Ask an administrator to check schema USAGE${operation === 'definition' ? '.' : ' and table or view SELECT.'}`);
  }

  return new Error(`Could not load ${subject}: ${queryError(error, '', password).message}`);
}

export async function openDatabase(profile, password) {
  const driver = profile.type === 'azure_sql' || profile.type === 'sqlserver'
    ? sqlserver : profile.type === 'postgres' ? postgres : profile.type === 'mysql' ? mysql : null;
  if (!driver) throw new Error('Unsupported database type.');
  const adapter = await driver(profile, password);
  return { id: randomUUID(), profileId: profile.id, profile, adapter };
}

export async function openSwitchedDatabase(connection, database, open = openDatabase) {
  if (!['azure_sql', 'sqlserver'].includes(connection.profile.type)) {
    throw new Error('Database switching is supported for SQL Server and Azure SQL.');
  }
  const profile = { ...connection.profile, database: databaseName(database) };
  const opened = await open(profile, connection.password);
  return { ...opened, password: connection.password, meta: connection.meta };
}
