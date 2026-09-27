import { WorkerClient } from './worker-client.mjs';
import { withProfileLock } from './operation-lock.mjs';

function publicResult(result) {
  if (!Array.isArray(result?.cellRefs)) return result;
  const { cellRefs, ...rest } = result;
  return {
    ...rest,
    truncatedCells: cellRefs.map(({ row, column, byteLength }) => ({ row, column, byteLength }))
  };
}

export class AgentBridge {
  constructor({ worker = new WorkerClient(), lock = withProfileLock } = {}) {
    this.worker = worker;
    this.lock = lock;
  }

  async profiles() {
    const { profiles } = await this.worker.call('profiles.list');
    return profiles.filter(profile => profile.hasStoredConnection && profile.agentAccess === true);
  }

  async #profile(reference) {
    if (typeof reference !== 'string' || !reference.trim()) throw new Error('Choose a saved connection profile.');
    const profiles = await this.profiles();
    const exact = profiles.find(profile => profile.id === reference);
    if (exact) return exact;
    const matches = profiles.filter(profile => profile.name.toLowerCase() === reference.trim().toLowerCase());
    if (matches.length === 1) return matches[0];
    if (matches.length > 1) throw new Error('More than one connection has that name. Use its profile ID.');
    throw new Error('Saved connection profile not found.');
  }

  async #withConnection(reference, action, payload = {}, signal) {
    const profile = await this.#profile(reference);
    return this.lock(profile.id, async () => {
      const opened = await this.worker.call('agent.connection.open', { profileId: profile.id });
      try {
        if (signal?.aborted) throw new Error('DB Studio operation cancelled.');
        return publicResult(await this.worker.call(action, { connectionId: opened.connectionId, ...payload }, { signal }));
      } finally {
        await this.worker.call('connection.close', { connectionId: opened.connectionId }).catch(() => {});
      }
    }, { signal });
  }

  schemas(profile, signal) { return this.#withConnection(profile, 'schemas.list', {}, signal); }
  objects(profile, schema, signal) { return this.#withConnection(profile, 'objects.list', { schema }, signal); }
  describe(profile, schema, name, signal) { return this.#withConnection(profile, 'table.describe', { schema, name }, signal); }
  rows(profile, schema, name, limit, offset, signal) {
    return this.#withConnection(profile, 'table.rows', { schema, name, limit, offset }, signal);
  }
  query(profile, sql, limit, timeoutMs, signal) {
    return this.#withConnection(profile, 'query.run', { sql, limit, timeoutMs }, signal);
  }

  close() { return this.worker.close(); }
}
