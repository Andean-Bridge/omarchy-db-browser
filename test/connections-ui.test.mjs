import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, cp, copyFile, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

for (const width of [1200,760]) test(`native connection workspaces isolate background results, cancellation, browser state, and unsaved work at ${width}px`, async t => {
  if (spawnSync('quickshell',['--version']).error) return t.skip('Quickshell is required for native UI checks.');
  const directory=await mkdtemp(path.join(tmpdir(),'db-studio-connections-ui-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  for(const name of ['DbStudioPanel.qml','ConnectionWorkspace.qml','DbGrid.qml','SqlEditor.qml','editor'])
    await cp(new URL(`../${name}`,import.meta.url),path.join(directory,name),{recursive:true});
  await cp(new URL('./qml/imports/qs/Commons',import.meta.url),path.join(directory,'Commons'),{recursive:true});
  await mkdir(path.join(directory,'backend'));
  await copyFile(new URL('./fixtures/connections-worker.fixture',import.meta.url),path.join(directory,'backend/worker.mjs'));
  const fixture=await readFile(new URL('./fixtures/connections.qml',import.meta.url),'utf8');
  await writeFile(path.join(directory,'shell.qml'),fixture.replace('import "../../" as App','import "./" as App')
    .replace('window.implicitWidth=1200',`window.implicitWidth=${width}`)
    .replace('window.implicitHeight=800',`window.implicitHeight=${width<1000?480:800}`));
  const result=spawnSync('quickshell',['-p',directory],{encoding:'utf8',timeout:20000,cwd:directory,env:{...process.env,QT_QPA_PLATFORM:'offscreen'}});
  const output=result.stdout+result.stderr;
  assert.equal(result.status,0,output);
  assert.match(output,/CONNECTIONS_UI_PASSED/,output);
  assert.doesNotMatch(output,/CONNECTIONS_UI_FAILED|TypeError|ReferenceError|FAIL!|Binding loop|Cannot assign/,output);
});
