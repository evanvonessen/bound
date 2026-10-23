import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { importLegacy } from '../import-legacy.mjs';
import { createGrantCipher } from '../../dropbox-link/handler.mjs';

// Explicitly opt-in. Creates and drops only two newly named fixture databases.
const databaseURL = process.env.BOUND_IMPORT_TEST_DATABASE_URL;
test('isolated PostgreSQL import retains UUID/hash, ciphertext, exact timestamps, bigint and identity sequence', { skip: !databaseURL }, async () => {
  const { default: pg } = await import('pg');
  const suffix = randomBytes(6).toString('hex'), sourceName = 'bound_import_source_' + suffix, destinationName = 'bound_import_destination_' + suffix;
  const admin = new pg.Client({ connectionString: databaseURL });
  const types = { getTypeParser: (oid, format) => [1082, 1114, 1184].includes(oid) ? value => value : pg.types.getTypeParser(oid, format) };
  const connection = name => { const url = new URL(databaseURL); url.pathname = '/' + name; return new pg.Client({ connectionString: url.toString(), types }); };
  const source = connection(sourceName), destination = connection(destinationName), created = [];
  const owner = '11111111-1111-4111-8111-111111111111', peer = '22222222-2222-4222-8222-222222222222', room = '33333333-3333-4333-8333-333333333333';
  const key = Buffer.alloc(32, 17).toString('base64'), appKey = 'fixture-dropbox', cipher = createGrantCipher(key, appKey);
  const ciphertext = await cipher.seal(owner, 'fixture-refresh-token');
  const business = authority => `
    CREATE SCHEMA cup050_private; CREATE SCHEMA bound_social_private; CREATE SCHEMA bound_multiplayer_private;
    CREATE SCHEMA bound_dropbox_private; CREATE SCHEMA bound_moderation_private;
    CREATE TABLE cup050_private.rooms(id uuid PRIMARY KEY,owner_a uuid REFERENCES ${authority}(id),owner_b uuid REFERENCES ${authority}(id),name_a text,name_b text,active boolean,created_at timestamptz);
    CREATE TABLE bound_social_private.profiles(owner uuid PRIMARY KEY REFERENCES ${authority}(id),username text,created_at timestamptz,updated_at timestamptz);
    CREATE TABLE bound_social_private.jiggle_jobs(id uuid PRIMARY KEY,room uuid REFERENCES cup050_private.rooms(id),sender uuid REFERENCES ${authority}(id),recipient uuid REFERENCES ${authority}(id));
    CREATE TABLE bound_multiplayer_private.run_leases(owner uuid REFERENCES ${authority}(id),run_id uuid,fence bigint,checkpoint_history text,ended_at timestamptz,PRIMARY KEY(owner,run_id));
    CREATE TABLE bound_dropbox_private.links(owner uuid PRIMARY KEY REFERENCES ${authority}(id),ciphertext text,revision uuid);
    CREATE TABLE bound_moderation_private.review_audit(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,action text);`;
  try {
    await admin.connect();
    for (const name of [sourceName, destinationName]) { await admin.query('CREATE DATABASE ' + name); created.push(name); }
    await source.connect(); await destination.connect();
    await source.query(`CREATE EXTENSION pgcrypto; CREATE SCHEMA auth;
      CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,encrypted_password text,email_confirmed_at timestamptz,
        raw_user_meta_data jsonb,raw_app_meta_data jsonb,created_at timestamptz,updated_at timestamptz,
        deleted_at timestamptz,is_anonymous boolean,banned_until timestamptz,last_sign_in_at timestamptz);
      CREATE TABLE auth.mfa_factors(id uuid); CREATE TABLE auth.identities(user_id uuid,provider text);
      ${business('auth.users')}`);
    await destination.query(`CREATE TABLE public.users(id uuid PRIMARY KEY,username varchar(128) UNIQUE,email varchar(255) UNIQUE,password bytea,
      custom_id varchar(128) UNIQUE,display_name varchar(255),metadata jsonb,create_time timestamptz,update_time timestamptz,verify_time timestamptz);
      CREATE TABLE public.storage(collection varchar(128),key varchar(128),user_id uuid REFERENCES public.users(id),value jsonb,version varchar(32),read smallint,write smallint,PRIMARY KEY(collection,key,user_id));
      CREATE SCHEMA auth; CREATE VIEW auth.users AS SELECT id FROM public.users;
      INSERT INTO public.users(id,username) VALUES('00000000-0000-0000-0000-000000000000','');
      ${business('public.users')}`);
    for (const [id, email, name] of [[owner, 'owner@example.com', 'OriginalOwner'], [peer, 'peer@example.com', 'OriginalPeer']]) {
      await source.query(`INSERT INTO auth.users(id,email,encrypted_password,email_confirmed_at,raw_user_meta_data,raw_app_meta_data,created_at,updated_at,is_anonymous)
        VALUES($1,$2,crypt('fixture-password',gen_salt('bf',10)),'2026-01-01 00:00:00.123456+00',$3,'{}','2026-01-01 00:00:00.123456+00','2026-01-02 00:00:00.654321+00',false)`, [id, email, { bound_username_v1: name }]);
      await source.query("INSERT INTO bound_social_private.profiles VALUES($1,$2,'2026-01-01 00:00:00.123456+00','2026-01-02 00:00:00.654321+00')", [id, name]);
    }
    await source.query("INSERT INTO cup050_private.rooms VALUES($1,$2,$3,'OriginalOwner','OriginalPeer',true,'2026-01-01 00:00:00.123456+00')", [room, owner, peer]);
    await source.query('INSERT INTO bound_social_private.jiggle_jobs VALUES($1,$2,$3,$4)', [room, room, owner, peer]);
    await source.query("INSERT INTO bound_multiplayer_private.run_leases VALUES($1,$2,'9007199254740993',$3,NULL)", [owner, room, 'a'.repeat(64)]);
    await source.query('INSERT INTO bound_dropbox_private.links VALUES($1,$2,$3)', [owner, ciphertext, room]);
    await source.query("INSERT INTO bound_moderation_private.review_audit OVERRIDING SYSTEM VALUE VALUES(73,'dismiss')");
    const options = { source, destination, env: { DROPBOX_APP_KEY: appKey, DROPBOX_ENCRYPTION_KEY: key } };
    const plan = await importLegacy(options); assert.deepEqual(plan.blockers, []); assert.equal(plan.imported, false);
    const imported = await importLegacy({ ...options, apply: true }); assert.deepEqual(imported.blockers, []); assert.equal(imported.imported, true);
    const original = (await source.query('SELECT * FROM auth.users WHERE id=$1', [owner])).rows[0];
    const copied = (await destination.query('SELECT * FROM public.users WHERE id=$1', [owner])).rows[0];
    assert.equal(copied.password.toString(), original.encrypted_password); assert.equal(copied.custom_id, 'bound-selfhost:' + owner);
    assert.equal(copied.create_time, original.created_at); assert.equal(copied.update_time, original.updated_at);
    assert.equal((await destination.query('SELECT fence FROM bound_multiplayer_private.run_leases')).rows[0].fence, '9007199254740993');
    assert.equal((await destination.query('SELECT ciphertext FROM bound_dropbox_private.links')).rows[0].ciphertext, ciphertext);
    assert.equal((await destination.query("INSERT INTO bound_moderation_private.review_audit(action) VALUES('dismiss') RETURNING id")).rows[0].id, '74');
    assert.ok((await importLegacy({ ...options, apply: true })).blockers.some(value => value.code === 'destination_not_empty'));
    assert.equal((await source.query('SELECT count(*)::int AS n FROM auth.users')).rows[0].n, 2);
  } finally {
    await source.end().catch(() => {}); await destination.end().catch(() => {});
    for (const name of created.reverse()) await admin.query('DROP DATABASE ' + name).catch(() => {});
    await admin.end();
  }
});
