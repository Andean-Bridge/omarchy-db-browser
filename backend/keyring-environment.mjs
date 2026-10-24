import { promises as fs } from 'node:fs';
import path from 'node:path';

export class KeyringError extends Error {}

// Agent launchers may omit desktop variables. Recover only the current user's
// standard session bus; never replace an explicitly configured bus address.
export async function keyringEnvironment({
  env = process.env, platform = process.platform, uid = process.getuid?.(),
  stat = fs.stat, runtimeDirectory = `/run/user/${uid}`
} = {}) {
  const result = { ...env };
  if (platform !== 'linux' || env.DBUS_SESSION_BUS_ADDRESS?.trim()) return result;
  const directory = env.XDG_RUNTIME_DIR || runtimeDirectory;
  if (Number.isInteger(uid) && path.isAbsolute(directory)) {
    try {
      const runtime = await stat(directory);
      const busPath = path.join(directory, 'bus');
      const bus = await stat(busPath);
      if (runtime.isDirectory() && runtime.uid === uid && (runtime.mode & 0o077) === 0 &&
          bus.isSocket() && bus.uid === uid) {
        // D-Bus addresses escape reserved bytes in socket paths.
        const address = [...Buffer.from(busPath)].map(byte =>
          /[A-Za-z0-9_\-/\.\\]/.test(String.fromCharCode(byte))
            ? String.fromCharCode(byte) : `%${byte.toString(16).padStart(2, '0')}`).join('');
        result.DBUS_SESSION_BUS_ADDRESS = `unix:path=${address}`;
        return result;
      }
    } catch { /* Report a safe, actionable error without filesystem details. */ }
  }
  throw new KeyringError('Secure keyring cannot reach the desktop session bus. Run DB Studio in your desktop session and try again.');
}

export function keyringReadError(error) {
  return error instanceof KeyringError ? error : new Error(
    'Secure keyring is unavailable. Open DB Studio in your desktop session and try again.');
}
