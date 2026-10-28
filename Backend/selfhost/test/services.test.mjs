import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createHmac } from 'node:crypto';
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
  assert.equal((await services.handle(request('/rest/v1/rpc/bound_game_notification_dispatch', {
    sender: owner, room, request: file, kind: 'shared-join', run: file, installation: file,
  }))).status,404);
  assert.equal(pool.calls.length,0);
});

test('notification settings and atomic device registration use authenticated parameterized RPCs', async () => {
  for (const name of ['bound_notification_preferences','bound_notification_device']) {
    const pool=db({ok:true});
    const services=createServices({pool,authenticate:async()=>identity});
    const payload={installationID:file,revision:'123',sendJoin:'true',receiveInvites:'false'};
    assert.equal((await services.handle(request('/rest/v1/rpc/'+name,{payload}))).status,200);
    assert.deepEqual(pool.calls.find(call=>call.sql.startsWith('SELECT public.'+name)).args,[JSON.stringify(payload)]);
  }
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

test('Dropbox token broker honors the shared cloud-provider gate before provider traffic', async () => {
  let guarded = false;
  const services = createServices({ pool: db({}), authenticate: async () => identity,
    withDropbox: async (actual, action) => {
      assert.equal(actual.id, owner); assert.equal(action, 'token'); guarded = true;
      return new Response('{"error":"backup_not_enabled"}', { status: 403 });
    },
    fetchImpl: async () => assert.fail('disabled Dropbox must not contact a provider') });
  const response = await services.handle(request('/functions/v1/bound-dropbox', { action: 'token' }));
  assert.equal(response.status, 403); assert.equal(guarded, true);
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


function saveBroker(options = {}) {
  const calls = []; let roomCalls = 0, authCalls = 0;
  const member = { ownerID: owner, roomID: room, members: [peer, owner], peerID: peer };
  const current = { ...identity, nakamaToken: 'synthetic.nakama.session', claims: { ...identity.claims, exp: options.exp ?? Math.floor(Date.now() / 1000) + 300 } };
  const pool = { connect: async () => ({ release() {}, query: async (sql, args) => {
    calls.push({ sql, args });
    if (sql.startsWith('SELECT EXISTS')) return { rows: [{ active: options.sessionActive !== false }] };
    if (sql.startsWith('SELECT public.bound_nakama_room_v1')) { roomCalls++; return { rows: [{ result: roomCalls > 1 ? options.finalRoom ?? options.room ?? member : options.room ?? member }] }; }
    if (sql.startsWith('SELECT public.cup117_account_active')) return { rows: [{ result: options.active !== false }] };
    return { rows: [] };
  } }) };
  const secret = 'synthetic-save-broker-secret-32-characters';
  const services = createServices({ pool, config: { PUBLIC_URL: 'https://bound.example', NAKAMA_HTTP_URL: 'http://nakama:7350', BOUND_NAKAMA_BRIDGE_SECRET: secret },
    authenticate: async () => { authCalls++; if (options.revoked && authCalls > 1) throw Error('revoked'); return options.finalOwner && authCalls > 1 ? { ...current, ownerID: peer, id: peer } : current; },
    fetchImpl: async () => assert.fail('save library must not allocate a live match') });
  return { calls, secret, call: body => services.handle(request('/functions/v1/nakama-session', body)), authCalls: () => authCalls };
}
test('selfhost save library authenticates and rechecks account/session without opening a gameplay match', async () => {
  const f = saveBroker(); const response = await f.call({ protocol: 'bound-saves-v1' });
  assert.equal(response.status, 200); const value = await response.json();
  assert.equal(value.ownerID, owner); assert.equal(value.httpEndpoint, 'https://bound.example'); assert.equal(value.accessToken, 'synthetic.nakama.session');
  assert.equal(f.authCalls(), 2); assert.ok(!f.calls.some(call => call.sql.startsWith('SELECT public.bound_nakama_room_v1')));
  const [claims, signature] = value.saveTicket.split('.');
  assert.equal(signature, createHmac('sha256', f.secret).update(claims).digest('hex'));
  const ticket = JSON.parse(Buffer.from(claims, 'base64url'));
  assert.deepEqual(Object.keys(ticket).sort(), ['expiresAt', 'issuedAt', 'ownerID', 'protocol', 'version']);
  assert.equal(ticket.protocol, 'bound-saves-v1'); assert.equal(ticket.ownerID, owner);
});
test('selfhost save creation scope checks current friend membership twice and authenticates partner from the database', async () => {
  const f = saveBroker(); const response = await f.call({ protocol: 'bound-saves-v1', roomID: room });
  assert.equal(response.status, 200); const value = await response.json();
  assert.equal(value.partnerID, peer); assert.equal(value.roomID, room);
  assert.equal(f.calls.filter(call => call.sql.startsWith('SELECT public.bound_nakama_room_v1')).length, 2);
  const ticket = JSON.parse(Buffer.from(value.saveTicket.split('.')[0], 'base64url'));
  assert.equal(ticket.partnerID, peer); assert.equal(ticket.roomID, room);
});
for (const body of [{ protocol: 'bound-saves-v1', ownerID: peer }, { protocol: 'bound-saves-v1', partnerID: peer },
  { protocol: 'bound-saves-v1', roomID: 'bad' }]) {
  test('selfhost save broker rejects caller-selected identity ' + JSON.stringify(body), async () => {
    const f = saveBroker(); assert.equal((await f.call(body)).status, 400); assert.equal(f.calls.length, 0);
  });
}
for (const [options, expected] of [[{ active: false }, 403], [{ sessionActive: false }, 503], [{ revoked: true }, 503], [{ finalOwner: true }, 403],
  [{ exp: Math.floor(Date.now() / 1000) + 5 }, 503]]) {
  test('selfhost save broker rejects invalid or revoked authorization ' + JSON.stringify(options), async () => {
    const f = saveBroker(options); assert.equal((await f.call({ protocol: 'bound-saves-v1' })).status, expected);
  });
}
for (const options of [{ room: { ok: false } }, { room: { ownerID: owner, roomID: room, members: [owner, owner], peerID: owner } },
  { room: { ownerID: owner, roomID: room, members: [owner, peer], peerID: session } }, { finalRoom: { ok: false } }]) {
  test('selfhost save creation scope rejects changed or malformed friendship ' + JSON.stringify(options), async () => {
    const f = saveBroker(options); assert.equal((await f.call({ protocol: 'bound-saves-v1', roomID: room })).status, 403);
  });
}
test('selfhost save ticket response is bounded by the native authenticated session expiry', async () => {
  const expiry = Math.floor(Date.now() / 1000) + 45, f = saveBroker({ exp: expiry });
  const response = await f.call({ protocol: 'bound-saves-v1' }); assert.equal(response.status, 200);
  assert.equal((await response.json()).expiresAt, expiry);
});
