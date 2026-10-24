import { CellValueStore } from './cell-values.mjs';

// Keep exact driver values in bounded, connection-scoped memory. Never trust
// display previews or client-supplied WHERE clauses to identify a row.
export class RowEditStore extends CellValueStore {
  constructor(options = {}) { super({ maxEntryBytes: 256 * 1024, ...options }); }
  beginPage(connectionId, schema, name) {
    const batch = this.begin(connectionId);
    const handles = [];
    batch.captureRow = raw => {
      const values = raw.map(value => {
        if (value === null || typeof value === 'boolean') return { value };
        if (typeof value === 'string' && value.length <= 65536) return { value };
        if (typeof value === 'bigint') return { value: value.toString() };
        if (typeof value === 'number' && Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value))) return { value };
        return null;
      });
      handles.push(batch.capture(JSON.stringify({ schema, name, values })));
    };
    batch.handlesForRows = handles;
    batch.commitPage = columns => {
      for (const handle of handles) {
        const entry = this.entries.get(handle);
        if (entry) entry.columns = columns;
      }
      return batch.commit();
    };
    return batch;
  }
  snapshot(connectionId, handle) {
    const entry = this.get(connectionId, handle);
    if (!entry) throw new Error('This row snapshot expired. Refresh the table before editing.');
    return { ...JSON.parse(entry.text), columns: this.entries.get(handle)?.columns };
  }
}

export function editableColumn(column) {
  if (!column || column.primaryKey || column.generated || column.identity || /generated|auto_increment/i.test(column.extra || '')) return false;
  return /^(?:character varying|character|varchar|nvarchar|char|nchar|text|tinytext|mediumtext|longtext|citext|uuid|uniqueidentifier|tinyint|smallint|mediumint|int|integer|bigint|int2|int4|int8|decimal|numeric|money|smallmoney|real|float|double precision|double|boolean|bool|bit)(?:\b|\()/i.test(column.type || '') && !/^bit\(/i.test(column.type || '');
}

export function planCellUpdate(type, schema, name, definition, columns, snapshot, columnName, value) {
  return planRowUpdate(type, schema, name, definition, columns, snapshot, [{ column: columnName, value }]);
}

export function planRowUpdate(type, schema, name, definition, columns, snapshot, changes) {
  if (!Array.isArray(changes) || !changes.length || changes.length > definition.columns.length) throw new Error('Choose one or more columns to update.');
  const seen = new Set();
  const targets = changes.map(change => {
    if (!change || typeof change.column !== 'string' || seen.has(change.column)) throw new Error('Each edited column must appear once.');
    seen.add(change.column);
    const target = definition.columns.find(column => column.name === change.column);
    if (!editableColumn(target)) throw new Error('This column is read-only. Use SQL to edit keys, generated values, or complex types.');
    validateValue(target, change.value);
    return target;
  });
  if (snapshot.schema !== schema || snapshot.name !== name) throw new Error('Row snapshot does not match this table.');
  const keys = definition.columns.filter(column => column.primaryKey);
  if (!keys.length) throw new Error('Row editing requires a primary key.');
  const original = name => {
    const index = columns.findIndex(column => column.name === name);
    const entry = snapshot.values[index];
    if (!entry) throw new Error('The original value cannot be edited safely. Use SQL instead.');
    return entry.value;
  };
  const quote = type === 'mysql' ? s => '`' + s.replaceAll('`', '``') + '`'
    : type === 'postgres' ? s => '"' + s.replaceAll('"', '""') + '"'
    : s => '[' + s.replaceAll(']', ']]') + ']';
  const params = [];
  const bind = value => {
    params.push(value);
    return type === 'mysql' ? '?' : type === 'postgres' ? '$' + params.length : '@p' + params.length;
  };
  const assignments = changes.map(change => `${quote(change.column)} = ${bind(change.value)}`);
  const conditions = [...keys, ...targets].map(column => {
    const value = original(column.name);
    if (column.primaryKey && value === null) throw new Error('A primary key value is unavailable. Refresh the table.');
    if (value === null) return `${quote(column.name)} IS NULL`;
    const parameter = bind(value);
    // Compare strings byte-for-byte even under case-insensitive collations.
    if (typeof value === 'string' && /^(?:character|varchar|nvarchar|char|nchar|text|tinytext|mediumtext|longtext|citext)/i.test(column.type)) {
      if (type === 'mysql') return `CAST(${quote(column.name)} AS BINARY) = CAST(${parameter} AS BINARY)`;
      if (type !== 'postgres') return `CONVERT(varbinary(max), CONVERT(nvarchar(max), ${quote(column.name)})) = CONVERT(varbinary(max), CONVERT(nvarchar(max), ${parameter}))`;
      if (/^citext/i.test(column.type)) return `${quote(column.name)}::text = ${parameter}::text`;
    }
    return `${quote(column.name)} = ${parameter}`;
  });
  return { sql: `UPDATE ${quote(schema)}.${quote(name)} SET ${assignments.join(', ')} WHERE ${conditions.join(' AND ')}`, params };
}

function validateValue(target, value) {
  if (value === null && !target.nullable) throw new Error('This column does not allow NULL.');
  if (value !== null && !['string', 'number', 'boolean'].includes(typeof value)) throw new Error('Enter a scalar value.');
  if (typeof value === 'string' && value.length > 65536) throw new Error('Edited values are limited to 65,536 characters.');
  if (typeof value === 'number' && (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))) throw new Error('Enter large numbers as text to preserve precision.');
}

// One statement saves every changed cell atomically with the existing driver transactions.
export async function commitSingleCell(transaction, plan) {
  await transaction.begin();
  try {
    const count = await transaction.update(plan);
    if (count !== 1) throw new Error('The row changed or was deleted. Refresh the table and try again.');
    await transaction.commit();
    return { updated: true };
  } catch (error) {
    await transaction.rollback().catch(() => {});
    throw error;
  }
}
