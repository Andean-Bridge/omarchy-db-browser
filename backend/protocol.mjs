import { write as fsWrite } from 'node:fs';

const pause = () => new Promise(resolve => setTimeout(resolve, 5));

// stdout is a nonblocking pipe under Quickshell. A single write may send only
// part of a response, so keep each JSON line ahead of subsequent responses.
export function createLineWriter({ fd = 1, write = fsWrite, wait = pause } = {}) {
  let tail = Promise.resolve();

  return line => {
    const bytes = Buffer.from(`${line}\n`, 'utf8');
    const sent = tail.then(async () => {
      let offset = 0;
      while (offset < bytes.length) {
        let written;
        try {
          written = await new Promise((resolve, reject) => {
            write(fd, bytes, offset, bytes.length - offset, null, (error, count) => {
              if (error) reject(error);
              else resolve(count);
            });
          });
        } catch (error) {
          if (error?.code === 'EAGAIN' || error?.code === 'EINTR') {
            await wait();
            continue;
          }
          throw error;
        }
        if (!Number.isInteger(written) || written < 0 || written > bytes.length - offset) {
          throw new Error('Invalid stdout write result.');
        }
        if (written === 0) await wait();
        else offset += written;
      }
    });
    tail = sent;
    return sent;
  };
}
