import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { withProfileLock } from '../backend/operation-lock.mjs';
import { WorkerClient } from '../backend/worker-client.mjs';

const profileId = '11111111-1111-4111-8111-111111111111';
const cliPath = new URL('../backend/cli.mjs', import.meta.url).pathname;
const workerPath = new URL('../backend/worker.mjs', import.meta.url).pathname;

function collect(child) {
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  return new Promise(resolve => child.on('close', code => resolve({ code, stdout, stderr })));
}

test('agent worker open rechecks consent before accessing the keyring', async t => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-worker-test-'));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const config = path.join(home, 'omarchy', 'db-browser');
  await fs.mkdir(config, { recursive: true });
  await fs.writeFile(path.join(config, 'connections.json'), JSON.stringify({
    version: 1, profiles: [{ id: profileId, name: 'Disabled', type: 'mysql', agentAccess: false }]
  }));
  const client = new WorkerClient({ spawnWorker: () => spawn(process.execPath, [workerPath], {
    env: { ...process.env, XDG_CONFIG_HOME: home }, stdio: ['pipe', 'pipe', 'pipe']
  }) });
  t.after(() => client.close());
  await assert.rejects(client.call('agent.connection.open', { profileId }), /not found/);
  await assert.rejects(client.call('agent.connection.open', { profileId, password: 'override' }), /Invalid agent connection request/);
});

test('CLI bounds SQL read from files and stdin before opening a connection', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-sql-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'large.sql');
  await fs.writeFile(file, 'x'.repeat(200001));
  const fromFile = await collect(spawn(process.execPath, [cliPath, 'query', '--profile', 'Unused', '--file', file]));
  assert.equal(fromFile.code, 1);
  assert.match(fromFile.stderr, /SQL input must be under 200 KB/);
  const fromStdinProcess = spawn(process.execPath, [cliPath, 'query', '--profile', 'Unused', '--file', '-']);
  const fromStdinResult = collect(fromStdinProcess);
  fromStdinProcess.stdin.end('x'.repeat(200001));
  const fromStdin = await fromStdinResult;
  assert.equal(fromStdin.code, 1);
  assert.match(fromStdin.stderr, /SQL input must be under 200 KB/);
});

test('aborting a worker call sends a cancellation request for its operation ID', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-cancel-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const cancelFile = path.join(directory, 'cancelled-id');
  const workerCode = `
    const fs = require('node:fs');
    const readline = require('node:readline');
    readline.createInterface({ input: process.stdin }).on('line', line => {
      const request = JSON.parse(line);
      if (request.action === 'query.cancel') {
        fs.writeFileSync(process.argv[1], String(request.payload.targetId));
        process.stdout.write(JSON.stringify({ id: request.id, ok: true, data: { cancelled: true } }) + '\\n');
      }
    });
  `;
  const client = new WorkerClient({ spawnWorker: () => spawn(process.execPath, ['-e', workerCode, cancelFile], {
    stdio: ['pipe', 'pipe', 'pipe']
  }) });
  t.after(() => client.close());
  const controller = new AbortController();
  const pending = client.call('query.run', { sql: 'SELECT 1' }, { signal: controller.signal });
  controller.abort();
  await assert.rejects(pending, /cancelled/);
  let cancelledId;
  for (let attempt = 0; attempt < 50; attempt++) {
    try { cancelledId = await fs.readFile(cancelFile, 'utf8'); break; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal(cancelledId, '1');
});

test('agent calls for one profile serialize across processes and can be cancelled while waiting', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-lock-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  let enterFirst;
  let releaseFirst;
  const entered = new Promise(resolve => { enterFirst = resolve; });
  const release = new Promise(resolve => { releaseFirst = resolve; });
  const first = withProfileLock(profileId, async () => { enterFirst(); await release; }, { directory });
  await entered;
  await assert.rejects(withProfileLock(profileId, async () => {}, { directory, waitMs: 200 }), /busy/);
  const controller = new AbortController();
  const waiting = withProfileLock(profileId, async () => { throw new Error('Should not run'); }, {
    directory, signal: controller.signal
  });
  controller.abort();
  await assert.rejects(waiting, /cancelled/);
  releaseFirst();
  await first;
  assert.equal(await withProfileLock(profileId, async () => 'acquired', { directory }), 'acquired');
});
