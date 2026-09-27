import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { AgentBridge } from '../backend/agent-bridge.mjs';
import { ProfileStore } from '../backend/profiles.mjs';

test('AI access is off for old profiles and must be explicitly enabled on a remembered profile', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-agent-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const filePath = path.join(directory, 'connections.json');
  const secrets = new Map();
  const keyring = {
    async store(id, value) { secrets.set(id, value); },
    async lookup(id) { return secrets.get(id) || ''; },
    async clear(id) { secrets.delete(id); }
  };
  const store = new ProfileStore({ filePath, keyring });
  const saved = await store.save({
    profile: { name: 'Local', type: 'mysql', host: 'localhost', database: 'dev', user: 'dev' },
    password: '', savePassword: true
  });
  assert.equal(saved.profile.agentAccess, false);
  await fs.writeFile(filePath, JSON.stringify({ version: 1, profiles: [{ id: saved.profile.id, name: 'Local', type: 'mysql' }] }));
  assert.equal((await new ProfileStore({ filePath, keyring }).list())[0].agentAccess, false);

  const enabled = await store.save({
    profile: { id: saved.profile.id, name: 'Local', type: 'mysql' }, agentAccess: true
  });
  assert.equal(enabled.profile.agentAccess, true);
  assert.equal(JSON.parse(await fs.readFile(filePath, 'utf8')).profiles[0].agentAccess, true);
  const duplicate = await store.duplicate(saved.profile.id);
  assert.equal(duplicate.profile.agentAccess, false);
  const disabled = await store.save({
    profile: { id: saved.profile.id, name: 'Local', type: 'mysql' }, agentAccess: false
  });
  assert.equal(disabled.profile.agentAccess, false);
  await assert.rejects(store.credentials(saved.profile.id, { requireAgentAccess: true }), /not found/);
  await store.save({ profile: { id: saved.profile.id, name: 'Local', type: 'mysql' }, agentAccess: true });
  assert.equal((await store.credentials(saved.profile.id, { requireAgentAccess: true })).meta.id, saved.profile.id);
});

test('bridge blocks disabled profiles and closes an enabled connection after a query', async () => {
  const calls = [];
  const profiles = [
    { id: 'enabled', name: 'Enabled', hasStoredConnection: true, agentAccess: true },
    { id: 'disabled', name: 'Disabled', hasStoredConnection: true, agentAccess: false },
    { id: 'session', name: 'Session', hasStoredConnection: false, agentAccess: true }
  ];
  const worker = {
    async call(action, payload) {
      calls.push({ action, payload });
      if (action === 'profiles.list') return { profiles };
      if (action === 'agent.connection.open') return { connectionId: 'open-id' };
      if (action === 'query.run') return {
        columns: [{ name: 'value' }], rows: [['preview…']],
        cellRefs: [{ row: 0, column: 0, handle: 'private-handle', byteLength: 10000 }]
      };
      if (action === 'connection.close') return { closed: true };
      throw new Error(`Unexpected action: ${action}`);
    },
    async close() {}
  };
  const bridge = new AgentBridge({ worker, lock: async (_id, task) => task() });
  assert.deepEqual((await bridge.profiles()).map(profile => profile.name), ['Enabled']);
  await assert.rejects(bridge.query('Disabled', 'SELECT 1'), /not found/);
  assert.equal(calls.some(call => call.action === 'agent.connection.open'), false);
  const data = await bridge.query('Enabled', 'SELECT 1');
  assert.deepEqual(data.rows, [['preview…']]);
  assert.deepEqual(data.truncatedCells, [{ row: 0, column: 0, byteLength: 10000 }]);
  assert.equal(JSON.stringify(data).includes('private-handle'), false);
  assert.deepEqual(calls.slice(-3).map(call => call.action), ['agent.connection.open', 'query.run', 'connection.close']);
  assert.equal(calls.at(-2).payload.limit, undefined);
});
