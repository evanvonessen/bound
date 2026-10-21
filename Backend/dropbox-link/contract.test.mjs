import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const { PGlite } = await import(process.env.PGLITE_MODULE ?? '@electric-sql/pglite');
const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const session = '33333333-3333-4333-8333-333333333333';
const sessionB = '44444444-4444-4444-8444-444444444444';
test('database enforces service-only grants, live sessions, revision fences and deletion cleanup', async () => {
  const db = new PGlite();
  try {
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
      CREATE SCHEMA auth; CREATE SCHEMA cup117_private;
      CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      CREATE TABLE auth.users(id uuid PRIMARY KEY,deleted_at timestamptz,is_anonymous boolean DEFAULT false,email_confirmed_at timestamptz DEFAULT now());
      CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,not_after timestamptz);
      CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY);
      INSERT INTO auth.users(id) VALUES ('${owner}'),('${other}');
      INSERT INTO auth.sessions(id,user_id) VALUES ('${session}','${owner}'),('${sessionB}','${other}');`);
    await db.exec(await readFile(new URL('./contract.sql',import.meta.url),'utf8'));
    for (const role of ['anon','authenticated']) {
      await db.exec(`SET ROLE ${role}`);
      await assert.rejects(db.query('SELECT public.bound_dropbox_grant($1,$2::jsonb)',['snapshot',JSON.stringify({owner,session})]));
      await assert.rejects(db.query('SELECT * FROM bound_dropbox_private.links'));
      await db.exec('RESET ROLE');
    }
    const call = async (action, payload = {}) => {
      const result = await db.query('SELECT public.bound_dropbox_grant($1,$2::jsonb) AS result',
        [action,JSON.stringify({owner,session,...payload})]);
      return result.rows[0].result;
    };
    await db.exec(`SET request.jwt.claims = '{"role":"service_role"}'; SET ROLE service_role`);
    const initial = await call('snapshot'); assert.equal(initial.ciphertext,null);
    assert.equal((await call('snapshot',{owner:other})).error,'unauthorized','session cannot select a different owner');
    assert.equal((await call('store',{revision:initial.revision,ciphertext:'encrypted-fixture'.repeat(3)})).ok,true);
    const stored = await call('snapshot'); assert.notEqual(stored.revision,initial.revision);
    assert.equal((await call('validate',{revision:initial.revision})).error,'connection_changed');
    const removed = await call('unlink',{revision:stored.revision}); assert.equal(removed.ok,true);
    assert.equal((await call('store',{revision:stored.revision,ciphertext:'stale-encrypted-token'.repeat(3)})).error,'connection_changed','unlink fences in-flight link/store');
    assert.equal((await call('validate',{revision:stored.revision})).error,'connection_changed','unlink fences token issuance');
    assert.equal((await call('snapshot')).ciphertext,null);
    await db.exec('RESET ROLE');
    await db.query('DELETE FROM auth.sessions WHERE id=$1',[session]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('snapshot')).error,'unauthorized','revoked sessions fail even with otherwise valid JWT');
    await db.exec('RESET ROLE');
    await db.query('INSERT INTO auth.sessions(id,user_id,not_after) VALUES ($1,$2,now()-interval \'1 minute\')',[session,owner]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('snapshot')).error,'unauthorized','expired session is denied');
    await db.exec('RESET ROLE');
    await db.query('UPDATE auth.sessions SET not_after=NULL WHERE id=$1',[session]);
    await db.query('INSERT INTO cup117_private.deletions(owner) VALUES ($1)',[owner]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('snapshot')).error,'unauthorized','account deletion marker blocks reads and writes');
    await db.exec('RESET ROLE');
    await db.query('DELETE FROM cup117_private.deletions WHERE owner=$1',[owner]);
    await db.query('UPDATE bound_dropbox_private.links SET requests=120 WHERE owner=$1',[owner]);
    await db.exec('SET ROLE service_role');
    assert.equal((await call('snapshot')).error,'rate_limited');
    await db.exec('RESET ROLE');
    await db.query('DELETE FROM auth.users WHERE id=$1',[owner]);
    assert.equal((await db.query('SELECT * FROM bound_dropbox_private.links WHERE owner=$1',[owner])).rows.length,0,'Auth deletion removes encrypted credentials');
  } finally { await db.close(); }
});
