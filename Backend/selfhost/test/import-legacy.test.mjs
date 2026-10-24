import test from 'node:test';
import assert from 'node:assert/strict';
import { importLegacy, projectUser, compatibleColumns } from '../import-legacy.mjs';

const id = '11111111-1111-4111-8111-111111111111';
const hash = '$2a$10$' + 'a'.repeat(53);
const account = () => ({ id, email: 'fixture@example.com', encrypted_password: hash,
  raw_user_meta_data: { bound_username_v1: 'Original', bound_email_confirmed_at: 'forged', bound_deleted_at: 'forged' },
  raw_app_meta_data: { provider: 'email' }, email_confirmed_at: '2026-01-01T00:00:00.123456Z',
  created_at: '2026-01-01T00:00:00.123456Z', updated_at: '2026-01-02T00:00:00.123456Z',
  is_anonymous: false, deleted_at: null, banned_until: null, last_sign_in_at: null });
const field = (name, type = 'text') => ({ name, type, nullable: 'YES', default: null, identity: 'NO', generated: 'NEVER' });
const dropboxFields = [field('owner', 'uuid'), field('revision', 'uuid'), field('ciphertext'),
  field('window_start', 'timestamptz'), field('requests', 'int4')];
const dropboxRow = { owner: id, revision: '22222222-2222-4222-8222-222222222222',
  ciphertext: 'original-encrypted-grant', window_start: '2026-01-01T00:00:00.123456Z', requests: 17 };
const legacyTable = 'cup041_v3_private.values';
const legacyFields = [['owner', 'uuid'], ['game', 'uuid'], ['operation', 'uuid'], ['generation', 'int8'],
  ['slot', 'int4'], ['metadata', 'jsonb'], ['position', 'int8']].map(([name, type]) =>
  ({ ...field(name, type), type_schema: 'pg_catalog', sql_type: type, nullable: name === 'slot' ? 'YES' : 'NO' }));
const legacyRow = { owner: id, source_key: JSON.stringify([id, id, id]), source_row: JSON.stringify({
  owner: id, game: id, operation: id, generation: '9007199254740993', slot: null, metadata: 'null', position: '9007199254740994' }) };

function fixture({ factors = 0, destinationAccounts = 0, failInsert = false, dropbox = false,
  legacy = false, authExport = false, missingWebauthnExport = false } = {}) {
  const logs = { source: [], destination: [], dropboxRows: [], legacyRows: [], legacyCatalog: [] }, state = { inserted: 0, fetches: 0, cursor: '' };
  const source = { async query(sql, parameters) {
    logs.source.push(sql);
    assert.ok(/^(BEGIN .*READ ONLY|SET LOCAL|SHOW |SELECT |DECLARE |FETCH |CLOSE |ROLLBACK)/.test(sql), 'source never gets writes');
    if (sql.startsWith('SHOW')) return { rows: [{ transaction_read_only: 'on' }] };
    if (sql.includes('FROM pg_class')) return { rows: [
      { schema: 'auth', name: 'users', kind: 'r' }, { schema: 'auth', name: 'mfa_factors', kind: 'r' },
      { schema: 'auth', name: 'identities', kind: 'r' },
      ...(authExport ? [{ schema: 'auth', name: 'webauthn_credentials', kind: 'r' },
        ...['users', 'identities', 'mfa_factors', ...(missingWebauthnExport ? [] : ['webauthn_credentials'])]
          .map(name => ({ schema: 'bound_migration_export', name, kind: 'v' }))] : []),
      ...(legacy ? [{ schema: 'cup041_v3_private', name: 'values', kind: 'r' }] : []),
      ...(dropbox ? [{ schema: 'bound_dropbox_private', name: 'links', kind: 'r' }] : [])] };
    if (sql.includes('FROM information_schema.columns')) return { rows: parameters[0] === 'bound_dropbox_private'
      ? dropboxFields : parameters[0] === 'cup041_v3_private' ? legacyFields : Object.keys(account()).map(name => field(name)) };
    if (sql.includes('FROM pg_index')) return { rows: ['owner', 'game', 'operation'].map(name => ({ name })) };
    if (sql.startsWith('SELECT count')) {
      if (sql.includes('mfa_factors') || sql.includes('webauthn_credentials')) return { rows: [{ count: String(factors) }] };
      if (sql.includes('"links"')) return { rows: [{ count: '1' }] };
      if (sql.includes(' WHERE ') || sql.includes(' duplicates')) return { rows: [{ count: '0' }] };
      return { rows: [{ count: '1' }] };
    }
    if (sql.startsWith('DECLARE')) { state.cursor = sql; state.fetches = 0; }
    if (sql.startsWith('FETCH')) return { rows: state.fetches++ ? [] : [state.cursor.includes('"links"')
      ? { ...dropboxRow, ciphertext: state.cursor.includes('NULL::text AS "ciphertext"') ? null : dropboxRow.ciphertext }
      : state.cursor.includes('"values"') ? legacyRow
      : account()] };
    return { rows: [] };
  } };
  const destination = { async query(sql, parameters) {
    logs.destination.push(sql);
    if (sql.includes('FROM pg_class')) return { rows: [
      { schema: 'auth', name: 'users', kind: 'v' }, { schema: 'public', name: 'users', kind: 'r' },
      { schema: 'public', name: 'storage', kind: 'r' },
      ...(legacy ? ['catalog', 'records', 'objects'].map(name => ({ schema: 'bound_archive_private', name, kind: 'r' })) : []),
      ...(dropbox ? [{ schema: 'bound_dropbox_private', name: 'links', kind: 'r' }] : [])] };
    if (sql.includes('FROM information_schema.columns')) return { rows: parameters[0] === 'bound_dropbox_private'
      ? dropboxFields : [field('id', 'uuid'), field('password', 'bytea'), field('metadata', 'jsonb'), field('custom_id', 'varchar')] };
    if (sql.startsWith('SELECT count')) return { rows: [{ count: String(sql.includes('"users"') ? destinationAccounts + state.inserted
      : sql.includes('"links"') ? logs.dropboxRows.length : sql.includes('bound_archive_private.records') ? logs.legacyRows.length : 0) }] };
    if (sql.startsWith('INSERT INTO "bound_dropbox_private"."links"')) logs.dropboxRows.push(parameters);
    if (sql.startsWith('INSERT INTO bound_archive_private.records')) logs.legacyRows.push(parameters);
    if (sql.startsWith('INSERT INTO bound_archive_private.catalog')) logs.legacyCatalog.push(parameters);
    if (sql.startsWith('INSERT INTO public.users')) {
      if (failInsert) throw Error('sensitive upstream row detail must not escape CLI');
      assert.equal(parameters[0], id); assert.equal(parameters[3].toString(), hash); state.inserted++;
    }
    return { rows: [] };
  } };
  return { source, destination, logs };
}

test('projects native identity/hash unchanged and keeps user-editable metadata out of authority flags', () => {
  const value = projectUser(account(), 'CurrentProfile');
  assert.equal(value.id, id); assert.equal(value.password.toString(), hash);
  assert.equal(value.customID, 'bound-selfhost:' + id);
  assert.equal(value.metadata.bound_username_v1, 'CurrentProfile');
  assert.equal(value.metadata.bound_email_confirmed_at, account().email_confirmed_at);
  assert.equal(value.metadata.bound_deleted_at, undefined);
  assert.equal(value.legacy.user_metadata.bound_deleted_at, 'forged');
  assert.throws(() => projectUser({ ...account(), encrypted_password: '$argon2id$unsupported' }));
  assert.throws(() => projectUser({ ...account(), is_anonymous: true }));
});

test('legacy archive retains original keys, exact bigint text and SQL-null versus JSON-null values', async () => {
  const f = fixture({ legacy: true });
  const result = await importLegacy({ ...f, apply: true });
  assert.equal(result.imported, true); assert.deepEqual(result.blockers, []);
  assert.equal(result.archive.rows, 1);
  assert.deepEqual(f.logs.legacyRows, [[legacyTable, legacyRow.source_key, id, legacyRow.source_row]]);
  assert.deepEqual(JSON.parse(f.logs.legacyCatalog[0][1]), legacyFields);
  assert.deepEqual(JSON.parse(f.logs.legacyCatalog[0][2]), ['owner', 'game', 'operation']);
});

test('explicit auth export views include every discovered WebAuthn table or block import', async () => {
  const options = { env: { SOURCE_AUTH_SCHEMA: 'bound_migration_export' }, apply: true };
  const missing = fixture({ authExport: true, missingWebauthnExport: true });
  const blocked = await importLegacy({ ...missing, ...options });
  assert.ok(blocked.blockers.some(blocker => blocker.code === 'source_auth_export_incomplete'));
  assert.equal(blocked.imported, false);
  assert.equal(missing.logs.destination.some(sql => sql.startsWith('INSERT')), false);
  const complete = fixture({ authExport: true });
  assert.equal((await importLegacy({ ...complete, ...options })).imported, true);
  assert.ok(complete.logs.source.some(sql => sql.startsWith('DECLARE') && sql.includes('"bound_migration_export"."users"')));
  assert.equal(complete.logs.source.some(sql => /FROM "auth"\./.test(sql)), false);
});

test('existing destination deletion tombstones block import before any account is inserted', async () => {
  const f = fixture(), original = f.destination.query;
  f.destination.query = async function(sql, parameters) {
    const result = await original(sql, parameters);
    if (sql.includes('FROM pg_class')) result.rows.push({ schema: 'cup117_private', name: 'deletions', kind: 'r' });
    if (sql.startsWith('SELECT count') && sql.includes('"cup117_private"."deletions"')) return { rows: [{ count: '9' }] };
    return result;
  };
  const result = await importLegacy({ ...f, apply: true });
  assert.ok(result.blockers.some(blocker => blocker.code === 'destination_not_empty' && blocker.table === 'cup117_private.deletions'));
  assert.equal(result.imported, false); assert.equal(f.logs.destination.some(sql => sql.startsWith('INSERT')), false);
});

test('rejects schema changes that would drop columns or require fabricated data', () => {
  assert.equal(compatibleColumns([field('owner', 'uuid')], [field('owner', 'uuid')]), true);
  assert.equal(compatibleColumns([field('owner', 'uuid'), field('history')], [field('owner', 'uuid')]), false);
  assert.equal(compatibleColumns([field('owner', 'uuid')], [field('owner', 'uuid'), { ...field('required'), nullable: 'NO' }]), false);
});

test('default check is read-only on both sides and does not copy credential rows', async () => {
  const f = fixture(); const result = await importLegacy(f);
  assert.equal(result.imported, false); assert.deepEqual(result.blockers, []);
  assert.equal(result.source.accounts, 1);
  assert.ok(f.logs.source[0].endsWith('READ ONLY'));
  assert.ok(f.logs.destination[0].endsWith('READ ONLY'));
  assert.equal(f.logs.source.some(sql => sql.startsWith('DECLARE')), false);
  assert.equal(f.logs.destination.some(sql => /^(INSERT|UPDATE|COMMIT)/.test(sql)), false);
});

test('MFA and conflicting destination block apply before any account is inserted', async () => {
  for (const options of [{ factors: 1 }, { destinationAccounts: 1 }]) {
    const f = fixture(options), result = await importLegacy({ ...f, apply: true });
    assert.ok(result.blockers.length); assert.equal(result.imported, false);
    assert.equal(f.logs.destination.some(sql => /^(INSERT|UPDATE|COMMIT)/.test(sql)), false);
    assert.equal(f.logs.destination.at(-1), 'ROLLBACK');
  }
});

test('apply preserves native UUID/password then commits destination only; failure rolls back', async () => {
  const f = fixture(), result = await importLegacy({ ...f, apply: true });
  assert.equal(result.imported, true);
  assert.equal(f.logs.destination.at(-1), 'COMMIT'); assert.equal(f.logs.source.at(-1), 'ROLLBACK');
  const failed = fixture({ failInsert: true });
  await assert.rejects(importLegacy({ ...failed, apply: true }));
  assert.equal(failed.logs.destination.at(-1), 'ROLLBACK'); assert.equal(failed.logs.source.at(-1), 'ROLLBACK');
});

test('explicit Dropbox reset imports disconnected rows without old keys and leaves source grants untouched', async () => {
  const preserved = fixture({ dropbox: true });
  const blocked = await importLegacy({ ...preserved, apply: true });
  assert.equal(blocked.dropbox_links, 'preserve');
  assert.ok(blocked.blockers.some(value => value.code === 'original_dropbox_keys_required'));
  assert.equal(preserved.logs.dropboxRows.length, 0);

  const f = fixture({ dropbox: true });
  const result = await importLegacy({ ...f, apply: true, resetDropboxLinks: true });
  assert.deepEqual(result.blockers, []); assert.equal(result.imported, true);
  assert.equal(result.dropbox_links, 'reset'); assert.equal(result.source.dropbox_encrypted_grants, 1);
  assert.equal(f.logs.dropboxRows.length, 1);
  const [owner, revision, ciphertext, windowStart, requests] = f.logs.dropboxRows[0];
  assert.equal(owner, id); assert.equal(ciphertext, null); assert.notEqual(revision, dropboxRow.revision);
  assert.match(revision, /^[0-9a-f-]{36}$/);
  assert.equal(windowStart, dropboxRow.window_start); assert.equal(requests, dropboxRow.requests);
  assert.ok(f.logs.destination.findIndex(sql => sql.startsWith('UPDATE public.users SET metadata'))
    > f.logs.destination.findIndex(sql => sql.startsWith('INSERT INTO "bound_dropbox_private"."links"')),
  'signup-triggering metadata updates wait until original business/profile rows are restored');
  assert.ok(f.logs.source.some(sql => sql.startsWith('DECLARE') && sql.includes('NULL::text AS "ciphertext"')));
  assert.equal(dropboxRow.ciphertext, 'original-encrypted-grant');
  assert.equal(f.logs.source.at(-1), 'ROLLBACK'); assert.equal(f.logs.destination.at(-1), 'COMMIT');
});
