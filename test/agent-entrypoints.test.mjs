import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import test from 'node:test';

const cliPath = new URL('../backend/cli.mjs', import.meta.url);
const mcpPath = new URL('../backend/mcp.mjs', import.meta.url);

test('CLI and MCP expose only enabled saved profiles', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-entrypoints-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const configDir = path.join(directory, 'omarchy', 'db-browser');
  await fs.mkdir(configDir, { recursive: true });
  await fs.writeFile(path.join(configDir, 'connections.json'), JSON.stringify({
    version: 1,
    profiles: [
      { id: '11111111-1111-4111-8111-111111111111', name: 'Enabled', type: 'mysql', agentAccess: true },
      { id: '22222222-2222-4222-8222-222222222222', name: 'Disabled', type: 'postgres', agentAccess: false }
    ]
  }));
  const env = { ...process.env, XDG_CONFIG_HOME: directory };

  const cli = spawn(process.execPath, [cliPath.pathname, 'profiles'], { env });
  let cliOutput = '';
  for await (const chunk of cli.stdout) cliOutput += chunk;
  assert.deepEqual(JSON.parse(cliOutput).profiles.map(profile => profile.name), ['Enabled']);

  const mcp = spawn(process.execPath, [mcpPath.pathname], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(() => mcp.kill());
  mcp.stderr.resume();
  const pending = new Map();
  const lines = readline.createInterface({ input: mcp.stdout });
  lines.on('line', line => {
    const message = JSON.parse(line);
    if (!pending.has(message.id)) return;
    pending.get(message.id)(message);
    pending.delete(message.id);
  });
  function request(id, method, params) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`MCP ${method} timed out`)); }, 5000);
      pending.set(id, message => { clearTimeout(timer); resolve(message); });
      mcp.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });
  }
  const initialized = await request(1, 'initialize', {
    protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'db-studio-test', version: '1.0.0' }
  });
  assert.equal(initialized.result.serverInfo.name, 'db-studio');
  mcp.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
  const listed = await request(2, 'tools/list', {});
  assert.equal(listed.result.tools.some(tool => tool.name === 'run_query'), true);
  const called = await request(3, 'tools/call', { name: 'list_connections', arguments: {} });
  assert.deepEqual(JSON.parse(called.result.content[0].text).map(profile => profile.name), ['Enabled']);
  mcp.stdin.end();
});
