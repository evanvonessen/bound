import { fileURLToPath } from 'node:url';
import { uuid } from './services.mjs';

// Operator-only: an authenticated client cannot grant itself developer access.
export async function setDeveloperApproval(pool, { action, owner }) {
  if (!['approve', 'revoke'].includes(action) || typeof owner !== 'string' || !uuid.test(owner) ||
      owner !== owner.toLowerCase() || owner === '00000000-0000-0000-0000-000000000000') throw Error('Use approve or revoke with an existing account UUID');
  const result = await pool.query(`INSERT INTO bound_developer_private.approvals(owner,approved)
    SELECT id,$2 FROM auth.users WHERE id=$1 AND deleted_at IS NULL
    ON CONFLICT(owner) DO UPDATE SET approved=EXCLUDED.approved,updated_at=now()
    RETURNING owner,approved`, [owner, action === 'approve']);
  if (result.rows.length !== 1) throw Error('No active account matches');
  return result.rows[0];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [action, owner, ...extra] = process.argv.slice(2);
  if (!action || !owner || extra.length) { console.error('Usage: node developer-access.mjs approve|revoke ACCOUNT_UUID'); process.exitCode = 1; }
  else {
    const { default: pg } = await import('pg');
    const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
    try { console.log(JSON.stringify(await setDeveloperApproval(pool, { action, owner }))); }
    catch (error) { console.error(error.message); process.exitCode = 1; }
    finally { await pool.end(); }
  }
}
