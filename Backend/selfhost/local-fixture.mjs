import { mkdir, open, realpath } from 'node:fs/promises';
import { resolve, isAbsolute, join } from 'node:path';
import { randomUUID } from 'node:crypto';

// Captures only the existing verification-email delivery seam. It never marks
// an account confirmed, changes a proof, or falls through to external delivery.
export async function localFixtureDelivery(config) {
  if (config.BOUND_LOCAL_EMAIL_CAPTURE !== 'true') return undefined;
  if (config.BOUND_DEBUG_MODE !== 'local' || config.HOST !== '127.0.0.1' || !['127.0.0.1', 'localhost'].includes(new URL(config.PUBLIC_URL).hostname) || !isAbsolute(config.BOUND_LOCAL_FIXTURE_ROOT ?? '')) throw Error('Invalid local fixture delivery');
  const root = resolve(config.BOUND_LOCAL_FIXTURE_ROOT);
  await mkdir(root, { recursive: true, mode: 0o700 });
  if (await realpath(root) !== root) throw Error('Fixture root must not use a symlink');
  const directory = join(root, 'email'); await mkdir(directory, { recursive: true, mode: 0o700 });
  if (await realpath(directory) !== directory) throw Error('Fixture email path must not use a symlink');
  return async (url, options) => {
    if (url !== 'https://api.resend.com/emails' || options.method !== 'POST') throw Error('Fixture delivery denied');
    const message = JSON.parse(options.body);
    if (!Array.isArray(message.to) || message.to.length !== 1 || !/^[a-z0-9.+_-]+@bound-debug\.invalid$/.test(message.to[0]) || typeof message.text !== 'string') throw Error('Fixture recipient denied');
    const file = await open(join(directory, randomUUID() + '.json'), 'wx', 0o600);
    try { await file.writeFile(JSON.stringify({ to: message.to, subject: message.subject, text: message.text })); await file.sync(); }
    finally { await file.close(); }
    return new Response('{"id":"local-fixture"}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
}
