const quote = (type, value) => type === 'mysql' ? '`' + String(value).replaceAll('`', '``') + '`'
  : ['sqlserver', 'azure_sql'].includes(type) ? '[' + String(value).replaceAll(']', ']]') + ']'
  : '"' + String(value).replaceAll('"', '""') + '"';
const end = sql => String(sql).trim().replace(/;?$/, ';');
const comment = value => String(value).replace(/[\r\n\u2028\u2029]/g, ' ');
const writable = (column, type) => !column.generated && !column.identity &&
  !/auto_increment|(?:virtual|stored) generated/i.test(column.extra || '') &&
  (!['sqlserver', 'azure_sql'].includes(type) || !/^(?:timestamp|rowversion)$/i.test(column.type || ''));

// Only metadata calls are allowed here. No generated statement is executed.
export async function generateTableScript(adapter, type, schema, name, action) {
  if (!['create', 'alter', 'insert', 'update'].includes(action)) throw new Error('Invalid table script action.');
  const object = (await adapter.objects(schema)).find(object => object.schema === schema && object.name === name);
  if (!object || object.type !== 'table') throw new Error('Could not generate a table script: select an existing table and refresh the schema.');
  const q = value => quote(type, value);
  const table = `${q(schema)}.${q(name)}`;
  let sql;
  if (action === 'create') {
    sql = await adapter.createScript(schema, name);
    if (!sql?.trim()) throw new Error('Could not read the complete CREATE TABLE definition. Check metadata permissions.');
  } else if (action === 'alter') {
    sql = `-- Replace the placeholders with the column name and SQL type to add.\nALTER TABLE ${table}\n    ADD ${type === 'sqlserver' || type === 'azure_sql' ? '' : 'COLUMN '}<column_name> <data_type> <NULL_or_NOT_NULL>;`;
  } else {
    const definition = await adapter.describe(schema, name);
    if (!definition.columns?.length) throw new Error('Could not read the table columns. Check metadata permissions.');
    const columns = definition.columns.filter(column => writable(column, type) && (action !== 'update' || !column.primaryKey));
    const value = column => `<value_${definition.columns.indexOf(column) + 1}>`;
    const notes = columns.map(column => `-- ${value(column)}: ${comment(column.name)} (${comment(column.type || 'value')})${column.nullable ? ', nullable' : ''}${column.default != null ? ', has default' : ''}`);
    if (action === 'insert') {
      sql = columns.length ? `INSERT INTO ${table} (\n    ${columns.map(column => q(column.name)).join(',\n    ')}\n)\nVALUES (\n    ${columns.map(value).join(',\n    ')}\n);`
        : type === 'mysql' ? `INSERT INTO ${table} () VALUES ();` : `INSERT INTO ${table} DEFAULT VALUES;`;
    } else {
      if (!columns.length) throw new Error('Could not generate UPDATE: this table has no writable non-key columns.');
      const keys = definition.columns.filter(column => column.primaryKey);
      sql = `UPDATE ${table}\nSET ${columns.map(column => `${q(column.name)} = ${value(column)}`).join(',\n    ')}\nWHERE ${keys.length ? keys.map((column, index) => `${q(column.name)} = <key_${index + 1}>`).join('\n  AND ') : '<row_condition>'};`;
      notes.push(...keys.map((column, index) => `-- <key_${index + 1}>: ${comment(column.name)} (${comment(column.type || 'value')})`));
    }
    sql = `-- Fill in each placeholder with a SQL literal or expression before running.\n${sql}\n\n${notes.join('\n')}`;
  }
  // Keep the same editor limits used for SQL files; never truncate a definition.
  if (sql.length > 200000 || sql.split('\n').length > 10000) throw new Error('Could not generate script: the definition exceeds the SQL editor limit.');
  return { sql: sql.trim() + '\n', action };
}

// PostgreSQL has deparsers for individual catalog objects, but no SHOW CREATE
// TABLE. Reject table features we cannot faithfully reconstruct.
export async function postgresCreateScript(metadata, schema, name) {
  const q = value => quote('postgres', value);
  const table = `${q(schema)}.${q(name)}`;
  const params = [schema, name];
  const [relation] = await metadata(`SELECT c.oid, c.relkind, c.relpersistence, c.relispartition,
    c.relrowsecurity, c.relforcerowsecurity, c.relreplident, c.reloptions,
    EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid=c.oid OR i.inhparent=c.oid) AS inherits,
    EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal) AS triggers,
    EXISTS (SELECT 1 FROM pg_rewrite r WHERE r.ev_class=c.oid) AS rules,
    ts.spcname AS tablespace
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    LEFT JOIN pg_tablespace ts ON ts.oid=c.reltablespace
    WHERE n.nspname=$1 AND c.relname=$2`, params);
  if (!relation || relation.relkind !== 'r' || relation.relispartition || relation.inherits || relation.triggers ||
      relation.rules || relation.relrowsecurity || relation.relforcerowsecurity || relation.relreplident !== 'd' || relation.relpersistence === 't') {
    throw new Error('Could not generate complete CREATE: PostgreSQL partitioned, inherited, foreign, temporary, or policy/rule/trigger tables and custom replica identities require a native schema dump.');
  }
  const columns = await metadata(`SELECT a.attname AS name, format_type(a.atttypid,a.atttypmod) AS type,
    a.attnotnull AS "notNull", a.attidentity AS identity, a.attgenerated AS generated,
    pg_get_expr(d.adbin,d.adrelid) AS expression,
    CASE WHEN a.attcollation <> t.typcollation THEN quote_ident(cn.nspname)||'.'||quote_ident(co.collname) END AS collation,
    sn.nspname AS "sequenceSchema", sc.relname AS "sequenceName", s.seqtypid::regtype::text AS "sequenceType",
    s.seqstart::text, s.seqincrement::text, s.seqmin::text, s.seqmax::text, s.seqcache::text, s.seqcycle
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_attribute a ON a.attrelid=c.oid JOIN pg_type t ON t.oid=a.atttypid
    LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
    LEFT JOIN pg_collation co ON co.oid=a.attcollation LEFT JOIN pg_namespace cn ON cn.oid=co.collnamespace
    LEFT JOIN pg_class sc ON sc.oid=pg_get_serial_sequence(quote_ident(n.nspname)||'.'||quote_ident(c.relname),a.attname)::regclass
    LEFT JOIN pg_namespace sn ON sn.oid=sc.relnamespace LEFT JOIN pg_sequence s ON s.seqrelid=sc.oid
    WHERE n.nspname=$1 AND c.relname=$2 AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum`, params);
  const constraints = await metadata(`SELECT con.conname AS name, pg_get_constraintdef(con.oid, false) AS definition
    FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname=$1 AND c.relname=$2 AND con.contype IN ('p','u','c','f','x') ORDER BY con.conname`, params);
  const indexes = await metadata(`SELECT pg_get_indexdef(i.indexrelid) AS definition, i.indisvalid AND i.indisready AS valid,
    i.indisclustered AS clustered
    FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname=$1 AND c.relname=$2 AND NOT EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid=i.indexrelid AND con.contype IN ('p','u','x'))
    ORDER BY i.indexrelid`, params);
  if (!columns.length || indexes.some(index => !index.valid || index.clustered)) throw new Error('Could not generate complete CREATE: unavailable columns or invalid/clustered indexes require a native schema dump.');
  const sequenceOptions = column => `START WITH ${column.seqstart} INCREMENT BY ${column.seqincrement} MINVALUE ${column.seqmin} MAXVALUE ${column.seqmax} CACHE ${column.seqcache} ${column.seqcycle ? '' : 'NO '}CYCLE`;
  const sequences = columns.filter(column => column.sequenceName && !column.identity);
  const before = sequences.map(column => `CREATE SEQUENCE ${q(column.sequenceSchema)}.${q(column.sequenceName)} AS ${column.sequenceType} ${sequenceOptions(column)};`);
  const lines = columns.map(column => {
    let line = `    ${q(column.name)} ${column.type}`;
    if (column.collation) line += ` COLLATE ${column.collation}`;
    if (column.generated) line += ` GENERATED ALWAYS AS (${column.expression}) ${column.generated === 'v' ? 'VIRTUAL' : 'STORED'}`;
    else if (column.identity) line += ` GENERATED ${column.identity === 'a' ? 'ALWAYS' : 'BY DEFAULT'} AS IDENTITY (SEQUENCE NAME ${q(column.sequenceSchema)}.${q(column.sequenceName)} ${sequenceOptions(column)})`;
    else if (column.expression != null) line += ` DEFAULT ${column.expression}`;
    if (column.notNull) line += ' NOT NULL';
    return line;
  });
  lines.push(...constraints.map(constraint => `    CONSTRAINT ${q(constraint.name)} ${constraint.definition}`));
  let create = `CREATE ${relation.relpersistence === 'u' ? 'UNLOGGED ' : ''}TABLE ${table} (\n${lines.join(',\n')}\n)`;
  if (relation.reloptions?.length) create += ` WITH (${relation.reloptions.join(', ')})`;
  if (relation.tablespace) create += ` TABLESPACE ${q(relation.tablespace)}`;
  return [...before, create + ';', ...sequences.map(column => `ALTER SEQUENCE ${q(column.sequenceSchema)}.${q(column.sequenceName)} OWNED BY ${table}.${q(column.name)};`),
    ...indexes.map(index => end(index.definition))].join('\n\n');
}
