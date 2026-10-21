import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const { PGlite } = await import(process.env.PGLITE_MODULE ?? '@electric-sql/pglite');
const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const session = '33333333-3333-4333-8333-333333333333';
const anotherSession = '44444444-4444-4444-8444-444444444444';
const staleOperation = '55555555-5555-4555-8555-555555555555';
const email = 'before@example.invalid';
const newEmail = 'after@example.invalid';

test('email contract enforces service-only access, account leases, rate limits, live session and deletion fences', async () => {
  const db = new PGlite();
  try {
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
      CREATE SCHEMA auth; CREATE SCHEMA cup117_private;
      CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,deleted_at timestamptz,is_anonymous boolean DEFAULT false,email_confirmed_at timestamptz DEFAULT now());
      CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,not_after timestamptz);
      CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY);
      INSERT INTO auth.users(id,email) VALUES ('${owner}','${email}'),('${other}','other@example.invalid');
      INSERT INTO auth.sessions(id,user_id) VALUES ('${session}','${owner}'),('${anotherSession}','${owner}');`);
    await db.exec(await readFile(new URL('./contract.sql', import.meta.url), 'utf8'));
    const call = async (action, extra = {}) => (await db.query('SELECT public.bound_account_email($1,$2::jsonb) AS result',
      [action, JSON.stringify({ owner, session, email, newEmail, ...extra })])).rows[0].result;
    for (const role of ['anon', 'authenticated']) {
      await db.exec(`SET ROLE ${role}`);
      await assert.rejects(call('begin'));
      await assert.rejects(db.query('SELECT * FROM bound_account_email_private.operations'));
      await db.exec('RESET ROLE');
    }
    await db.exec(`SET request.jwt.claims='{"role":"service_role"}'; SET ROLE service_role`);
    await assert.rejects(db.query('SELECT * FROM bound_account_email_private.operations'));
    assert.equal((await call('begin', { owner: other })).error, 'unauthorized', 'session must belong to exact owner');
    assert.equal((await call('begin', { email: 'wrong@example.invalid' })).error, 'account_changed');
    const initial = await call('begin'); assert.equal(initial.ok, true); assert.ok(initial.operation);
    assert.equal((await call('begin')).error, 'change_in_progress');
    assert.equal((await call('begin', { session: anotherSession })).error, 'change_in_progress', 'lease spans devices');
    assert.equal((await call('validate', { operation: initial.operation })).ok, true);
    for (const extra of [{ operation: staleOperation }, { operation: initial.operation, session: anotherSession },
      { operation: initial.operation, newEmail: 'changed@example.invalid' }]) {
      assert.equal((await call('validate', extra)).error, 'account_changed');
    }
    await call('release', { operation: staleOperation });
    assert.equal((await call('begin')).error, 'change_in_progress', 'stale release cannot clear active operation');
    await call('release', { operation: initial.operation });
    const second = await call('begin'); assert.notEqual(second.operation, initial.operation);
    assert.equal((await call('validate', { operation: initial.operation })).error, 'account_changed', 'retry cannot reuse old operation');
    await db.exec('RESET ROLE');
    await db.query('UPDATE bound_account_email_private.operations SET expires_at=now()-interval \'1 second\' WHERE owner=$1', [owner]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('validate', { operation: second.operation })).error, 'account_changed', 'expired lease cannot authorize writes');
    const renewed = await call('begin'); assert.equal(renewed.ok, true);
    await db.exec('RESET ROLE');
    await db.query('DELETE FROM auth.sessions WHERE id=$1', [session]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('validate', { operation: renewed.operation })).error, 'unauthorized', 'revoked original session blocks final update');
    await db.exec('RESET ROLE');
    await db.query('INSERT INTO auth.sessions(id,user_id,not_after) VALUES($1,$2,now()-interval \'1 minute\')', [session, owner]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('validate', { operation: renewed.operation })).error, 'unauthorized', 'expired original session denied');
    await db.exec('RESET ROLE');
    await db.query('UPDATE auth.sessions SET not_after=NULL WHERE id=$1', [session]);
    await db.query('INSERT INTO cup117_private.deletions(owner) VALUES($1)', [owner]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('validate', { operation: renewed.operation })).error, 'unauthorized', 'deletion marker blocks final update');
    await db.exec('RESET ROLE');
    await db.query('DELETE FROM cup117_private.deletions WHERE owner=$1', [owner]);
    await db.query('UPDATE auth.users SET email=$2 WHERE id=$1', [owner, 'changed@example.invalid']);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('validate', { operation: renewed.operation })).error, 'account_changed', 'actual Auth email checked again');
    await db.exec('RESET ROLE');
    await db.query('UPDATE auth.users SET email=$2 WHERE id=$1', [owner, email]);
    await db.exec('SET ROLE service_role');
    await call('release', { operation: renewed.operation });
    await db.exec('RESET ROLE');
    const afterRelease = (await db.query('SELECT * FROM bound_account_email_private.operations WHERE owner=$1', [owner])).rows[0];
    assert.equal(afterRelease.old_email, null); assert.equal(afterRelease.new_email, null); assert.equal(afterRelease.session_id, null);
    assert.equal(afterRelease.attempts, 3, 'release preserves password-attempt rate accounting');
    await db.query('UPDATE bound_account_email_private.operations SET attempts=5 WHERE owner=$1', [owner]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('begin')).error, 'rate_limited');
    await db.exec('RESET ROLE');
    await db.query('UPDATE bound_account_email_private.operations SET window_start=now()-interval \'16 minutes\' WHERE owner=$1', [owner]);
    await db.exec('SET ROLE service_role');
    const reset = await call('begin'); assert.equal(reset.ok, true);
    await call('release', { operation: reset.operation });
    const sameEmail = await call('begin', { newEmail: email });
    assert.equal((await call('validate', { operation: sameEmail.operation, newEmail: email })).ok, true, 'same-email reconciliation is authorized, not assumed');
    await db.exec('RESET ROLE');
    await db.query('DELETE FROM auth.users WHERE id=$1', [owner]);
    assert.equal((await db.query('SELECT * FROM bound_account_email_private.operations WHERE owner=$1', [owner])).rows.length, 0);
    assert.equal((await db.query("SELECT count(*)::int AS count FROM pg_trigger WHERE tgrelid='auth.users'::regclass AND NOT tgisinternal")).rows[0].count, 0, 'no Auth trigger added');
  } finally { await db.close(); }
});
