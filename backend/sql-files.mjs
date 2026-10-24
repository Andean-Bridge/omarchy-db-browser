import { constants } from 'node:fs';
import { open, lstat, rename, unlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';

const MAX_CHARACTERS = 200000;
const MAX_BYTES = MAX_CHARACTERS * 4;
const revision = buffer => createHash('sha256').update(buffer).digest('hex');
function sqlPath(filePath) {
  if (typeof filePath !== 'string' || filePath.length > 4096 || /[\x00-\x1f]/.test(filePath) || !path.isAbsolute(filePath) || path.extname(filePath).toLowerCase() !== '.sql') throw new Error('Choose an absolute .sql file path.');
  return filePath;
}
function sqlText(sql) {
  if (typeof sql !== 'string' || sql.length > MAX_CHARACTERS || sql.includes('\0') || sql.split('\n').length > 10000) throw new Error('SQL files are limited to 200,000 characters and 10,000 lines of text.');
  return sql;
}

export async function readSqlFile(filePath) {
  sqlPath(filePath);
  let file;
  try {
    file = await open(filePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > MAX_BYTES) throw new Error('Invalid SQL file size or type.');
    // Bound the read even if the file grows after stat().
    const buffer = Buffer.alloc(Math.min(MAX_BYTES + 1, stat.size + 1));
    let bytesRead = 0;
    while (bytesRead < buffer.length) {
      const read = await file.read(buffer, bytesRead, buffer.length - bytesRead, null);
      if (!read.bytesRead) break;
      bytesRead += read.bytesRead;
    }
    if (bytesRead !== stat.size || bytesRead > MAX_BYTES) throw new Error('SQL file changed while opening. Try again.');
    const contents = buffer.subarray(0, bytesRead);
    let sql;
    try { sql = new TextDecoder('utf-8', { fatal: true }).decode(contents); }
    catch { throw new Error('SQL files must contain UTF-8 text.'); }
    return { filePath, sql: sqlText(sql), revision: revision(contents) };
  } catch (error) {
    if (/^(SQL files|SQL file|Invalid SQL)/.test(error.message)) throw new Error('Could not open SQL file: ' + error.message);
    throw new Error('Could not open SQL file. Choose a readable, regular .sql file.');
  } finally { await file?.close(); }
}

export async function saveSqlFile(filePath, sql, { expectedRevision, overwrite = false } = {}) {
  sqlPath(filePath);
  sqlText(sql);
  let stat;
  try { stat = await lstat(filePath); }
  catch (error) { if (error.code !== 'ENOENT') throw new Error('Could not inspect the SQL file.'); }
  if (stat && !stat.isFile()) throw new Error('Could not save SQL: choose a regular file, not a symbolic link or directory.');
  if (expectedRevision !== undefined) {
    if (typeof expectedRevision !== 'string' || !/^[a-f0-9]{64}$/.test(expectedRevision)) throw new Error('Invalid SQL file revision.');
    if (!stat || (await readSqlFile(filePath)).revision !== expectedRevision) throw new Error('Could not save SQL: the file changed outside DB Studio. Reopen it or use Save as.');
  } else if (stat && !overwrite) throw new Error('Could not save SQL: the file already exists. Choose another path or confirm replacement in Save as.');
  const temporary = path.join(path.dirname(filePath), '.' + path.basename(filePath) + '.' + randomUUID() + '.tmp');
  let file;
  try {
    file = await open(temporary, 'wx', stat ? stat.mode & 0o777 : 0o600);
    await file.writeFile(sql, 'utf8');
    await file.sync();
    await file.close();
    file = null;
    await rename(temporary, filePath);
    return { filePath, revision: revision(Buffer.from(sql)), saved: true };
  } catch { throw new Error('Could not save the SQL file. Check the folder and file permissions.'); }
  finally { await file?.close(); await unlink(temporary).catch(() => {}); }
}
