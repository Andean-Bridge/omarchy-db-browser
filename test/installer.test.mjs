import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import test from 'node:test';

const run = promisify(execFile);
const repo = new URL('..', import.meta.url).pathname;

test('setup preserves foreign links and cleanup removes only this installation', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-install-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const home = path.join(directory, 'home');
  const plugin = path.join(directory, 'plugin');
  const fakeBin = path.join(directory, 'fake-bin');
  await fs.mkdir(path.join(plugin, 'assets'), { recursive: true });
  await fs.mkdir(path.join(plugin, 'bin'), { recursive: true });
  await fs.mkdir(path.join(plugin, 'skills', 'db-studio'), { recursive: true });
  await fs.mkdir(fakeBin);
  for (const file of ['setup.sh', 'uninstall.sh', 'manifest.json', 'package-lock.json', 'db-studio.desktop']) {
    await fs.copyFile(path.join(repo, file), path.join(plugin, file));
  }
  await fs.copyFile(path.join(repo, 'assets/db-studio.svg'), path.join(plugin, 'assets/db-studio.svg'));
  await fs.copyFile(path.join(repo, 'bin/db-studio'), path.join(plugin, 'bin/db-studio'));
  await fs.copyFile(path.join(repo, 'skills/db-studio/SKILL.md'), path.join(plugin, 'skills/db-studio/SKILL.md'));
  for (const command of ['omarchy', 'omarchy-shell', 'npm']) {
    await fs.writeFile(path.join(fakeBin, command), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  }
  const env = { ...process.env, HOME: home, XDG_DATA_HOME: path.join(home, 'share'), PATH: `${fakeBin}:${process.env.PATH}` };
  const commandLink = path.join(home, '.local/bin/db-studio');
  const foreign = path.join(directory, 'foreign-command');
  await fs.mkdir(path.dirname(commandLink), { recursive: true });
  await fs.writeFile(foreign, 'foreign');
  await fs.symlink(foreign, commandLink);
  await run('bash', [path.join(plugin, 'setup.sh')], { env });
  assert.equal(await fs.readlink(commandLink), foreign);

  await fs.rm(commandLink);
  await run('bash', [path.join(plugin, 'setup.sh')], { env });
  assert.equal(await fs.readlink(commandLink), path.join(plugin, 'bin/db-studio'));
  const codexSkill = path.join(home, '.codex/skills/db-studio');
  assert.equal(await fs.readlink(codexSkill), path.join(plugin, 'skills/db-studio'));

  const desktop = path.join(home, 'share/applications/db-studio.desktop');
  await fs.appendFile(desktop, '\n# customized\n');
  await run('bash', [path.join(plugin, 'uninstall.sh')], { env });
  await assert.rejects(fs.lstat(commandLink), { code: 'ENOENT' });
  await assert.rejects(fs.lstat(codexSkill), { code: 'ENOENT' });
  assert.match(await fs.readFile(desktop, 'utf8'), /customized/);
  await assert.rejects(fs.lstat(path.join(home, 'share/icons/hicolor/scalable/apps/db-studio.svg')), { code: 'ENOENT' });
  await run('bash', [path.join(plugin, 'uninstall.sh')], { env });
});
