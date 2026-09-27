#!/usr/bin/env node
import { createReadStream } from 'node:fs';
import { AgentBridge } from './agent-bridge.mjs';

const MAX_SQL_BYTES = 200000;

const usage = `DB Studio database CLI

Usage:
  db-studio profiles
  db-studio schemas --profile NAME_OR_ID
  db-studio objects --profile NAME_OR_ID [--schema SCHEMA]
  db-studio describe --profile NAME_OR_ID --name TABLE [--schema SCHEMA]
  db-studio rows --profile NAME_OR_ID --name TABLE [--schema SCHEMA] [--limit N] [--offset N]
  db-studio query --profile NAME_OR_ID (--sql SQL | --file PATH) [--limit N] [--timeout-ms N]

Results are JSON on stdout. Omit --limit to use DB Studio's saved default result limit.
Queries use the saved connection's database permissions.
Use --file - to read SQL from stdin. Available profiles must be remembered in the keyring and enabled for AI access in DB Studio. If none appear, the user must enable access in the DB Studio interface.`;

function parseArgs(args) {
  const [command, ...rest] = args;
  if (!command || command === '--help' || command === 'help') return { command: 'help', options: {} };
  const options = {};
  const allowed = new Set(['--profile', '--schema', '--name', '--limit', '--offset', '--sql', '--file', '--timeout-ms']);
  for (let index = 0; index < rest.length; index += 2) {
    const flag = rest[index];
    const value = rest[index + 1];
    if (!allowed.has(flag) || value === undefined || Object.hasOwn(options, flag)) {
      throw new Error(`Invalid argument: ${flag || ''}. Run db-studio --help.`);
    }
    options[flag] = value;
  }
  return { command, options };
}

async function readBoundedSql(stream) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of stream) {
    bytes += Buffer.byteLength(chunk);
    if (bytes > MAX_SQL_BYTES) {
      stream.destroy();
      throw new Error('SQL input must be under 200 KB.');
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks.map(chunk => Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))).toString('utf8');
}

async function readSql(options) {
  if (Boolean(options['--sql']) === Boolean(options['--file'])) {
    throw new Error('Provide exactly one of --sql or --file.');
  }
  if (options['--sql']) {
    if (Buffer.byteLength(options['--sql']) > MAX_SQL_BYTES) throw new Error('SQL input must be under 200 KB.');
    return options['--sql'];
  }
  return readBoundedSql(options['--file'] === '-' ? process.stdin : createReadStream(options['--file']));
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2));
  if (command === 'help') { process.stdout.write(`${usage}\n`); return; }
  const profile = options['--profile'];
  if (command !== 'profiles' && !profile) throw new Error('Provide --profile NAME_OR_ID.');
  const sql = command === 'query' ? await readSql(options) : undefined;
  const bridge = new AgentBridge();
  try {
    let result;
    switch (command) {
      case 'profiles': result = { profiles: await bridge.profiles() }; break;
      case 'schemas': result = await bridge.schemas(profile); break;
      case 'objects': result = await bridge.objects(profile, options['--schema']); break;
      case 'describe': result = await bridge.describe(profile, options['--schema'], options['--name']); break;
      case 'rows': result = await bridge.rows(profile, options['--schema'], options['--name'], options['--limit'], options['--offset']); break;
      case 'query': result = await bridge.query(profile, sql, options['--limit'], options['--timeout-ms']); break;
      default: throw new Error(`Unknown command: ${command}. Run db-studio --help.`);
    }
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } finally {
    await bridge.close();
  }
}

main().catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
