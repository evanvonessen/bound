import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { setDeveloperApproval } from '../developer-access.mjs';
import { createROMUpdates } from '../rom-updates.mjs';
import { migrations, adaptContract } from '../migrate.mjs';

const databaseURL = process.env.BOUND_ROM_TEST_DATABASE_URL;
test('PostgreSQL one-time existing cohort, deny future accounts, revocation, rollback, roles and deletion', { skip: !databaseURL }, async () => {
  const { default: pg } = await import('pg');
  const name = 'bound_rom_test_' + randomBytes(6).toString('hex');
  const admin = new pg.Client({ connectionString: databaseURL });
  const url = new URL(databaseURL); url.pathname = '/' + name;
  const pool = new pg.Pool({ connectionString: url.toString(), max: 4 });
  const owner = '11111111-1111-4111-8111-111111111111', future = '22222222-2222-4222-8222-222222222222';
  const session = '33333333-3333-4333-8333-333333333333', system = '00000000-0000-0000-0000-000000000000';
  let created = false, currentOwner = owner;
  try {
    await admin.connect();
    for (const role of ['anon', 'authenticated', 'service_role']) {
      if (!(await admin.query('SELECT 1 FROM pg_roles WHERE rolname=$1', [role])).rowCount) await admin.query('CREATE ROLE ' + role + ' NOLOGIN');
    }
    await admin.query('CREATE DATABASE ' + name); created = true;
    await pool.query(`CREATE TABLE public.users(id uuid PRIMARY KEY,deleted_at timestamptz);
      CREATE SCHEMA auth; CREATE VIEW auth.users AS SELECT * FROM public.users;
      CREATE TABLE auth.sessions(id uuid,user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,not_after timestamptz);
      CREATE SCHEMA cup117_private; CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY);
      CREATE TABLE bound_schema_migrations(name text PRIMARY KEY,sha256 text NOT NULL);
      INSERT INTO public.users VALUES('${owner}',NULL),('${system}',NULL);
      INSERT INTO auth.sessions VALUES('${session}','${owner}',now()+interval '1 hour');`);
    const migration = './rom-updates.sql';
    assert.ok(migrations.includes(migration));
    const sql = adaptContract(await readFile(new URL('../rom-updates.sql', import.meta.url), 'utf8'));
    const digest = createHash('sha256').update(sql).digest('hex');
    const client = await pool.connect();
    try {
      // Prove DDL plus cohort roll back if migration cannot commit its receipt.
      await client.query('BEGIN'); await client.query(sql); await client.query('ROLLBACK');
      assert.equal((await client.query("SELECT to_regclass('bound_developer_private.approvals') AS relation")).rows[0].relation, null);
      await client.query('BEGIN'); await client.query(sql);
      await client.query('INSERT INTO bound_schema_migrations VALUES($1,$2)', [migration, digest]); await client.query('COMMIT');
      await client.query('INSERT INTO public.users VALUES($1,NULL)', [future]);
      await client.query("INSERT INTO auth.sessions VALUES($1,$2,now()+interval '1 hour')", [session, future]);
      // The immutable migration ledger skips the one-time snapshot on restart.
      assert.equal((await client.query('SELECT sha256 FROM bound_schema_migrations WHERE name=$1', [migration])).rows[0].sha256, digest);
      const service = createROMUpdates({ pool, authenticate: async () => ({ ownerID: currentOwner, sessionID: session }), config: {} });
      const status = async () => (await service.handle(new Request('https://bound.example/rom-updates/access'))).json();
      assert.deepEqual(await status(), { developerApproved: true });
      assert.equal((await client.query('SELECT owner FROM bound_developer_private.approvals WHERE owner=$1', [system])).rowCount, 0);
      currentOwner = future;
      assert.deepEqual(await status(), { developerApproved: false });
      await client.query('INSERT INTO bound_developer_private.approvals(owner) VALUES($1)', [future]);
      assert.deepEqual(await status(), { developerApproved: false }, 'table default must also deny');
      await setDeveloperApproval(pool, { action: 'approve', owner: future });
      assert.deepEqual(await status(), { developerApproved: true });
      await setDeveloperApproval(pool, { action: 'revoke', owner: future });
      assert.deepEqual(await status(), { developerApproved: false });
      await assert.rejects(setDeveloperApproval(pool, { action: 'approve', owner: system }));
      await client.query('SET ROLE authenticated');
      await assert.rejects(client.query('SELECT * FROM bound_developer_private.approvals'), { code: '42501' });
      await assert.rejects(client.query('UPDATE bound_developer_private.approvals SET approved=true'), { code: '42501' });
      await client.query('RESET ROLE');
      await client.query('DELETE FROM public.users WHERE id=$1', [future]);
      assert.equal((await client.query('SELECT * FROM bound_developer_private.approvals WHERE owner=$1', [future])).rowCount, 0);
      await client.query('INSERT INTO public.users VALUES($1,NULL)', [future]);
      await client.query("INSERT INTO auth.sessions VALUES($1,$2,now()+interval '1 hour')", [session, future]);
      assert.deepEqual(await status(), { developerApproved: false }, 'recreated UUID cannot inherit deleted grant');
    } finally { client.release(); }
  } finally {
    await pool.end();
    if (created) await admin.query('DROP DATABASE ' + name);
    await admin.end();
  }
});
