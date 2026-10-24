import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, writeFile, rm, symlink, stat, readdir } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { readSqlFile, saveSqlFile } from '../backend/sql-files.mjs';

async function fixture(t) {
  const dir = await mkdtemp(path.join(os.tmpdir(),'db-studio-sql-files-'));
  t.after(() => rm(dir,{recursive:true,force:true}));
  return dir;
}

test('SQL files round-trip Unicode, blank scripts, permissions and revisions', async t => {
  const dir = await fixture(t);
  const file = path.join(dir,'consulta #1.SQL');
  const sql = "SELECT 'Lima 🇵🇪', 'áéíóú';\n";
  const saved = await saveSqlFile(file, sql);
  assert.equal((await stat(file)).mode & 0o777,0o600);
  const opened = await readSqlFile(file);
  assert.equal(opened.sql, sql);
  assert.equal(opened.revision, saved.revision);
  const blank = await saveSqlFile(file, '', {expectedRevision:opened.revision});
  assert.equal((await readSqlFile(file)).sql,'');
  assert.notEqual(blank.revision, opened.revision);
  assert.deepEqual(await readdir(dir),['consulta #1.SQL']);
});

test('external edits and deletions block stale saves without destroying disk contents', async t => {
  const dir = await fixture(t);
  const file = path.join(dir,'query.sql');
  await saveSqlFile(file,'SELECT 1;');
  const opened = await readSqlFile(file);
  await writeFile(file,'SELECT 2;');
  await assert.rejects(saveSqlFile(file,'SELECT 3;',{expectedRevision:opened.revision}),/changed outside/);
  assert.equal(await readFile(file,'utf8'),'SELECT 2;');
  await assert.rejects(saveSqlFile(file,'SELECT 4;'),/already exists/);
  await saveSqlFile(file,'SELECT 4;',{overwrite:true});
  assert.equal(await readFile(file,'utf8'),'SELECT 4;');
  await rm(file);
  await assert.rejects(saveSqlFile(file,'SELECT 5;',{expectedRevision:opened.revision}),/changed outside/);
});

test('non-SQL paths, symlinks, directories, invalid UTF-8, binary input and oversized files are rejected', async t => {
  const dir = await fixture(t);
  const file = path.join(dir,'query.sql');
  for (const input of ['relative.sql',path.join(dir,'notes.txt'),'',null]) {
    await assert.rejects(readSqlFile(input));
    await assert.rejects(saveSqlFile(input,'SELECT 1'));
  }
  await writeFile(file,Buffer.from([0xff,0xfe,0xff]));
  await assert.rejects(readSqlFile(file),/UTF-8/);
  await writeFile(file,'SELECT \0');
  await assert.rejects(readSqlFile(file),/limited/);
  await writeFile(file,'x'.repeat(800001));
  await assert.rejects(readSqlFile(file),/size/);
  await writeFile(file,'x'.repeat(200001));
  await assert.rejects(readSqlFile(file),/limited/);
  await assert.rejects(saveSqlFile(file,'\n'.repeat(10000)),/limited/);
  const link = path.join(dir,'link.sql');
  await symlink(file,link);
  await assert.rejects(readSqlFile(link),/regular/);
  await assert.rejects(saveSqlFile(link,'SELECT 1',{overwrite:true}),/regular/);
  await assert.rejects(saveSqlFile(file,'SELECT 1',{expectedRevision:'invalid'}),/revision/);
});
