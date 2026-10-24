import { appendRow, identifier, queryError } from './drivers.mjs';
import { QueryResults } from './query-results.mjs';
import { normalizeProfile } from './connection-string.mjs';
import { tableReadPlan } from './table-read.mjs';

const API = 'https://api.cloudflare.com/client/v4';
const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;
const quote = value => '"' + identifier(value, 'identifier').replaceAll('"', '""') + '"';

// D1 has no external transaction/session protocol. Keep grid edits unavailable;
// explicit SQL uses the token's permissions. Never retry a request automatically.
export async function cloudflareD1(input, token, { fetchApi = globalThis.fetch } = {}) {
  const profile = normalizeProfile(input);
  if (typeof token !== 'string' || !/^[\x21-\x7e]{1,4096}$/.test(token)) throw new Error('Enter a Cloudflare API token without spaces or line breaks.');
  const base = `${API}/accounts/${profile.accountId}/d1/database/${profile.databaseId}`;
  const active = new Set();
  let closed = false;
  async function request(suffix, body, timeoutMs = 20000, onReady = () => {}) {
    if (closed) throw new Error('Connection is closed.');
    const controller = new AbortController();
    active.add(controller);
    let cancelled = false;
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
    try {
      onReady(() => { cancelled = true; controller.abort(); });
      if (controller.signal.aborted) throw new Error('Query cancelled.');
      const response = await fetchApi(base + suffix, {
        method: body ? 'POST' : 'GET',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        ...(body ? { body: JSON.stringify(body) } : {}),
        signal: controller.signal,
        redirect: 'error'
      });
      if (!response.ok && response.status !== 400) {
        await response.body?.cancel();
        const detail = response.status === 401 || response.status === 403
          ? 'Check the API token and its D1 Read or D1 Write permission for this account.'
          : response.status === 404 ? 'Check the Account ID and Database ID.'
          : response.status === 429 ? 'Cloudflare rate limit reached. Wait before trying again.'
          : 'Cloudflare could not complete the request.';
        throw new Error(`Query failed: Cloudflare D1 HTTP ${response.status}. ${detail}`);
      }
      const chunks = [];
      let size = 0;
      for await (const chunk of response.body) {
        size += chunk.byteLength;
        if (size > MAX_RESPONSE_BYTES) {
          controller.abort();
          throw new Error('Query failed: Cloudflare response exceeds 32 MB. Add a SQL LIMIT or select fewer columns.');
        }
        chunks.push(Buffer.from(chunk));
      }
      let data;
      try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { throw new Error('Query failed: Cloudflare returned an invalid response.'); }
      if (!response.ok || data.success !== true || (Array.isArray(data.result) && data.result.some(item => item.success === false))) {
        const failure = data.errors?.[0] || (Array.isArray(data.result) && data.result.find(item => item.success === false));
        throw queryError(new Error(failure?.message || failure?.error || 'Cloudflare D1 rejected the query.'), body?.sql || '', token);
      }
      return data.result;
    } catch (error) {
      if (cancelled || closed) throw new Error('Query cancelled.');
      if (timedOut) throw new Error('Query timed out. Cloudflare may still finish the request.');
      if (/^(Query failed|Connection is closed)/.test(error?.message || '')) throw error;
      throw new Error('Query failed: Could not reach Cloudflare D1. Check your network connection.');
    } finally {
      clearTimeout(timer);
      active.delete(controller);
    }
  }
  const raw = async (sql, params = [], timeoutMs, onReady) => {
    const results = await request('/raw', { sql, params: params.map(value => typeof value === 'boolean' ? Number(value) : value) }, timeoutMs, onReady);
    if (!Array.isArray(results) || !results.length || results.some(result =>
      (result.results?.columns !== undefined && !Array.isArray(result.results.columns)) ||
      (result.results?.rows !== undefined && !Array.isArray(result.results.rows)))) {
      throw new Error('Query failed: Cloudflare returned an invalid SQL result.');
    }
    return results.map(result => ({ ...result, results: { columns: result.results?.columns || [], rows: result.results?.rows || [] } }));
  };
  const metadata = async (sql, params = []) => {
    const [result] = await raw(sql, params);
    return result.results.rows.map(row => Object.fromEntries(result.results.columns.map((name, i) => [name, row[i]])));
  };
  const schemaName = schema => {
    if (schema && schema !== 'main') throw new Error('Invalid D1 schema. Use main.');
  };
  const info = await request(''); // Verify access without executing user SQL.
  if (!info || typeof info.name !== 'string') throw new Error('Could not connect to Cloudflare D1: invalid database response.');
  function display(result, limit, cellBatch) {
    const columns = result.results.columns.map(name => ({ name: String(name) }));
    const rows = [], cellRefs = [], budget = { bytes: 0 };
    for (const row of result.results.rows.slice(0, limit)) {
      if (!appendRow(rows, row, budget, cellRefs, cellBatch)) {
        if (!rows.length) {
          const error = new Error('Could not load table data: A row exceeds the 5 MB display limit.');
          error.code = 'ROW_TOO_LARGE';
          throw error;
        }
        break;
      }
    }
    return { columns, rows, cellRefs, hasMore: result.results.rows.length > rows.length,
      rowCount: columns.length ? rows.length : result.meta?.changes || 0 };
  }
  return {
    type: 'cloudflare_d1',
    databaseName: info.name,
    async close() { closed = true; for (const controller of active) controller.abort(); },
    async schemas() { return [{ name: 'main' }]; },
    async objects(schema) {
      schemaName(schema);
      return metadata(`SELECT 'main' AS schema, name, type FROM main.sqlite_schema
        WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
        AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' ORDER BY name LIMIT 2000`);
    },
    async describe(schema, name) {
      schemaName(schema);
      const columns = await metadata(`PRAGMA main.table_xinfo(${quote(name)})`);
      if (!columns.length) throw new Error('Could not find the D1 table or view. Refresh the schema.');
      const indexes = await metadata(`SELECT name, sql AS definition FROM main.sqlite_schema WHERE type = 'index' AND tbl_name = ? ORDER BY name`, [name]);
      return { columns: columns.filter(column => column.hidden !== 1).map(column => ({
        name: column.name, type: column.type || 'BLOB', nullable: !column.notnull,
        primaryKey: column.pk > 0, generated: column.hidden > 1, default: column.dflt_value
      })), indexes };
    },
    async createScript(schema, name) {
      schemaName(schema);
      const rows = await metadata(`SELECT type, sql FROM main.sqlite_schema
        WHERE tbl_name = ? AND type IN ('table','index','trigger') AND sql IS NOT NULL
        ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END, name`, [name]);
      if (!rows.some(row => row.type === 'table')) throw new Error('Could not read the CREATE TABLE definition.');
      return rows.map(row => row.sql.trim().replace(/;?$/, ';')).join('\n\n');
    },
    async rows(schema, name, limit, offset, onReady, cellBatch, readPlan) {
      schemaName(schema);
      const plan = readPlan || tableReadPlan('cloudflare_d1', 'main', name, null, { limit, offset });
      const [result] = await raw(plan.sql, plan.params, 30000, onReady);
      return { ...display(result, limit, cellBatch), offset };
    },
    async exportRows(plan, onReady) {
      // D1 returns a complete HTTP response instead of a row stream. Read small
      // batches and bypass display(), which shortens values and caps grid bytes.
      let offset = 0, batchSize = 250;
      while (true) {
        let result;
        try {
          [result] = await raw(plan.sql + ' LIMIT ? OFFSET ?', [...plan.params, batchSize, offset], plan.timeoutMs, onReady);
        } catch (error) {
          if (/response exceeds 32 MB/.test(error.message) && batchSize > 1) {
            batchSize = Math.max(1, Math.floor(batchSize / 2));
            continue;
          }
          throw error;
        }
        for (const row of result.results.rows) plan.exportRow(row);
        offset += result.results.rows.length;
        if (result.results.rows.length < batchSize) break;
      }
    },
    async run(sql, limit, timeoutMs, onReady, cellBatch) {
      const statements = await raw(sql, [], timeoutMs, onReady);
      const results = new QueryResults(limit, cellBatch);
      for (const statement of statements) {
        if (statement.results.columns.length) {
          const set = results.begin(statement.results.columns.map(name => ({ name: String(name) })));
          for (const row of statement.results.rows) results.row(set, row);
        }
        results.affectedRows += statement.meta?.changes || 0;
      }
      return results.finish(statements.length > 1 ? `${statements.length} SQL statements executed. All statements were sent to Cloudflare.` : '');
    }
  };
}
