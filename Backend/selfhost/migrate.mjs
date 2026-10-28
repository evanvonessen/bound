import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

// Reuse the reviewed Bound business contracts. No Supabase, PostgREST, or
// independent identity service is installed. Each change is recorded once.
export const migrations = [
  './schema.sql', '../moderation/proposed-schema.sql', './friends.sql',
  '../social/supabase/migrations/20261015210839_bound_friend_social_v1.sql',
  '../social/supabase/migrations/20261015212112_bound_device_registration_revision_fence.sql',
  '../social/supabase/migrations/20261015212554_bound_device_registration_owner_index.sql',
  '../social/supabase/migrations/20261017201648_bound_username_friends_v2.sql',
  '../multiplayer/supabase/migrations/20261022090724_bound_run_lease_v1.sql',
  '../multiplayer/supabase/migrations/20261022093123_bound_run_lease_anchors_v1.sql',
  '../multiplayer/supabase/migrations/20261022095012_bound_run_lease_end_v1.sql',
  '../dropbox-link/contract.sql', '../nakama-session/contract.sql', './deletion.sql', './archive.sql',
  './archive-deletions.sql', './backups.sql', './game-notifications.sql',
];

export function adaptContract(sql) {
  return sql.replace(/^\s*(?:BEGIN|COMMIT);\s*$/gm, '')
    .replace(/^\s*NOTIFY pgrst,[^;]+;\s*$/gm, '')
    .replace(/REFERENCES auth\.users\(id\)/g, 'REFERENCES public.users(id)')
    .replace(/AFTER INSERT ON auth\.users/g, 'AFTER INSERT OR UPDATE OF metadata ON public.users')
    .replace("  IF NOT (coalesce(NEW.raw_user_meta_data,'{}'::jsonb) ? 'bound_username_v1') THEN",
      "  IF EXISTS(SELECT 1 FROM bound_social_private.profiles WHERE owner=NEW.id) THEN RETURN NEW; END IF;\n  IF NOT (coalesce(NEW.raw_user_meta_data,'{}'::jsonb) ? 'bound_username_v1') THEN")
    .replace(/NEW\.raw_user_meta_data/g, 'NEW.metadata')
    .replace(/NEW\.is_anonymous/g, 'false');
}

export async function migrate(pool) {
  const client = await pool.connect();
  try {
    await client.query('SELECT pg_advisory_lock(81720261022)');
    // Nakama migrations run first. Never bootstrap a substitute accounts table.
    const ready = await client.query("SELECT to_regclass('public.users') AS users,to_regclass('public.storage') AS storage");
    if (!ready.rows[0]?.users || !ready.rows[0]?.storage) throw Error('Run Nakama migrations before the Bound schema');
    await client.query('CREATE TABLE IF NOT EXISTS public.bound_schema_migrations(name text PRIMARY KEY,sha256 text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now())');
    for (const name of migrations) {
      const sql = adaptContract(await readFile(new URL(name, import.meta.url), 'utf8'));
      const hash = createHash('sha256').update(sql).digest('hex');
      const existing = await client.query('SELECT sha256 FROM public.bound_schema_migrations WHERE name=$1', [name]);
      if (existing.rows.length) {
        if (existing.rows[0].sha256 !== hash) throw Error(`Applied migration changed: ${name}`);
        continue;
      }
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO public.bound_schema_migrations(name,sha256) VALUES($1,$2)', [name, hash]);
        await client.query('COMMIT');
      } catch (error) { await client.query('ROLLBACK'); throw error; }
    }
  } finally {
    await client.query('SELECT pg_advisory_unlock(81720261022)').catch(() => {});
    client.release();
  }
}

// Runtime gateways can use a least-privilege role after an administrator ran
// migrations. Verify every expected immutable migration instead of doing DDL.
export async function verifyMigrations(pool) {
  for (const name of migrations) {
    const sql = adaptContract(await readFile(new URL(name, import.meta.url), 'utf8'));
    const hash = createHash('sha256').update(sql).digest('hex');
    const result = await pool.query('SELECT sha256 FROM public.bound_schema_migrations WHERE name=$1', [name]);
    if (result.rows.length !== 1 || result.rows[0].sha256 !== hash) throw Error('Missing or changed migration: ' + name);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { default: pg } = await import('pg');
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
  try { await migrate(pool); process.stdout.write('Bound database ready.\n'); }
  finally { await pool.end(); }
}
