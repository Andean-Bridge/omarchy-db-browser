#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';
import { AgentBridge } from './agent-bridge.mjs';

const bridge = new AgentBridge();
const profile = z.string().min(1).describe('Saved DB Studio connection name or ID');
const schema = z.string().optional().describe('Schema or database name; omit for the connection default');
const name = z.string().min(1).describe('Table or view name');
const limit = z.number().int().min(1).max(1000).optional().describe('Maximum rows; defaults to DB Studio settings');

function result(data) {
  return { content: [{ type: 'text', text: JSON.stringify(data) }] };
}

function register(server, toolName, description, inputSchema, run) {
  server.registerTool(toolName, { description, inputSchema }, async (args, context) => {
    try { return result(await run(args, context?.mcpReq?.signal)); }
    catch (error) { return { content: [{ type: 'text', text: error.message }], isError: true }; }
  });
}

function createServer() {
  const server = new McpServer({ name: 'db-studio', version: '0.1.0' });
  register(server, 'list_connections', 'List remembered DB Studio connections enabled for AI access. If empty, tell the user to open DB Studio and enable access themselves; do not offer to change it. Names and IDs only; no credentials.', z.object({}), () => bridge.profiles());
  register(server, 'list_schemas', 'List schemas available in a saved connection.', z.object({ profile }), ({ profile }, signal) => bridge.schemas(profile, signal));
  register(server, 'list_objects', 'List tables and views in a saved connection.', z.object({ profile, schema }), ({ profile, schema }, signal) => bridge.objects(profile, schema, signal));
  register(server, 'describe_table', 'Get columns, keys and indexes for a table or view.', z.object({ profile, schema, name }), ({ profile, schema, name }, signal) => bridge.describe(profile, schema, name, signal));
  register(server, 'read_rows', 'Read a page of rows from a table or view.', z.object({ profile, schema, name, limit, offset: z.number().int().min(0).max(10000000).optional() }), ({ profile, schema, name, limit, offset }, signal) => bridge.rows(profile, schema, name, limit, offset, signal));
  register(server, 'run_query', 'Run SQL using a saved DB Studio connection. This can modify data if the database account permits it.', z.object({ profile, sql: z.string().min(1).max(200000), limit, timeoutMs: z.number().int().min(1000).max(120000).optional() }), ({ profile, sql, limit, timeoutMs }, signal) => bridge.query(profile, sql, limit, timeoutMs, signal));
  return server;
}

process.once('SIGINT', () => { void bridge.close(); });
process.once('SIGTERM', () => { void bridge.close(); });
process.stdin.once('end', () => { void bridge.close(); });
void serveStdio(createServer);
