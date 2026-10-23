import { createHash } from 'node:crypto';
import { readJSON, reply } from './services.mjs';

// A random device-held capability resumes an already-authorized deletion after
// session revocation or a lost reply. Store only its digest, including afterward.
export function createDeletion({ pool, auth, files }) {
  async function finish(job) {
    const client = await pool.connect();
    try {
      await client.query('SELECT pg_advisory_lock(hashtextextended($1,117))', [job.owner]);
      const current = await client.query('SELECT complete FROM cup117_private.deletion_jobs WHERE token_hash=$1', [job.token_hash]);
      if (current.rows[0]?.complete) return reply(200, { status: 'complete' });
      const exists = await client.query('SELECT 1 FROM public.users WHERE id=$1', [job.owner]);
      if (exists.rowCount) await auth.deleteAccount(job.owner);
      await files.purgeOwner(job.owner);
      await client.query('BEGIN');
      await client.query('UPDATE cup117_private.deletions SET complete=true WHERE owner=$1', [job.owner]);
      await client.query('UPDATE cup117_private.deletion_jobs SET complete=true WHERE token_hash=$1', [job.token_hash]);
      await client.query('COMMIT');
      return reply(200, { status: 'complete' });
    } catch {
      await client.query('ROLLBACK').catch(() => {});
      return reply(202, { status: 'pending' });
    } finally {
      await client.query('SELECT pg_advisory_unlock(hashtextextended($1,117))', [job.owner]).catch(() => {});
      client.release();
    }
  }
  async function handle(request) {
    if (new URL(request.url).pathname !== '/functions/v1/delete-account') return null;
    if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    let input;
    try { input = await readJSON(request, 1024); } catch { return reply(400, { error: 'invalid_request' }); }
    if (!input || typeof input !== 'object' || Array.isArray(input) ||
      !/^[0-9a-f]{64}$/.test(input.operationToken ?? '') || Object.keys(input).some(key => !['operationToken', 'confirmationEmail'].includes(key))) return reply(400, { error: 'invalid_request' });
    const tokenHash = createHash('sha256').update(input.operationToken).digest('hex');
    const existing = await pool.query('SELECT * FROM cup117_private.deletion_jobs WHERE token_hash=$1', [tokenHash]);
    if (existing.rows[0]) return finish(existing.rows[0]);
    if (!input.confirmationEmail) return reply(404, { status: 'not_started' });
    let identity;
    try { identity = await auth.authenticate(request); } catch { return reply(401, { error: 'unauthorized' }); }
    if (typeof input.confirmationEmail !== 'string' || input.confirmationEmail.trim().toLowerCase() !== identity.email?.toLowerCase()) return reply(403, { error: 'forbidden' });
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SELECT pg_advisory_xact_lock(11720260925)');
      // A request may wait behind a room/lease transaction. Recheck the exact
      // bearer after that wait, then hold its account/session rows through begin.
      let current;
      try { current = await auth.authenticate(request); }
      catch { await client.query('ROLLBACK'); return reply(401, { error: 'unauthorized' }); }
      if (current.id !== identity.id || current.session_id !== identity.session_id ||
        current.email?.toLowerCase() !== input.confirmationEmail.trim().toLowerCase()) {
        await client.query('ROLLBACK'); return reply(403, { error: 'forbidden' });
      }
      const active = await client.query(`SELECT u.id FROM auth.users u JOIN auth.sessions s ON s.user_id=u.id
        WHERE u.id=$1 AND s.id=$2 AND u.deleted_at IS NULL AND u.email_confirmed_at IS NOT NULL
          AND lower(u.email)=$3 AND s.not_after>now() FOR SHARE OF u,s`,
      [current.id, current.session_id, current.email.toLowerCase()]);
      if (!active.rows.length) { await client.query('ROLLBACK'); return reply(401, { error: 'unauthorized' }); }
      await client.query('INSERT INTO cup117_private.deletion_jobs(token_hash,owner) VALUES($1,$2)', [tokenHash, identity.id]);
      await client.query('INSERT INTO cup117_private.deletions(owner) VALUES($1) ON CONFLICT DO NOTHING', [identity.id]);
      await client.query('COMMIT');
    } catch { await client.query('ROLLBACK'); return reply(409, { status: 'pending' }); }
    finally { client.release(); }
    return finish({ owner: identity.id, token_hash: tokenHash });
  }
  return { handle };
}
