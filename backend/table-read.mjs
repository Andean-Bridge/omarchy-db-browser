const dialects = new Set(['sqlserver', 'azure_sql', 'postgres', 'mysql', 'cloudflare_d1']);
const scalarType = /^(?:character varying|character|varchar|nvarchar|char|nchar|text|ntext|tinytext|mediumtext|longtext|citext|uuid|uniqueidentifier|tinyint|smallint|mediumint|int|integer|bigint|int2|int4|int8|decimal|numeric|money|smallmoney|real|float|double precision|double|boolean|bool|bit|date|datetime|datetime2|smalldatetime|datetimeoffset|timestamp|timestamptz|time|timetz)(?:\b|\()/i;
const textType = /^(?:character|varchar|nvarchar|char|nchar|text|ntext|tinytext|mediumtext|longtext|citext)(?:\b|\()/i;

export function tableColumnCapabilities(column, dialect = "") {
  const type = column?.type || '';
  // PostgreSQL arrays and MySQL bit vectors are not scalar editor fields.
  const scalar = scalarType.test(type) && !/\[\]|^bit\(/i.test(type);
  return { sortable: scalar && !(['sqlserver', 'azure_sql'].includes(dialect) && /^(?:text|ntext)$/i.test(type)), filterable: scalar, text: textType.test(type) };
}

function name(value) {
  if (typeof value !== 'string' || !value || value.length > 255 || /[\x00-\x1f]/.test(value)) throw new Error('Invalid table column or identifier.');
  return value;
}

// One read plan for all adapters: values remain parameters and identifiers must
// come from fresh metadata. Every existing caller may omit sort and filter.
export function tableReadPlan(type, schema, table, definition, { limit, offset, sort = null, filter = null, selectedColumns = null, unpaged = false } = {}) {
  if (!dialects.has(type)) throw new Error('Invalid database dialect.');
  if (!unpaged && (!Number.isInteger(limit) || limit < 1 || limit > 1000 || !Number.isInteger(offset) || offset < 0 || offset > 10000000)) throw new Error('Invalid table page.');
  const columns = definition?.columns || [];
  const quote = type === 'mysql' ? value => '`' + name(value).replaceAll('`', '``') + '`'
    : type === 'postgres' || type === 'cloudflare_d1' ? value => '"' + name(value).replaceAll('"', '""') + '"'
    : value => '[' + name(value).replaceAll(']', ']]') + ']';
  const params = [];
  const bind = value => { params.push(value); return type === 'mysql' || type === 'cloudflare_d1' ? '?' : type === 'postgres' ? '$' + params.length : '@p' + params.length; };
  const lookup = columnName => {
    const column = columns.find(column => column.name === columnName);
    if (!column) throw new Error('Invalid table column. Refresh the table definition.');
    return column;
  };
  let where = '';
  if (filter !== null) {
    if (!filter || typeof filter !== 'object' || Array.isArray(filter)) throw new Error('Invalid table filter.');
    const column = lookup(filter.column);
    const capabilities = tableColumnCapabilities(column, type);
    if (!capabilities.filterable) throw new Error('Invalid filter: this column type requires SQL.');
    const field = quote(column.name);
    const op = filter.operator;
    if (op === 'isNull' || op === 'notNull') where = `${field} IS ${op === 'notNull' ? 'NOT ' : ''}NULL`;
    else {
      const value = filter.value;
      if (!['string', 'number', 'boolean'].includes(typeof value) || (typeof value === 'string' && value.length > 2000) || (typeof value === 'number' && !Number.isFinite(value))) throw new Error('Invalid filter value (maximum 2,000 characters).');
      if (op === 'contains' || op === 'startsWith') {
        if (!capabilities.text || typeof value !== 'string') throw new Error('Invalid filter: contains and starts with require a text column.');
        const escaped = value.replace(/[!%_\[]/g, '!$&');
        where = `${field} LIKE ${bind((op === 'contains' ? '%' : '') + escaped + '%')} ESCAPE '!'`;
      } else {
        const operators = new Map([['equals', '='], ['notEqual', '<>'], ['greaterThan', '>'], ['lessThan', '<']]);
        const operator = operators.get(op);
        if (!operator) throw new Error('Invalid table filter operator.');
        // SQL Server's legacy text type cannot be compared directly.
        const expression = (type === 'sqlserver' || type === 'azure_sql') && /^(?:text|ntext)$/i.test(column.type) ? `CONVERT(nvarchar(max), ${field})` : field;
        where = `${expression} ${operator} ${bind(value)}`;
      }
    }
  }
  const order = [];
  if (sort !== null) {
    if (!sort || typeof sort !== 'object' || Array.isArray(sort) || !['asc', 'desc'].includes(sort.direction)) throw new Error('Invalid table sort.');
    const column = lookup(sort.column);
    if (!tableColumnCapabilities(column, type).sortable) throw new Error('Invalid sort: this column type requires SQL.');
    order.push({ column: column.name, direction: sort.direction });
  }
  for (const column of columns.filter(column => column.primaryKey)) {
    if (!order.some(item => item.column === column.name)) order.push({ column: column.name, direction: 'asc' });
  }
  let projection = '*';
  if (selectedColumns !== null) {
    if (!Array.isArray(selectedColumns) || !selectedColumns.length || new Set(selectedColumns).size !== selectedColumns.length) throw new Error('Invalid export columns. Select at least one column.');
    projection = selectedColumns.map(columnName => {
      const column = lookup(columnName);
      const field = quote(column.name);
      // Keep decimal and temporal precision before the SQL Server driver turns
      // these into JavaScript numbers or millisecond Date objects.
      if (unpaged && ['sqlserver', 'azure_sql'].includes(type)) {
        if (/^(decimal|numeric|money|smallmoney)$/i.test(column.type)) return `CONVERT(varchar(100), ${field}, 2) AS ${field}`;
        if (/^(date|datetime|datetime2|smalldatetime|datetimeoffset|time)$/i.test(column.type)) return `CONVERT(varchar(50), ${field}, 127) AS ${field}`;
      }
      return field;
    }).join(', ');
  }
  let sql = `SELECT ${projection} FROM ${quote(schema)}.${quote(table)}`;
  if (where) sql += ' WHERE ' + where;
  // Export projections may cast values to text for lossless serialization.
  // Qualify the source column so sorting never uses that text-valued alias.
  if (order.length) sql += ' ORDER BY ' + order.map(item => `${unpaged ? quote(table) + '.' : ''}${quote(item.column)} ${item.direction.toUpperCase()}`).join(', ');
  else if (!unpaged && (type === 'sqlserver' || type === 'azure_sql')) sql += ' ORDER BY (SELECT NULL)';
  if (!unpaged) {
    if (type === 'sqlserver' || type === 'azure_sql') sql += ` OFFSET ${bind(offset)} ROWS FETCH NEXT ${bind(limit + 1)} ROWS ONLY`;
    else if (type === 'mysql') sql += ` LIMIT ${limit + 1} OFFSET ${offset}`;
    else sql += ` LIMIT ${bind(limit + 1)} OFFSET ${bind(offset)}`;
  }
  return { sql, params, order, stableOrder: columns.some(column => column.primaryKey) };
}
