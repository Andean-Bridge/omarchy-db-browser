const TYPES = new Set(['azure_sql', 'sqlserver', 'postgres', 'mysql']);

function booleanValue(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  if (typeof value === 'boolean') return value;
  if (/^(true|yes|1|on)$/i.test(String(value))) return true;
  if (/^(false|no|0|off)$/i.test(String(value))) return false;
  throw new Error('Invalid boolean connection option.');
}

function optionalPort(value) {
  if (value === undefined || value === null || value === '') return undefined;
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Port must be between 1 and 65535.');
  return port;
}

function requiredText(value, label, maxLength = 255) {
  if (typeof value !== 'string' || !value.trim() || value.length > maxLength || /[\x00-\x1f]/.test(value)) {
    throw new Error(`${label} is required and must be a single line.`);
  }
  return value.trim();
}

export function normalizeType(type) {
  const value = String(type || '').toLowerCase().replace(/[-\s]/g, '_');
  const normalized = ({postgresql: 'postgres', mssql: 'sqlserver', azure: 'azure_sql', sqlazure: 'azure_sql'})[value] || value;
  if (!TYPES.has(normalized)) throw new Error('Select Azure SQL, SQL Server, PostgreSQL, or MySQL.');
  return normalized;
}

function splitAdoString(text) {
  const parts = [];
  let value = '';
  let braces = false;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (char === '{' && !braces) braces = true;
    if (char === '}' && braces) {
      if (text[i + 1] === '}') { value += '}}'; i += 1; continue; }
      braces = false;
    }
    if (char === ';' && !braces) { parts.push(value); value = ''; }
    else value += char;
  }
  if (braces) throw new Error('The connection string has an unclosed brace.');
  if (value) parts.push(value);
  return parts;
}

function parseSqlServer(text, requestedType) {
  const values = new Map();
  for (const item of splitAdoString(text)) {
    if (!item.trim()) continue;
    const index = item.indexOf('=');
    if (index < 1) throw new Error('The SQL Server connection string is invalid.');
    const raw = item.slice(index + 1).trim();
    const value = raw.startsWith('{') && raw.endsWith('}')
      ? raw.slice(1, -1).replaceAll('}}', '}') : raw;
    values.set(item.slice(0, index).trim().toLowerCase().replace(/[ _]/g, ''), value);
  }
  const get = (...keys) => keys.map(key => values.get(key)).find(value => value !== undefined);
  if (booleanValue(get('integratedsecurity', 'trustedconnection'), false)) {
    throw new Error('Integrated Security is not supported yet; use a SQL login.');
  }
  const authentication = get('authentication');
  if (authentication && !/^(sqlpassword|default)$/i.test(authentication)) {
    throw new Error('This SQL Server authentication mode is not supported yet.');
  }
  let server = get('server', 'datasource', 'address', 'addr', 'networkaddress', 'host') || '';
  server = server.replace(/^tcp:/i, '');
  let port = get('port');
  if (server.includes(',')) {
    const index = server.lastIndexOf(',');
    port ??= server.slice(index + 1);
    server = server.slice(0, index);
  }
  if (server.includes('\\')) throw new Error('Named SQL Server instances are not supported; provide host and TCP port.');
  const type = requestedType || (server.toLowerCase().endsWith('.database.windows.net') ? 'azure_sql' : 'sqlserver');
  return {
    profile: {
      type,
      host: server,
      port,
      database: get('database', 'initialcatalog') || '',
      user: get('userid', 'uid', 'user') || '',
      encrypt: get('encrypt'),
      trustServerCertificate: get('trustservercertificate')
    },
    password: get('password', 'pwd')
  };
}

function parseMysql(text) {
  const values = new Map();
  for (const item of splitAdoString(text)) {
    if (!item.trim()) continue;
    const index = item.indexOf('=');
    if (index < 1) throw new Error('The MySQL connection string is invalid.');
    const raw = item.slice(index + 1).trim();
    const value = raw.startsWith('{') && raw.endsWith('}')
      ? raw.slice(1, -1).replaceAll('}}', '}') : raw;
    values.set(item.slice(0, index).trim().toLowerCase().replace(/[ _]/g, ''), value);
  }
  const get = (...keys) => keys.map(key => values.get(key)).find(value => value !== undefined);
  const sslMode = get('sslmode');
  let ssl;
  if (sslMode !== undefined) {
    if (/^(none|disabled|disable|false|0)$/i.test(sslMode)) ssl = false;
    else if (/^(required|require|verifyca|verifyfull|true|1)$/i.test(sslMode)) ssl = true;
    else throw new Error('Unsupported MySQL SSL mode.');
  } else {
    ssl = get('ssl');
  }
  return {
    profile: {
      type: 'mysql',
      host: get('server', 'datasource', 'host') || '',
      port: get('port'),
      database: get('database', 'initialcatalog') || '',
      user: get('userid', 'uid', 'user', 'username') || '',
      ssl
    },
    password: get('password', 'pwd') ?? ''
  };
}

function parseUrl(text, requestedType) {
  let url;
  try { url = new URL(text); } catch { throw new Error('The database URL is invalid.'); }
  const scheme = url.protocol.slice(0, -1);
  const type = scheme === 'postgresql' || scheme === 'postgres' ? 'postgres' : scheme === 'mysql' ? 'mysql' : null;
  if (!type || (requestedType && requestedType !== type)) throw new Error('The connection URL does not match the selected database type.');
  const sslmode = url.searchParams.get('sslmode');
  return {
    profile: {
      type,
      host: url.hostname,
      port: url.port || undefined,
      database: decodeURIComponent(url.pathname.replace(/^\//, '')),
      user: decodeURIComponent(url.username),
      ssl: sslmode ? !/^(disable|false)$/i.test(sslmode) : undefined
    },
    password: decodeURIComponent(url.password)
  };
}

export function parseConnectionString(text, requestedType) {
  if (typeof text !== 'string' || !text.trim() || text.length > 8192) throw new Error('Enter a connection string.');
  const type = requestedType ? normalizeType(requestedType) : undefined;
  if (/^(postgres(ql)?|mysql):\/\//i.test(text)) return parseUrl(text, type);
  if (type === 'mysql') return parseMysql(text);
  if (type === 'postgres') throw new Error('Use a postgres:// URL.');
  return parseSqlServer(text, type);
}

export function normalizeProfile(input = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid connection profile.');
  const type = normalizeType(input.type);
  const profile = {
    name: requiredText(input.name, 'Connection name', 100),
    type,
    host: requiredText(input.host, 'Host'),
    port: optionalPort(input.port) || ({azure_sql: 1433, sqlserver: 1433, postgres: 5432, mysql: 3306})[type],
    database: requiredText(input.database, 'Database'),
    user: requiredText(input.user, 'User'),
    ssl: type === 'postgres' || type === 'mysql' ? booleanValue(input.ssl, false) : undefined,
    encrypt: type === 'azure_sql' ? true : type === 'sqlserver' ? booleanValue(input.encrypt, true) : undefined,
    trustServerCertificate: type === 'azure_sql' ? false : type === 'sqlserver' ? booleanValue(input.trustServerCertificate, false) : undefined
  };
  if (type === 'azure_sql' && input.trustServerCertificate === true) {
    throw new Error('Azure SQL requires server certificate validation.');
  }
  return profile;
}
