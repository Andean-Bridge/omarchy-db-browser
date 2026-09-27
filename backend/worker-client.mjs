import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline';

const workerPath = fileURLToPath(new URL('./worker.mjs', import.meta.url));

export class WorkerClient {
  constructor({ spawnWorker = () => spawn(process.execPath, [workerPath], { stdio: ['pipe', 'pipe', 'pipe'] }) } = {}) {
    this.child = spawnWorker();
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
    this.lines = readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    this.lines.on('line', line => this.#receive(line));
    // The worker deliberately keeps credentials out of normal responses. Do not
    // forward its stderr into an agent's context or the CLI's JSON output.
    this.child.stderr.resume();
    this.child.on('error', () => this.#failAll('DB Studio worker could not start.'));
    this.child.on('close', () => this.#failAll('DB Studio worker stopped.'));
  }

  #receive(line) {
    let response;
    try { response = JSON.parse(line); }
    catch { this.#failAll('DB Studio worker sent an invalid response.'); return; }
    const pending = this.pending.get(response?.id);
    if (!pending) return;
    this.pending.delete(response.id);
    if (response.ok) pending.resolve(response.data);
    else pending.reject(new Error(response.error || 'DB Studio operation failed.'));
  }

  #failAll(message) {
    this.closed = true;
    for (const pending of this.pending.values()) pending.reject(new Error(message));
    this.pending.clear();
  }

  call(action, payload = {}, { signal } = {}) {
    if (this.closed) return Promise.reject(new Error('DB Studio worker stopped.'));
    if (signal?.aborted) return Promise.reject(new Error('DB Studio operation cancelled.'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const cleanup = () => signal?.removeEventListener('abort', onAbort);
      const onAbort = () => {
        if (!this.pending.delete(id)) return;
        cleanup();
        reject(new Error('DB Studio operation cancelled.'));
        void this.call('query.cancel', { targetId: id }).catch(() => {});
      };
      this.pending.set(id, {
        resolve: value => { cleanup(); resolve(value); },
        reject: error => { cleanup(); reject(error); }
      });
      signal?.addEventListener('abort', onAbort, { once: true });
      if (signal?.aborted) { onAbort(); return; }
      this.child.stdin.write(`${JSON.stringify({ id, action, payload })}\n`, error => {
        if (error && this.pending.has(id)) {
          this.pending.delete(id);
          cleanup();
          reject(new Error('DB Studio worker could not receive the request.'));
        }
      });
    });
  }

  async close() {
    if (this.closePromise) return this.closePromise;
    if (this.child.exitCode !== null || this.child.signalCode !== null) return;
    this.closePromise = new Promise(resolve => {
      const timer = setTimeout(() => { this.child.kill(); resolve(); }, 2000);
      this.child.once('close', () => { clearTimeout(timer); resolve(); });
      this.child.stdin.end();
    });
    return this.closePromise;
  }
}
