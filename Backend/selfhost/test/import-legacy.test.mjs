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

function fixture({ factors = 0, destinationAccounts = 0, failInsert = false } = {}) {
  const logs = { source: [], destination: [] }, state = { inserted: 0, fetches: 0 };
  const source = { async query(sql, parameters) {
    logs.source.push(sql);
    assert.ok(/^(BEGIN .*READ ONLY|SET LOCAL|SHOW |SELECT |DECLARE |FETCH |CLOSE |ROLLBACK)/.test(sql), 'source never gets writes');
    if (sql.startsWith('SHOW')) return { rows: [{ transaction_read_only: 'on' }] };
    if (sql.includes('FROM pg_class')) return { rows: [
      { schema: 'auth', name: 'users', kind: 'r' }, { schema: 'auth', name: 'mfa_factors', kind: 'r' },
      { schema: 'auth', name: 'identities', kind: 'r' }] };
    if (sql.includes('FROM information_schema.columns')) return { rows: Object.keys(account()).map(name => field(name)) };
    if (sql.startsWith('SELECT count')) {
      if (sql.includes('mfa_factors')) return { rows: [{ count: String(factors) }] };
      if (sql.includes(' WHERE ') || sql.includes(' duplicates')) return { rows: [{ count: '0' }] };
      return { rows: [{ count: '1' }] };
    }
    if (sql.startsWith('FETCH')) return { rows: state.fetches++ ? [] : [account()] };
    return { rows: [] };
  } };
  const destination = { async query(sql, parameters) {
    logs.destination.push(sql);
    if (sql.includes('FROM pg_class')) return { rows: [
      { schema: 'auth', name: 'users', kind: 'v' }, { schema: 'public', name: 'users', kind: 'r' },
      { schema: 'public', name: 'storage', kind: 'r' }] };
    if (sql.includes('FROM information_schema.columns')) return { rows: [field('id', 'uuid'), field('password', 'bytea'), field('metadata', 'jsonb'), field('custom_id', 'varchar')] };
    if (sql.startsWith('SELECT count')) return { rows: [{ count: String(sql.includes('"users"') ? destinationAccounts + state.inserted : 0) }] };
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
