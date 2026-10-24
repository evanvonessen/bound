import { fileURLToPath } from 'node:url';
import { backupLockSQL, backupUnlockSQL } from './backups.mjs';

export function normalizeApprovalEmail(value) {
  const email = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (email.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw Error('A valid account email is required');
  return email;
}

// Operator-only local command. No HTTP admin route and no username matching.
// Revocation is committed before waiting for the owner lock: in-flight uploads
// fail their final approval check, and existing reads drain before we return.
export async function setBackupApproval(pool, { action, email: supplied, pending = false }) {
  if (!['approve', 'revoke'].includes(action)) throw Error('Use approve or revoke');
  const email = normalizeApprovalEmail(supplied);
  const client = await pool.connect();
  let owner, locked = false;
  try {
    await client.query('BEGIN');
    const account = (await client.query(`SELECT id,email_confirmed_at FROM auth.users
      WHERE lower(email)=$1 AND deleted_at IS NULL`, [email])).rows[0];
    if (action === 'approve' && (!account || !account.email_confirmed_at) && !pending) throw Error('No verified account matches; use --pending only for an intended future verified email');
    owner = account?.email_confirmed_at ? account.id : null;
    if (owner) {
      // A verified mailbox change keeps the same account UUID. Retire its old
      // mailbox grant before replacing it, so the old address cannot regain it.
      await client.query(`UPDATE bound_backups_private.approvals SET owner=NULL,approved=false,
        revision=gen_random_uuid(),updated_at=now() WHERE owner=$1 AND email<>$2`, [owner, email]);
    }
    const row = (await client.query(`INSERT INTO bound_backups_private.approvals(email,owner,approved)
      VALUES($1,$2,$3) ON CONFLICT(email) DO UPDATE SET
        owner=coalesce(EXCLUDED.owner,bound_backups_private.approvals.owner),
        approved=EXCLUDED.approved,revision=gen_random_uuid(),updated_at=now()
      RETURNING owner,approved`, [email, owner, action === 'approve'])).rows[0];
    owner = row.owner;
    await client.query('COMMIT');
    if (owner) {
      await client.query(backupLockSQL, [owner]); locked = true;
      if (action === 'revoke') await client.query(`UPDATE bound_backups_private.preferences
        SET provider='none',revision=gen_random_uuid() WHERE owner=$1 AND provider='server'`, [owner]);
    }
    return { email, owner: owner ?? null, approved: action === 'approve', pending: !owner };
  } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
  finally { if (locked) await client.query(backupUnlockSQL, [owner]).catch(() => {}); client.release(); }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [action, email, ...flags] = process.argv.slice(2);
  if (!['approve', 'revoke'].includes(action) || !email || flags.some(flag => flag !== '--pending') || flags.length > 1 || (action === 'revoke' && flags.length)) {
    console.error('Usage: node backup-access.mjs approve EMAIL [--pending] | revoke EMAIL');
    process.exitCode = 1;
  } else {
    const { default: pg } = await import('pg');
    const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
    try { console.log(JSON.stringify(await setBackupApproval(pool, { action, email, pending: flags.includes('--pending') }))); }
    catch (error) { console.error(error.message); process.exitCode = 1; }
    finally { await pool.end(); }
  }
}
