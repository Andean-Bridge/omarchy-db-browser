import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const PROFILE_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const WAIT_MS = 30000;

function defaultLockDirectory() {
  const base = process.env.XDG_RUNTIME_DIR || process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache');
  return path.join(base, 'db-studio-agent-locks');
}

function cancelled() { return new Error('DB Studio operation cancelled.'); }

async function acquire(file, signal, waitMs) {
  if (signal?.aborted) throw cancelled();
  // flock retains the lock while its child waits for stdin to close. --close
  // prevents that child (or its descendants) from retaining the lock fd.
  const child = spawn('flock', ['--exclusive', '--wait', String(waitMs / 1000), '--close', file,
    'sh', '-c', 'printf "ready\\n"; cat >/dev/null'], { stdio: ['pipe', 'pipe', 'ignore'] });
  child.stdin.on('error', () => {});
  try {
    await new Promise((resolve, reject) => {
      let settled = false;
      let output = '';
      const finish = error => {
        if (settled) return;
        settled = true;
        signal?.removeEventListener('abort', onAbort);
        if (error) reject(error);
        else resolve();
      };
      const onAbort = () => {
        child.stdin.end();
        child.kill();
        finish(cancelled());
      };
      signal?.addEventListener('abort', onAbort, { once: true });
      if (signal?.aborted) { onAbort(); return; }
      child.on('error', () => finish(new Error('DB Studio could not start the connection limiter.')));
      child.on('close', () => finish(new Error('DB Studio connection is busy. Retry shortly.')));
      child.stdout.on('data', chunk => {
        output += chunk.toString('utf8');
        if (output.includes('ready\n')) finish();
      });
    });
    return child;
  } catch (error) {
    child.stdin.end();
    child.kill();
    throw error;
  }
}

export async function withProfileLock(profileId, task, { signal, directory = defaultLockDirectory(), waitMs = WAIT_MS } = {}) {
  if (!PROFILE_ID.test(profileId)) throw new Error('Invalid connection profile ID.');
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await fs.lstat(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid()) throw new Error('DB Studio lock directory is unsafe.');
  await fs.chmod(directory, 0o700);
  const holder = await acquire(path.join(directory, `${profileId}.lock`), signal, waitMs);
  try {
    if (signal?.aborted) throw cancelled();
    return await task();
  } finally {
    holder.stdin.end();
    await new Promise(resolve => {
      if (holder.exitCode !== null) { resolve(); return; }
      const timer = setTimeout(() => { holder.kill(); resolve(); }, 2000);
      holder.once('close', () => { clearTimeout(timer); resolve(); });
    });
  }
}
