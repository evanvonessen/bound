import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServices } from '../services.mjs';
import { createFileService } from '../files.mjs';

const owner = '11111111-1111-4111-8111-111111111111';
const peer = '22222222-2222-4222-8222-222222222222';
const session = '33333333-3333-4333-8333-333333333333';
const room = '44444444-4444-4444-8444-444444444444';
const file = '55555555-5555-4555-8555-555555555555';
const identity = { id: owner, ownerID: owner, sessionID: session,
  claims: { sub: 'spoofed', role: 'service_role', session_id: 'spoofed', aal: 'aal1' },
  user: { id: owner, email_confirmed_at: '2026-10-22T00:00:00Z' } };
const request = (path, body = {}, headers = {}) => new Request(`https://bound.example${path}`, {
  method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body),
});
const db = result => {
  const calls = [];
  const client = { async query(sql, args) {
    calls.push({ sql, args });
    return { rows: sql.startsWith('SELECT EXISTS') ? [{ active: true }] : [{ result }] };
  }, release() {} };
  return { calls, connect: async () => client };
};

test('service-only database operations have no public HTTP route', async () => {
  const pool = db({ ok: true });
  const services = createServices({ pool, authenticate: async () => identity });
  const response = await services.handle(request('/rest/v1/rpc/bound_dropbox_grant', { action: 'snapshot', payload: { owner: peer, session } }));
  assert.equal(response.status, 404);
  assert.equal(pool.calls.length, 0);
});

test('RPC claims derive from verified identity and statement arguments stay parameterized', async () => {
  const pool = db({ ok: true });
  const services = createServices({ pool, authenticate: async () => identity });
  const payload = { roomID: room, owner: peer };
  const response = await services.handle(request('/rest/v1/rpc/cup050_friends', { action: 'room', payload }));
  assert.equal(response.status, 200);
  const claims = JSON.parse(pool.calls.find(call => call.sql.includes('set_config')).args[0]);
  assert.equal(claims.sub, owner); assert.equal(claims.session_id, session); assert.equal(claims.role, 'authenticated');
  assert.deepEqual(pool.calls.find(call => call.sql.startsWith('SELECT public.cup050_friends')).args, ['room', JSON.stringify(payload)]);
});

test('invalid sessions and privileged owner spoofing cannot reach the database', async () => {
  const pool = db({});
  const services = createServices({ pool, authenticate: async () => { throw Error('revoked'); } });
  assert.equal((await services.handle(request('/functions/v1/bound-dropbox', { action: 'token' }))).status, 401);
  await assert.rejects(services.rpc(identity, 'bound_dropbox_grant', { action: 'snapshot', payload: { owner: peer, session } }, { service: true }), /unauthorized/);
  assert.equal(pool.calls.length, 0);
});

test('Agora authorization runs in process and blocked rooms never receive a token', async () => {
  let signed = false;
  const services = createServices({ pool: db(false), authenticate: async () => identity,
    config: { AGORA_APP_ID: 'a'.repeat(32), AGORA_APP_CERTIFICATE: 'b'.repeat(32) },
    fetchImpl: async () => { throw Error('Unexpected network'); }, signAgora: () => { signed = true; return 'token'; } });
  const response = await services.handle(request('/functions/v1/agora-token', { roomID: room }));
  assert.equal(response.status, 403); assert.equal(signed, false);
});

test('files require ownership or current room membership; stale room membership is denied', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bound-file-test-'));
  try {
    let shared = false;
    const files = createFileService({ config: { FILE_DIRECTORY: directory }, authenticate: async () => identity,
      pool: { query: async () => ({ rows: [{ id: file, owner: peer, room, shared, expires_at: new Date(Date.now() + 60000), state: 'ready' }] }) },
      rpc: async (_identity, name) => name === 'cup117_account_active' ? true : ({ ok: false }) });
    const make = () => new Request(`https://bound.example/files/v1/transfers/${file}`);
    assert.equal((await files.handle(make())).status, 404);
    shared = true;
    assert.equal((await files.handle(make())).status, 404);
    assert.equal((await files.handle(new Request('https://bound.example/files/v1/transfers/../../secret'))), null);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
