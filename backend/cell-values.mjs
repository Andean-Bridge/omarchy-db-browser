import { randomUUID } from 'node:crypto';

export const MAX_CELL_VALUE_BYTES = 5 * 1024 * 1024;
export const MAX_CACHED_VALUE_BYTES = 20 * 1024 * 1024;
export const CELL_VALUE_TTL_MS = 5 * 60 * 1000;

// Full cell values live only in this worker's memory. A batch keeps values
// private until its table/query response succeeds, and can discard them after
// cancellation or failure. The byte budget includes uncommitted batches.
export class CellValueStore {
  constructor({
    maxEntryBytes = MAX_CELL_VALUE_BYTES,
    maxTotalBytes = MAX_CACHED_VALUE_BYTES,
    ttlMs = CELL_VALUE_TTL_MS,
    now = Date.now
  } = {}) {
    this.maxEntryBytes = maxEntryBytes;
    this.maxTotalBytes = maxTotalBytes;
    this.ttlMs = ttlMs;
    this.now = now;
    this.entries = new Map();
    this.batches = new Set();
    this.totalBytes = 0;
    this.expiryTimer = setInterval(() => this.prune(), Math.min(ttlMs, 60_000));
    this.expiryTimer.unref?.();
  }

  begin(connectionId) {
    const batch = {
      connectionId,
      handles: new Set(),
      closed: false,
      capture: (text, byteLength = Buffer.byteLength(text, 'utf8')) => this.capture(batch, text, byteLength),
      commit: () => this.commit(batch),
      discard: () => this.discard(batch)
    };
    this.batches.add(batch);
    return batch;
  }

  remove(handle) {
    const entry = this.entries.get(handle);
    if (!entry) return;
    this.entries.delete(handle);
    this.totalBytes -= entry.byteLength;
    entry.batch?.handles.delete(handle);
    entry.buffer.fill(0);
  }

  prune() {
    const now = this.now();
    for (const [handle, entry] of this.entries) {
      if (entry.expiresAt <= now) this.remove(handle);
    }
  }

  capture(batch, text, byteLength) {
    if (batch.closed || typeof text !== 'string' || !Number.isSafeInteger(byteLength) || byteLength < 0 ||
        byteLength > this.maxEntryBytes || byteLength > this.maxTotalBytes) return null;
    this.prune();
    // Evict oldest completed values first. Values in another in-flight batch
    // cannot be evicted because its response may still contain their handles.
    for (const [handle, entry] of this.entries) {
      if (this.totalBytes + byteLength <= this.maxTotalBytes) break;
      if (!entry.batch) this.remove(handle);
    }
    if (this.totalBytes + byteLength > this.maxTotalBytes) return null;
    const buffer = Buffer.from(text, 'utf8');
    const actualBytes = buffer.length;
    if (actualBytes > this.maxEntryBytes || this.totalBytes + actualBytes > this.maxTotalBytes) return null;
    const handle = randomUUID();
    this.entries.set(handle, {
      connectionId: batch.connectionId, buffer, byteLength: actualBytes,
      expiresAt: this.now() + this.ttlMs, batch
    });
    batch.handles.add(handle);
    this.totalBytes += actualBytes;
    return handle;
  }

  commit(batch) {
    if (batch.closed) return false;
    for (const handle of batch.handles) {
      const entry = this.entries.get(handle);
      if (entry) entry.batch = null;
    }
    batch.handles.clear();
    batch.closed = true;
    this.batches.delete(batch);
    return true;
  }

  discard(batch) {
    if (batch.closed) return;
    for (const handle of batch.handles) this.remove(handle);
    batch.closed = true;
    this.batches.delete(batch);
  }

  get(connectionId, handle) {
    if (typeof handle !== 'string' || !/^[0-9a-f-]{36}$/.test(handle)) return null;
    this.prune();
    const entry = this.entries.get(handle);
    if (!entry || entry.batch || entry.connectionId !== connectionId) return null;
    return { text: entry.buffer.toString('utf8'), byteLength: entry.byteLength };
  }

  clearConnection(connectionId) {
    for (const batch of [...this.batches]) {
      if (batch.connectionId === connectionId) this.discard(batch);
    }
    for (const [handle, entry] of this.entries) {
      if (entry.connectionId === connectionId) this.remove(handle);
    }
  }

  clear() {
    for (const batch of [...this.batches]) this.discard(batch);
    for (const handle of this.entries.keys()) this.remove(handle);
  }

  dispose() {
    clearInterval(this.expiryTimer);
    this.clear();
  }
}
