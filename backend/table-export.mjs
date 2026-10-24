import { open, lstat, rename, unlink } from 'node:fs/promises';
import { writeSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { tableReadPlan } from './table-read.mjs';

const activePaths = new Set();
const sqlServer = type => ['sqlserver', 'azure_sql'].includes(type);
export const sqlExportable = (column, type) => !column.generated && !/\b(?:VIRTUAL|STORED) GENERATED\b/i.test(column.extra || '') &&
  !(sqlServer(type) && /^(timestamp|rowversion)$/i.test(column.type));

function quote(type, value) {
  if (type === 'mysql') return '`' + value.replaceAll('`', '``') + '`';
  if (sqlServer(type)) return '[' + value.replaceAll(']', ']]') + ']';
  return '"' + value.replaceAll('"', '""') + '"';
}
function binary(value, type, column) {
  if (Buffer.isBuffer(value)) return value;
  if (type === 'postgres' && column.type === 'bytea' && typeof value === 'string' && /^\\x[\da-f]*$/i.test(value)) return Buffer.from(value.slice(2), 'hex');
  if (type === 'cloudflare_d1' && Array.isArray(value)) return Buffer.from(value);
  return null;
}
function text(value) {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'object') return JSON.stringify(value, (_, item) => typeof item === 'bigint' ? String(item) : item);
  return String(value);
}
export function csvValue(value, type, column = {}) {
  if (value === null || value === undefined) return '';
  const bytes = binary(value, type, column);
  return '"' + (bytes ? '0x' + bytes.toString('hex') : text(value)).replaceAll('"', '""') + '"';
}
export function sqlValue(value, type, column = {}) {
  if (value === null || value === undefined) return 'NULL';
  const bytes = binary(value, type, column);
  if (bytes) {
    const hex = bytes.toString('hex');
    return type === 'postgres' ? `decode('${hex}', 'hex')` : sqlServer(type) ? '0x' + hex : `X'${hex}'`;
  }
  if (typeof value === 'boolean') return type === 'postgres' ? (value ? 'TRUE' : 'FALSE') : (value ? '1' : '0');
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      if (type === 'postgres') return `'${String(value)}'`;
      throw new Error('Could not export a non-finite number as SQL. Choose CSV or omit this column.');
    }
    return String(value);
  }
  if (typeof value === 'bigint') return String(value);
  if (sqlServer(type) && typeof value === 'object' && !(value instanceof Date)) throw new Error('Could not export this complex SQL Server value as SQL. Choose CSV or omit this column.');
  const string = text(value);
  if (type === 'postgres') return "E'" + string.replaceAll('\\', '\\\\').replaceAll("'", "''") + "'";
  // Hex text is independent of MySQL's NO_BACKSLASH_ESCAPES/ANSI_QUOTES modes.
  if (type === 'mysql') return `CONVERT(X'${Buffer.from(string).toString('hex')}' USING utf8mb4)`;
  if (sqlServer(type)) {
    if (string.includes('\0')) return `CONVERT(nvarchar(max), 0x${Buffer.from(string, 'utf16le').toString('hex')})`;
    return "N'" + string.replaceAll("'", "''") + "'";
  }
  if (string.includes('\0')) return `CAST(X'${Buffer.from(string).toString('hex')}' AS TEXT)`;
  return "'" + string.replaceAll("'", "''") + "'";
}

async function fileStat(filePath) {
  try { return await lstat(filePath); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
const sameFile = (before, after) => !before ? !after : after && before.dev === after.dev && before.ino === after.ino && before.size === after.size && before.mtimeMs === after.mtimeMs && before.ctimeMs === after.ctimeMs;

// The sink writes raw driver values to a private temporary file with bounded
// buffering. No row data goes through JSON IPC, grid previews, or cell caches.
export async function exportTable({ adapter, type, schema, name, definition, format, columns, filter = null, sort = null,
  filePath, overwrite = false, timeoutMs = 30000, onReady = () => {}, checkCancelled = () => {} }) {
  if (!['csv', 'sql'].includes(format)) throw new Error('Invalid export format. Choose CSV or SQL.');
  if (typeof filePath !== 'string' || filePath.length > 4096 || /[\x00-\x1f]/.test(filePath) || !path.isAbsolute(filePath) || path.extname(filePath).toLowerCase() !== '.' + format) throw new Error(`Choose an absolute .${format} file path.`);
  filePath = path.resolve(filePath);
  if (activePaths.has(filePath)) throw new Error('Could not export: another export is using this file.');
  if (!Array.isArray(columns) || !columns.length) throw new Error('Invalid export columns. Select at least one column.');
  const plan = tableReadPlan(type, schema, name, definition, { selectedColumns: columns, filter, sort, unpaged: true });
  const selected = columns.map(name => definition.columns.find(column => column.name === name));
  if (format === 'sql' && selected.some(column => !sqlExportable(column, type))) throw new Error('Invalid SQL export columns. Omit generated columns; their values are calculated by the database.');
  const target = quote(type, schema) + '.' + quote(type, name);
  const identity = format === 'sql' && sqlServer(type) && selected.some(column => column.identity);
  const overriding = type === 'postgres' && selected.some(column => column.identity) ? ' OVERRIDING SYSTEM VALUE' : '';
  const insert = `INSERT INTO ${target} (${columns.map(name => quote(type, name)).join(', ')})${overriding} VALUES (`;
  const temporary = path.join(path.dirname(filePath), '.' + path.basename(filePath) + '.' + randomUUID() + '.tmp');
  let file, rowCount = 0, bytesWritten = 0, buffer = '';
  activePaths.add(filePath);
  const deadline = Date.now() + timeoutMs;
  const check = () => {
    checkCancelled();
    if (Date.now() > deadline) throw new Error('Query timed out. Increase the query timeout in Settings or narrow the export filter.');
  };
  const flush = () => {
    if (!buffer) return;
    const bytes = Buffer.from(buffer, 'utf8');
    let offset = 0;
    try {
      while (offset < bytes.length) offset += writeSync(file.fd, bytes, offset, bytes.length - offset);
    } catch { throw new Error('Could not write the export file. Check disk space and folder permissions.'); }
    bytesWritten += bytes.length;
    buffer = '';
  };
  const write = chunk => { buffer += chunk; if (buffer.length >= 65536) flush(); };
  try {
    const before = await fileStat(filePath);
    if (before && !before.isFile()) throw new Error('Could not export: choose a regular file, not a symbolic link or directory.');
    if (before && !overwrite) throw new Error('Could not export: the file already exists. Confirm replacement in Save as.');
    check();
    file = await open(temporary, 'wx', 0o600);
    if (format === 'csv') write(columns.map(name => csvValue(name, type)).join(',') + '\r\n');
    else {
      write('-- DB Studio data export. INSERT statements for an existing table.\n-- Generated columns are omitted. Review constraints and sequence values before importing.\n');
      if (identity) write(`SET IDENTITY_INSERT ${target} ON;\n`);
    }
    plan.exportRow = row => {
      check();
      if (!Array.isArray(row) || row.length !== selected.length) throw new Error('Could not export: the result columns changed. Refresh the table and try again.');
      if (format === 'csv') write(row.map((value, i) => csvValue(value, type, selected[i])).join(',') + '\r\n');
      else write(insert + row.map((value, i) => sqlValue(value, type, selected[i])).join(', ') + ');\n');
      rowCount++;
    };
    plan.timeoutMs = timeoutMs;
    if (adapter.exportRows) await adapter.exportRows(plan, onReady);
    else await adapter.rows(schema, name, 1000, 0, onReady, null, plan);
    check();
    if (identity) write(`SET IDENTITY_INSERT ${target} OFF;\n`);
    flush();
    await file.sync();
    await file.close(); file = null;
    if (!sameFile(before, await fileStat(filePath))) throw new Error('Could not export: the destination changed during export. Choose another file.');
    check();
    await rename(temporary, filePath);
    return { saved: true, filePath, format, rowCount, columnCount: columns.length, bytesWritten };
  } catch (error) {
    if (/^(Could not |Invalid |Choose |Query |Connection )/.test(error.message || '')) throw error;
    throw new Error('Could not export the table. Check the file permissions and database connection.');
  } finally {
    await file?.close();
    await unlink(temporary).catch(() => {});
    activePaths.delete(filePath);
  }
}
