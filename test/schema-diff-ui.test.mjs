import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, copyFile, cp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

test('native schema diff supports mixed type selection, filtered bulk actions, and retained script scope', async t => {
  if (spawnSync('quickshell', ['--version']).error) return t.skip('Quickshell is required for native UI checks.');
  const directory = await mkdtemp(path.join(tmpdir(), 'db-studio-diff-ui-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  for (const name of ['ConnectionWorkspace.qml', 'DbGrid.qml', 'SqlEditor.qml']) {
    await copyFile(new URL(`../${name}`, import.meta.url), path.join(directory, name));
  }
  await cp(new URL('./qml/imports/qs/Commons',import.meta.url),path.join(directory,'Commons'),{recursive:true});
  await mkdir(path.join(directory,'editor'));
  await copyFile(new URL('../editor/sql-language.js',import.meta.url),path.join(directory,'editor/sql-language.js'));
  const fixture = await readFile(new URL('./fixtures/schema-diff.qml', import.meta.url), 'utf8');
  await writeFile(path.join(directory, 'shell.qml'), fixture.replace('import "../../"', 'import "./"'));
  const result = spawnSync('quickshell', ['-p', directory], { encoding: 'utf8', timeout: 15000,
    env: { ...process.env, QT_QPA_PLATFORM: 'offscreen', QML_IMPORT_PATH: fileURLToPath(new URL('./qml/imports', import.meta.url)) } });
  const output = result.stdout + result.stderr;
  assert.equal(result.status, 0, output);
  assert.match(output, /SCHEMA_DIFF_UI_PASSED/, output);
  assert.doesNotMatch(output, /SCHEMA_DIFF_UI_FAILED|TypeError|ReferenceError|FAIL!/, output);
});
