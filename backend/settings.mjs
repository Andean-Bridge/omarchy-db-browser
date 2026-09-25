import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { boundedNumber } from './drivers.mjs';

export const DEFAULT_RESULT_LIMIT = 100;
export const MAX_RESULT_LIMIT = 1000;

export function defaultSettingsPath() {
  const base = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  return path.join(base, 'omarchy', 'db-browser', 'settings.json');
}

export function resultLimit(value, fallback = DEFAULT_RESULT_LIMIT) {
  return boundedNumber(value, fallback, 1, MAX_RESULT_LIMIT, 'Limit');
}

function requiredResultLimit(value) {
  if (typeof value !== 'number' || !Number.isInteger(value)) throw new Error('Limit must be between 1 and 1000.');
  return resultLimit(value);
}

export class SettingsStore {
  constructor({ filePath = defaultSettingsPath() } = {}) {
    this.filePath = filePath;
    this.queue = Promise.resolve();
  }

  #serial(task) {
    const next = this.queue.then(task);
    this.queue = next.catch(() => {});
    return next;
  }

  async #read() {
    let contents;
    try {
      const stat = await fs.lstat(this.filePath);
      if (!stat.isFile()) throw new Error('Settings path is not a regular file.');
      contents = await fs.readFile(this.filePath, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') return { defaultLimit: DEFAULT_RESULT_LIMIT };
      throw error;
    }
    let settings;
    try { settings = JSON.parse(contents); }
    catch { throw new Error('Settings file is invalid JSON.'); }
    if (settings?.version !== 1) throw new Error('Settings file has an unsupported format.');
    return { defaultLimit: requiredResultLimit(settings.defaultLimit) };
  }

  get() {
    return this.#serial(() => this.#read());
  }

  save({ defaultLimit } = {}) {
    return this.#serial(async () => {
      const limit = requiredResultLimit(defaultLimit);
      const directory = path.dirname(this.filePath);
      await fs.mkdir(directory, { recursive: true, mode: 0o700 });
      await fs.chmod(directory, 0o700);
      const temp = `${this.filePath}.${randomUUID()}.tmp`;
      try {
        await fs.writeFile(temp, JSON.stringify({ version: 1, defaultLimit: limit }, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
        await fs.rename(temp, this.filePath);
        await fs.chmod(this.filePath, 0o600);
      } finally {
        await fs.rm(temp, { force: true }).catch(() => {});
      }
      return { defaultLimit: limit };
    });
  }
}
