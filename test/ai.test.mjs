import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { aiAvailability, codexReady, compactCatalog, compactDefinitions, generateAiQuery, omarchyDefaultAgent, runCodex } from '../backend/ai.mjs';
import { WorkerClient } from '../backend/worker-client.mjs';

test('Omarchy agent selection is read without modifying its defaults', async t => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-agent-'));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  assert.equal(await omarchyDefaultAgent({ home }), '');
  await fs.mkdir(path.join(home, '.config/omarchy/defaults'), { recursive: true });
  await fs.writeFile(path.join(home, '.config/omarchy/defaults/agent'), 'codex\n');
  assert.equal(await omarchyDefaultAgent({ home }), 'codex');
});

test('AI availability requires Codex as the selected agent and a successful login status', async () => {
  let checks = 0;
  const checkCodex = async () => { checks++; return true; };
  assert.deepEqual(await aiAvailability({ readAgent: async () => '', checkCodex }), { available: false, agent: '' });
  assert.deepEqual(await aiAvailability({ readAgent: async () => 'claude', checkCodex }), { available: false, agent: 'claude' });
  assert.equal(checks, 0);
  assert.deepEqual(await aiAvailability({ readAgent: async () => 'codex', checkCodex }), { available: true, agent: 'codex' });
  assert.equal(checks, 1);
  assert.deepEqual(await aiAvailability({ readAgent: async () => 'codex', checkCodex: async () => false }),
    { available: false, agent: 'codex' });
  let invocation;
  assert.equal(await codexReady({ environment: { PATH: '/usr/bin', HOME: '/tmp/fake-home', DB_PASSWORD: 'private' },
    run: async (command, args, options) => { invocation = { command, args, options }; }
  }), true);
  assert.equal(invocation.command, 'codex');
  assert.deepEqual(invocation.args, ['login', 'status']);
  assert.equal(invocation.options.env.DB_PASSWORD, undefined);
  assert.equal(await codexReady({ run: async () => { throw new Error('not installed'); } }), false);
});

test('worker AI status follows Omarchy selection and installed Codex login', async t => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'db-studio-ai-status-'));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const defaults = path.join(home, '.config/omarchy/defaults');
  const fakeBin = path.join(home, 'bin');
  await fs.mkdir(defaults, { recursive: true });
  await fs.mkdir(fakeBin);
  const codexPath = path.join(fakeBin, 'codex');
  await fs.writeFile(codexPath, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const workerPath = new URL('../backend/worker.mjs', import.meta.url).pathname;
  const client = new WorkerClient({ spawnWorker: () => spawn(process.execPath, [workerPath], {
    env: { ...process.env, HOME: home, PATH: fakeBin }, stdio: ['pipe', 'pipe', 'pipe']
  }) });
  t.after(() => client.close());
  assert.equal((await client.call('ai.status')).available, false);
  await fs.writeFile(path.join(defaults, 'agent'), 'claude\n');
  assert.equal((await client.call('ai.status')).available, false);
  await fs.writeFile(path.join(defaults, 'agent'), 'codex\n');
  assert.equal((await client.call('ai.status')).available, true);
  await fs.writeFile(codexPath, '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  assert.equal((await client.call('ai.status')).available, false);
  await fs.rm(codexPath);
  assert.equal((await client.call('ai.status')).available, false);
  assert.equal(Array.isArray((await client.call('profiles.list')).profiles), true);
});

test('AI generation stops before reading schema when Codex is unavailable', async () => {
  let inspected = false;
  await assert.rejects(generateAiQuery({
    connection: { profile: { type: 'postgres' }, adapter: { async objects() { inspected = true; return []; } } },
    instruction: 'Draft a query', readAgent: async () => 'codex', checkCodex: async () => false
  }), /not installed or signed in/);
  assert.equal(inspected, false);
});

test('AI uses a compact 500-object catalog and describes only selected tables', async () => {
  const objects = Array.from({ length: 498 }, (_, index) => ({ schema: 'sales', name: `archive_${index}`, type: 'table' }));
  objects.push({ schema: 'sales', name: 'orders', type: 'table' });
  objects.push({ schema: 'sales', name: 'customers', type: 'table' });
  const catalog = compactCatalog(objects);
  assert.equal(catalog.objects.length, 500);
  assert.ok(catalog.text.length < 18000);
  assert.ok(!catalog.text.includes('email:varchar'));
  const rankedCatalog = compactCatalog(objects, null, 'Join orders to customers SELECT bad FROM sales.orders');
  const ids = ['sales.orders', 'sales.customers'].map(name =>
    rankedCatalog.objects.find(object => `${object.schema}.${object.name}` === name).id);
  const described = [];
  const prompts = [];
  const connection = {
    profile: { type: 'postgres', host: 'private.example', password: 'NeverSendMe' },
    adapter: {
      async objects() { return objects; },
      async describe(schema, name) {
        described.push(`${schema}.${name}`);
        return { columns: name === 'orders'
          ? [{ name: 'id', type: 'integer', primaryKey: true }, { name: 'customer_id', type: 'integer' }]
          : [{ name: 'id', type: 'integer', primaryKey: true }, { name: 'email', type: 'text' }] };
      }
    }
  };
  const result = await generateAiQuery({
    connection,
    instruction: 'Join orders to customers',
    sql: 'SELECT bad FROM sales.orders',
    error: 'Query failed: column bad does not exist',
    readAgent: async () => 'codex',
    checkCodex: async () => true,
    runModel: async (prompt, schema) => {
      prompts.push({ prompt, schema });
      return schema === 'ai-tables.schema.json'
        ? { ids }
        : { sql: 'SELECT o.id, c.email FROM sales.orders o JOIN sales.customers c ON c.id = o.customer_id;', explanation: 'Joined on the customer key.' };
    }
  });
  assert.deepEqual(described.sort(), ['sales.customers', 'sales.orders']);
  assert.equal(prompts.length, 2);
  assert.ok(prompts[0].prompt.includes('SELECT bad FROM sales.orders'));
  assert.ok(prompts[0].prompt.includes('column bad does not exist'));
  assert.ok(prompts[1].prompt.includes('["customer_id","integer",0]'));
  assert.ok(prompts[1].prompt.includes('["email","text",0]'));
  assert.ok(prompts.every(entry => !entry.prompt.includes('NeverSendMe') && !entry.prompt.includes('private.example')));
  assert.equal(result.catalogCount, 500);
  assert.equal(result.tablesUsed, 2);
  assert.match(result.sql, /JOIN sales\.customers/);
});

test('large catalogs keep prompt-matching objects ahead of the size cap', () => {
  const objects = Array.from({ length: 1200 }, (_, index) => ({ schema: 'public', name: `archive_record_${index}` }));
  objects.push({ schema: 'public', name: 'z_customer_orders' });
  const catalog = compactCatalog(objects, null, 'customer orders');
  assert.ok(catalog.omitted > 0);
  assert.match(catalog.text.split('\n')[0], /z_customer_orders/);
  assert.ok(catalog.text.length <= 18000);
});

test('schema definitions omit defaults, indexes, and row data', () => {
  const definition = compactDefinitions([{ schema: 'public', name: 'users' }], [{
    columns: [{ name: 'id', type: 'int', primaryKey: true, default: 'sensitive-default' }],
    indexes: [{ name: 'secret-index' }], rows: [['sensitive-row']]
  }]);
  assert.equal(definition, '["public","users"](["id","int",1])');
});

test('Codex adapter uses stdin, structured output, and a restricted environment', async () => {
  let invocation;
  const result = await runCodex('Draft a query', 'ai-query.schema.json', {
    environment: { HOME: '/tmp/fake-home', PATH: '/usr/bin', DB_PASSWORD: 'DoNotPass' },
    spawnAgent(command, args, options) {
      invocation = { command, args, options };
      const child = new EventEmitter();
      child.stdin = new PassThrough();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      child.kill = () => {};
      let input = '';
      child.stdin.on('data', chunk => { input += chunk.toString(); });
      child.stdin.on('end', () => {
        child.stdout.end(JSON.stringify({ sql: input === 'Draft a query' ? 'SELECT 1;' : '', explanation: 'ok' }));
        setImmediate(() => child.emit('close', 0));
      });
      return child;
    }
  });
  assert.deepEqual(result, { sql: 'SELECT 1;', explanation: 'ok' });
  assert.equal(invocation.command, 'codex');
  assert.ok(invocation.args.includes('--ephemeral'));
  assert.ok(invocation.args.includes('--output-schema'));
  assert.ok(invocation.args.includes('read-only'));
  assert.equal(invocation.options.env.DB_PASSWORD, undefined);
  await assert.rejects(fs.stat(invocation.options.cwd), { code: 'ENOENT' });
});
