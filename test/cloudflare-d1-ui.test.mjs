import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, copyFile, cp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('native D1 connection form saves IDs and token, preserves saved credentials, and quotes SQLite SQL', async t => {
  if (spawnSync('quickshell', ['--version']).error) return t.skip('Quickshell is required for native UI checks.');
  const directory = await mkdtemp(path.join(tmpdir(), 'db-studio-d1-ui-'));
  t.after(() => rm(directory, {recursive:true,force:true}));
  for (const name of ['DbStudioPanel.qml','DbGrid.qml']) await copyFile(new URL(`../${name}`, import.meta.url), path.join(directory,name));
  // Include the editor when testing a working tree with the newer workbench.
  for (const name of ['SqlEditor.qml', 'editor']) {
    await cp(new URL(`../${name}`, import.meta.url),path.join(directory,name),{recursive:true}).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
  await cp(new URL('./qml/imports/qs/Commons',import.meta.url),path.join(directory,'Commons'),{recursive:true});
  const fixture = await readFile(new URL('./fixtures/d1.qml', import.meta.url),'utf8');
  await writeFile(path.join(directory,'shell.qml'),fixture.replace('import "../../" as App','import "./" as App'));
  const result = spawnSync('quickshell',['-p',directory],{encoding:'utf8',timeout:15000,cwd:directory,
    env:{...process.env,QT_QPA_PLATFORM:'offscreen'}});
  const output = result.stdout + result.stderr;
  assert.equal(result.status,0,output);
  assert.match(output,/D1_UI_PASSED/,output);
  assert.doesNotMatch(output,/D1_UI_FAILED|TypeError|ReferenceError|FAIL!/,output);
});
