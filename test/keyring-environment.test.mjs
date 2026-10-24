import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { KeyringError, keyringEnvironment } from '../backend/keyring-environment.mjs';

const uid = 1234;
const runtime = { uid, mode: 0o40700, isDirectory: () => true };
const socket = { uid, isSocket: () => true };

test('headless agents recover the current user session bus without changing their environment', async () => {
  const env = { PATH: '/bin' };
  const visited = [];
  const result = await keyringEnvironment({ env, platform: 'linux', uid, stat: async file => {
    visited.push(file);
    return file.endsWith('/bus') ? socket : runtime;
  } });
  assert.equal(result.DBUS_SESSION_BUS_ADDRESS, 'unix:path=/run/user/1234/bus');
  assert.deepEqual(visited, ['/run/user/1234', '/run/user/1234/bus']);
  assert.deepEqual(env, { PATH: '/bin' });
});

test('explicit bus addresses and non-Linux environments are preserved', async () => {
  const stat = async () => assert.fail('Should not discover another bus');
  const env = { DBUS_SESSION_BUS_ADDRESS: 'unix:abstract=custom-session' };
  assert.deepEqual(await keyringEnvironment({ env, platform: 'linux', uid, stat }), env);
  assert.deepEqual(await keyringEnvironment({ env: {}, platform: 'darwin', stat }), {});
});

test('custom runtime paths are honored and D-Bus reserved characters are escaped', async () => {
  const env = { XDG_RUNTIME_DIR: '/private/session,one' };
  const visited = [];
  const result = await keyringEnvironment({ env, platform: 'linux', uid, stat: async file => {
    visited.push(file);
    return file.endsWith('/bus') ? socket : runtime;
  } });
  assert.equal(result.DBUS_SESSION_BUS_ADDRESS, 'unix:path=/private/session%2cone/bus');
  assert.deepEqual(visited, ['/private/session,one', '/private/session,one/bus']);
});

test('missing, public, foreign-owned, and non-socket session buses fail with safe guidance', async () => {
  for (const [directoryStat, busStat] of [
    [{ ...runtime, uid: uid + 1 }, socket],
    [{ ...runtime, mode: 0o40755 }, socket],
    [{ ...runtime, isDirectory: () => false }, socket],
    [runtime, { ...socket, uid: uid + 1 }],
    [runtime, { ...socket, isSocket: () => false }],
    [null, null]
  ]) {
    await assert.rejects(keyringEnvironment({ env: {}, platform: 'linux', uid, stat: async file => {
      if (!directoryStat) throw new Error('private filesystem detail');
      return file.endsWith('/bus') ? busStat : directoryStat;
    } }), error => error instanceof KeyringError && /desktop session bus/.test(error.message) &&
      !error.message.includes('private filesystem detail'));
  }
  await assert.rejects(keyringEnvironment({ env: { XDG_RUNTIME_DIR: 'relative' }, platform: 'linux', uid }), /desktop session bus/);
});

test('saved enabled profiles reopen from a separate process with no D-Bus address; consent is still checked first', {
  skip: process.platform !== 'linux', timeout: 10000
}, async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-keyring-'));
  await fs.chmod(directory, 0o700);
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(path.join(directory, 'bus'), resolve); });
  t.after(() => new Promise(resolve => server.close(resolve)));
  const marker = path.join(directory, 'lookup');
  const definition = 'omarchy-db-browser:v1:' + JSON.stringify({
    profile: { type: 'mysql', host: 'localhost', database: 'fixture', user: 'reader' }, password: 'fixture-password'
  });
  await fs.writeFile(path.join(directory, 'secret-tool'), `#!${process.execPath}
    const fs = require('node:fs');
    if (process.env.DBUS_SESSION_BUS_ADDRESS !== ${JSON.stringify(`unix:path=${directory}/bus`)}) process.exit(2);
    fs.writeFileSync(${JSON.stringify(marker)}, 'lookup');
    process.stdout.write(${JSON.stringify(definition + '\n')});
  `, { mode: 0o700 });
  const id = '11111111-1111-4111-8111-111111111111';
  const filePath = path.join(directory, 'connections.json');
  const profiles = [
    { id, name: 'Enabled', type: 'mysql', agentAccess: true },
    { id: '22222222-2222-4222-8222-222222222222', name: 'Disabled', type: 'mysql', agentAccess: false }
  ];
  await fs.writeFile(filePath, JSON.stringify({ version: 1, profiles }));
  const moduleUrl = new URL('../backend/profiles.mjs', import.meta.url).href;
  const child = spawn(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { promises as fs } from 'node:fs';
    import { ProfileStore } from ${JSON.stringify(moduleUrl)};
    const store = new ProfileStore({ filePath: ${JSON.stringify(filePath)} });
    await assert.rejects(store.credentials(${JSON.stringify(profiles[1].id)}, { requireAgentAccess: true }), /not found/);
    await assert.rejects(fs.stat(${JSON.stringify(marker)}), { code: 'ENOENT' });
    const result = await store.credentials(${JSON.stringify(id)}, { requireAgentAccess: true });
    assert.equal(result.profile.database, 'fixture');
    assert.equal(result.password, 'fixture-password');
    await fs.writeFile(${JSON.stringify(path.join(directory, 'secret-tool'))}, ${JSON.stringify(`#!${process.execPath}\nprocess.stderr.write('private-keyring-detail'); process.exit(1);\n`)});
    await assert.rejects(store.credentials(${JSON.stringify(id)}, { requireAgentAccess: true }), error =>
      /running and unlocked/.test(error.message) && !error.message.includes('private-keyring-detail'));
    await fs.unlink(${JSON.stringify(path.join(directory, 'secret-tool'))});
    await assert.rejects(store.credentials(${JSON.stringify(id)}, { requireAgentAccess: true }), /requires secret-tool/);
    console.log('reopened');
  `], { env: { PATH: directory, HOME: directory, XDG_RUNTIME_DIR: directory } });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
  assert.equal(code, 0, stderr);
  assert.equal(stdout.trim(), 'reopened');
  assert.equal(await fs.readFile(marker, 'utf8'), 'lookup');
});
