import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { normalizeProfile, normalizeType, parseConnectionString } from './connection-string.mjs';

const ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CANONICAL_PREFIX = 'omarchy-db-browser:v1:';

export function defaultProfilesPath() {
  const base = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  return path.join(base, 'omarchy', 'db-browser', 'connections.json');
}

function runSecretTool(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn('secret-tool', args, { stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [];
    let size = 0;
    const timer = setTimeout(() => child.kill('SIGKILL'), 15000);
    let settled = false;
    const fail = () => {
      if (!settled) { settled = true; clearTimeout(timer); reject(new Error('Secure keyring is unavailable.')); }
    };
    child.on('error', fail);
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > 16384) child.kill('SIGKILL');
      else stdout.push(chunk);
    });
    // Never surface secret-tool's stderr: a keyring service could echo input.
    child.stderr.resume();
    child.on('close', code => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (code === 0) resolve(Buffer.concat(stdout).toString('utf8'));
      else reject(new Error('Secure keyring is unavailable.'));
    });
    child.stdin.on('error', () => {});
    child.stdin.end(input ?? undefined);
  });
}

export const systemKeyring = {
  store: (id, secret) => runSecretTool(['store', '--label=DB Studio connection', 'app', 'omarchy-db-browser', 'id', id], secret),
  async lookup(id) {
    const secret = await runSecretTool(['lookup', 'app', 'omarchy-db-browser', 'id', id]);
    return secret.endsWith('\n') ? secret.slice(0, -1) : secret;
  },
  clear: id => runSecretTool(['clear', 'app', 'omarchy-db-browser', 'id', id])
};

function cleanMeta(item) {
  if (!item || !ID_PATTERN.test(String(item.id || ''))) throw new Error('Connection profiles file has an invalid ID.');
  if (typeof item.name !== 'string' || !item.name.trim() || item.name.length > 100) {
    throw new Error('Connection profiles file has an invalid name.');
  }
  return { id: item.id, name: item.name.trim(), type: normalizeType(item.type), hasStoredConnection: true,
    agentAccess: item.agentAccess === true };
}

function validateName(name) {
  if (typeof name !== 'string' || !name.trim() || name.length > 100 || /[\x00-\x1f]/.test(name)) {
    throw new Error('Connection name is required and must be a single line.');
  }
  return name.trim();
}

function duplicateName(sourceName, profiles) {
  const taken = new Set(profiles.map(item => item.name.toLowerCase()));
  for (let number = 1; ; number++) {
    const suffix = number === 1 ? ' copy' : ` copy ${number}`;
    const name = sourceName.slice(0, 100 - suffix.length).trimEnd() + suffix;
    if (!taken.has(name.toLowerCase())) return name;
  }
}

function definitionFromPayload(payload, type, name) {
  if (payload.connectionString !== undefined && payload.connectionString !== '') {
    if (payload.password) throw new Error('Put the password in the connection string, or use the connection fields.');
    const parsed = parseConnectionString(payload.connectionString, type);
    normalizeProfile({ ...parsed.profile, name, type });
    return payload.connectionString;
  }
  const input = payload.profile || {};
  if (!input.host && !input.database && !input.user) return null;
  const profile = normalizeProfile({ ...input, name, type });
  if (payload.password !== undefined && typeof payload.password !== 'string') throw new Error('Password must be text.');
  return CANONICAL_PREFIX + JSON.stringify({ profile, password: payload.password || '' });
}

function parseDefinition(definition, meta, passwordOverride) {
  let parsed;
  if (definition.startsWith(CANONICAL_PREFIX)) {
    try { parsed = JSON.parse(definition.slice(CANONICAL_PREFIX.length)); }
    catch { throw new Error('Saved connection is invalid.'); }
    if (!parsed || typeof parsed.password !== 'string') throw new Error('Saved connection is invalid.');
  } else {
    parsed = parseConnectionString(definition, meta.type);
  }
  const profile = normalizeProfile({ ...parsed.profile, name: meta.name, type: meta.type });
  const password = passwordOverride !== undefined ? passwordOverride : parsed.password;
  if (typeof password !== 'string' || (!password && profile.type !== 'mysql')) {
    throw new Error('Enter a password to connect.');
  }
  return { profile, password };
}

export class ProfileStore {
  constructor({ filePath = defaultProfilesPath(), keyring = systemKeyring } = {}) {
    this.filePath = filePath;
    this.keyring = keyring;
    this.sessionDefinitions = new Map();
    this.sessionProfiles = new Map();
    this.queue = Promise.resolve();
  }

  #serial(task) {
    const next = this.queue.then(task);
    this.queue = next.catch(() => {});
    return next;
  }

  async #read() {
    let text;
    try {
      const stat = await fs.lstat(this.filePath);
      if (!stat.isFile()) throw new Error('Connection profile path is not a regular file.');
      text = await fs.readFile(this.filePath, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
    let data;
    try { data = JSON.parse(text); }
    catch { throw new Error('Connection profiles file is invalid JSON.'); }
    if (data?.version !== 1 || !Array.isArray(data.profiles)) throw new Error('Connection profiles file has an unsupported format.');
    return data.profiles.map(cleanMeta);
  }

  async #write(profiles) {
    const directory = path.dirname(this.filePath);
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    await fs.chmod(directory, 0o700);
    const temp = `${this.filePath}.${randomUUID()}.tmp`;
    try {
      const metadata = profiles.map(({ id, name, type, agentAccess }) => ({ id, name, type, agentAccess: agentAccess === true }));
      await fs.writeFile(temp, JSON.stringify({ version: 1, profiles: metadata }, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
      await fs.chmod(temp, 0o600);
      await fs.rename(temp, this.filePath);
      await fs.chmod(this.filePath, 0o600);
    } finally {
      await fs.rm(temp, { force: true }).catch(() => {});
    }
  }

  async list() {
    return this.#serial(async () => {
      const profiles = new Map((await this.#read()).map(item => [item.id, item]));
      for (const [id, item] of this.sessionProfiles) profiles.set(id, item);
      return [...profiles.values()];
    });
  }

  async get(id) {
    if (!ID_PATTERN.test(String(id || ''))) throw new Error('Invalid connection profile ID.');
    return this.#serial(async () => {
      const item = this.sessionProfiles.get(id) || (await this.#read()).find(profile => profile.id === id);
      if (!item) throw new Error('Connection profile not found.');
      return item;
    });
  }

  async save(payload) {
    return this.#serial(async () => {
      if (!payload || typeof payload !== 'object') throw new Error('Invalid connection profile.');
      if (payload.agentAccess !== undefined && typeof payload.agentAccess !== 'boolean') {
        throw new Error('Invalid AI agent access setting.');
      }
      const input = payload.profile || {};
      const name = validateName(input.name);
      const type = normalizeType(input.type);
      const persisted = await this.#read();
      const existing = input.id ? (this.sessionProfiles.get(input.id) || persisted.find(item => item.id === input.id)) : null;
      if (input.id && !existing) throw new Error('Connection profile not found.');
      const id = existing?.id || randomUUID();
      const agentAccess = payload.agentAccess === undefined ? existing?.agentAccess === true : payload.agentAccess;
      let definition = definitionFromPayload(payload, type, name);
      if (!definition) {
        if (!existing || existing.type !== type) throw new Error('Enter connection details.');
        definition = this.sessionDefinitions.get(id);
        if (!definition && existing.hasStoredConnection) {
          try { definition = await this.keyring.lookup(id); }
          catch { throw new Error('Secure keyring is unavailable. Enter connection details again.'); }
        }
        if (!definition) throw new Error('Enter connection details.');
      }
      const remember = payload.savePassword === true || (payload.savePassword === undefined && existing?.hasStoredConnection);
      let credentialSaved = false;
      let warning;
      let previousDefinition;
      if (remember && existing?.hasStoredConnection) {
        try { previousDefinition = await this.keyring.lookup(id); }
        catch { throw new Error('Secure keyring is unavailable. Saved connection was left unchanged.'); }
      }
      if (remember) {
        try { await this.keyring.store(id, definition); credentialSaved = true; }
        catch {
          if (existing?.hasStoredConnection) throw new Error('Secure keyring is unavailable. Saved connection was left unchanged.');
          warning = 'Secure keyring is unavailable. This connection works only until DB Studio closes and was not saved.';
        }
      }
      const index = persisted.findIndex(item => item.id === id);
      if (credentialSaved) {
        const item = { id, name, type, hasStoredConnection: true, agentAccess };
        if (index >= 0) persisted[index] = item;
        else persisted.push(item);
        try { await this.#write(persisted); }
        catch (error) {
          try {
            if (previousDefinition) await this.keyring.store(id, previousDefinition);
            else await this.keyring.clear(id);
          } catch {}
          throw error;
        }
        this.sessionDefinitions.set(id, definition);
        this.sessionProfiles.delete(id);
        return { profile: item, credentialSaved: true };
      }
      if (index >= 0) {
        await this.#write(persisted.filter(item => item.id !== id));
        try { await this.keyring.clear(id); }
        catch {
          await this.#write(persisted).catch(() => {});
          throw new Error('Could not remove the previously saved connection from the secure keyring.');
        }
      }
      this.sessionDefinitions.set(id, definition);
      const item = { id, name, type, hasStoredConnection: false, agentAccess: false };
      this.sessionProfiles.set(id, item);
      return { profile: item, credentialSaved: false, ...(warning ? { warning } : {}) };
    });
  }

  async duplicate(id) {
    return this.#serial(async () => {
      if (!ID_PATTERN.test(String(id || ''))) throw new Error('Invalid connection profile ID.');
      const persisted = await this.#read();
      const source = this.sessionProfiles.get(id) || persisted.find(item => item.id === id);
      if (!source) throw new Error('Connection profile not found.');

      let definition;
      if (source.hasStoredConnection) {
        try { definition = await this.keyring.lookup(id); }
        catch { throw new Error('Secure keyring is unavailable. Connection was not duplicated.'); }
        if (!definition) throw new Error('Saved connection is unavailable.');
      } else {
        definition = this.sessionDefinitions.get(id);
        if (!definition) throw new Error('Enter connection details again.');
      }

      const copy = {
        id: randomUUID(),
        name: duplicateName(source.name, [...persisted, ...this.sessionProfiles.values()]),
        type: source.type,
        hasStoredConnection: source.hasStoredConnection,
        agentAccess: false
      };
      if (source.hasStoredConnection) {
        try { await this.keyring.store(copy.id, definition); }
        catch { throw new Error('Secure keyring is unavailable. Connection was not duplicated.'); }
        try { await this.#write([...persisted, copy]); }
        catch (error) {
          await this.keyring.clear(copy.id).catch(() => {});
          throw error;
        }
      } else {
        this.sessionProfiles.set(copy.id, copy);
      }
      this.sessionDefinitions.set(copy.id, definition);
      return { profile: copy, credentialSaved: source.hasStoredConnection };
    });
  }

  async delete(id) {
    return this.#serial(async () => {
      if (!ID_PATTERN.test(String(id || ''))) throw new Error('Invalid connection profile ID.');
      const persisted = await this.#read();
      const item = this.sessionProfiles.get(id) || persisted.find(profile => profile.id === id);
      if (!item) throw new Error('Connection profile not found.');
      if (persisted.some(profile => profile.id === id)) {
        await this.#write(persisted.filter(profile => profile.id !== id));
        try { await this.keyring.clear(id); }
        catch {
          await this.#write(persisted).catch(() => {});
          throw new Error('Could not remove the saved connection from the secure keyring.');
        }
      }
      this.sessionProfiles.delete(id);
      this.sessionDefinitions.delete(id);
      return { deleted: true };
    });
  }

  async credentials(id, { password, connectionString, requireAgentAccess = false } = {}) {
    const meta = await this.get(id);
    if (requireAgentAccess && (!meta.hasStoredConnection || meta.agentAccess !== true)) {
      throw new Error('Saved connection profile not found.');
    }
    if (password !== undefined && typeof password !== 'string') throw new Error('Password must be text.');
    if (connectionString !== undefined) {
      if (typeof connectionString !== 'string') throw new Error('Connection string must be text.');
      parseConnectionString(connectionString, meta.type);
      this.sessionDefinitions.set(id, connectionString);
    }
    let definition = this.sessionDefinitions.get(id);
    if (!definition && meta.hasStoredConnection) {
      try { definition = await this.keyring.lookup(id); }
      catch { throw new Error('Secure keyring is unavailable. Enter connection details again.'); }
    }
    if (!definition) throw new Error('Enter connection details again.');
    return { meta, ...parseDefinition(definition, meta, password) };
  }
}
