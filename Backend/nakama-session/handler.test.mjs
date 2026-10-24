import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';
import { createNakamaSessionHandler } from './handler.mjs';

const owner = '11111111-1111-4111-8111-111111111111';
const peer = '22222222-2222-4222-8222-222222222222';
const stranger = '33333333-3333-4333-8333-333333333333';
const roomID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const nakamaUserID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const matchID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc.bound-node';
const origin = 'https://bound-game.example.invalid';
const protocol = 'bound-room-v1';
const bridgeSecret = 'synthetic-fixture-bridge-secret-123456789';
const serverKey = 'synthetic-fixture-server-key';
const token = (claims = {}) => Buffer.from('{"alg":"HS256"}').toString('base64url') + '.' +
  Buffer.from(JSON.stringify({ uid: nakamaUserID, exp: 5000, ...claims })).toString('base64url') + '.synthetic';
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
const identity = { id: owner, role: 'authenticated', is_anonymous: false, email_confirmed_at: '2026-01-01T00:00:00Z' };
const membership = { roomID, ownerID: owner, members: [peer, owner], peerID: peer };

function fixture(options = {}) {
  const calls = []; let roomCalls = 0; let activeCalls = 0; let current = 1000;
  const handler = createNakamaSessionHandler({ publishableKey: 'synthetic-public', nakamaHTTPURL: origin,
    nakamaServerKey: serverKey, bridgeSecret, now: () => current, requestTimeoutMs: 100,
    ...options.config,
    fetchImpl: async (url, config) => {
      calls.push({ url, ...config });
      if (options.failAt && url.includes(options.failAt)) throw Error('synthetic sensitive upstream detail');
      if (url.endsWith('/auth/v1/user')) return json(options.user ?? identity, options.authStatus ?? 200);
      if (url.endsWith('/rpc/cup117_account_active')) { activeCalls++; return json(activeCalls > 1 ? options.finalActive ?? options.active ?? true : options.active ?? true, options.activeStatus ?? 200); }
      if (url.endsWith('/rpc/bound_nakama_room_v1')) {
        roomCalls += 1;
        assert.deepEqual(JSON.parse(config.body), { payload: { roomID } });
        return json(roomCalls > 1 ? options.finalRoom ?? options.room ?? membership : options.room ?? membership, options.roomStatus ?? 200);
      }
      if (url.startsWith(origin + '/v2/account/authenticate/custom')) {
        assert.equal(config.headers.Authorization, 'Basic ' + Buffer.from(serverKey + ':').toString('base64'));
        if (options.afterAuth) current = options.afterAuth;
        return json({ token: options.token ?? token(), refreshToken: 'synthetic-do-not-return-refresh' }, options.nakamaAuthStatus ?? 200);
      }
      if (url === origin + '/v2/rpc/bound_room_v1') {
        assert.equal(config.headers.Authorization, 'Bearer ' + (options.token ?? token()));
        if (options.afterRPC) current = options.afterRPC;
        return json(options.rpc ?? { payload: JSON.stringify({ matchID, roomID, protocol, nakamaUserID, ...options.match }) }, options.rpcStatus ?? 200);
      }
      throw Error('unexpected fixture URL');
    },
  });
  return { calls, request: (body = { roomID, protocol }, headers = {}) => handler(new Request('https://fixture.invalid/nakama-session', {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer synthetic.valid.session', ...headers }, body: JSON.stringify(body),
  })), handler };
}

test('issues a room-bound short lease without returning server or refresh credentials', async () => {
  const f = fixture(); const response = await f.request();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const value = await response.json();
  assert.deepEqual(Object.keys(value).sort(), ['endpoint', 'httpEndpoint', 'accessToken', 'expiresAt', 'matchID', 'roomID', 'ownerID', 'nakamaUserID', 'joinTicket', 'members', 'peerOwnerID'].sort());
  assert.equal(value.endpoint, 'wss://bound-game.example.invalid/ws?format=json&status=false');
  assert.equal(value.httpEndpoint, origin);
  assert.equal(value.accessToken, token());
  assert.equal(value.expiresAt, 1090);
  assert.equal(value.matchID, matchID);
  assert.equal(value.nakamaUserID, nakamaUserID);
  assert.equal(value.ownerID, owner);
  assert.equal(value.peerOwnerID, peer);
  assert.deepEqual(value.members, [owner, peer]);
  const [payload, signature] = value.joinTicket.split('.');
  assert.equal(signature, createHmac('sha256', bridgeSecret).update(payload).digest('hex'));
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url')), { version: 1, protocol, ownerID: owner, roomID,
    members: [owner, peer], issuedAt: 1000, expiresAt: 1090 });
  const authCall = f.calls.find(call => call.url.includes('/authenticate/custom'));
  assert.deepEqual(JSON.parse(authCall.body), { id: 'bound:' + owner, vars: { bound_ticket: value.joinTicket } });
  assert.deepEqual(JSON.parse(JSON.parse(f.calls.find(call => call.url.endsWith('/rpc/bound_room_v1')).body)), { ticket: value.joinTicket });
  assert.equal(f.calls.filter(call => call.url.endsWith('/rpc/bound_nakama_room_v1')).length, 2);
  for (const call of f.calls) { assert.equal(call.redirect, 'error'); assert.ok(call.signal instanceof AbortSignal); }
  const serialized = JSON.stringify(value);
  for (const secret of [bridgeSecret, serverKey, 'synthetic.valid.session', 'synthetic-do-not-return-refresh']) assert.ok(!serialized.includes(secret));
});

test('a renewed broker session creates a fresh ticket and rechecks membership', async () => {
  const f = fixture({ afterRPC: 1040 });
  const first = await (await f.request()).json();
  const second = await (await f.request()).json();
  assert.notEqual(first.joinTicket, second.joinTicket);
  assert.equal(second.matchID, first.matchID);
  assert.equal(second.expiresAt, 1130);
  assert.equal(f.calls.filter(call => call.url.endsWith('/rpc/bound_nakama_room_v1')).length, 4);
});

for (const authorization of ['', 'Bearer short', 'Basic synthetic.valid.session', 'Bearer injected token']) {
  test('rejects invalid bearer ' + JSON.stringify(authorization), async () => {
    const f = fixture(); assert.equal((await f.request(undefined, { Authorization: authorization })).status, 401); assert.equal(f.calls.length, 0);
  });
}
for (const body of [{}, { roomID }, { roomID, protocol: 'unknown' }, { roomID: 'invalid', protocol },
  { roomID, protocol, ownerID: stranger }, { roomID, protocol, members: [owner, stranger] }, [], null]) {
  test('rejects malformed or caller-selected identity request ' + JSON.stringify(body), async () => {
    const f = fixture(); assert.equal((await f.request(body)).status, 400); assert.equal(f.calls.length, 0);
  });
}
test('rejects browser origins until website authorization is explicitly configured', async () => {
  const f = fixture(); assert.equal((await f.request(undefined, { Origin: 'https://untrusted.invalid' })).status, 403); assert.equal(f.calls.length, 0);
});
test('rejects other methods, content types and oversized bodies', async () => {
  const f = fixture();
  assert.equal((await f.handler(new Request('https://fixture.invalid', { method: 'GET' }))).status, 405);
  assert.equal((await f.request(undefined, { 'Content-Type': 'text/plain' })).status, 400);
  assert.equal((await f.request({ roomID, protocol, large: 'x'.repeat(1000) })).status, 400);
  assert.equal(f.calls.length, 0);
});
for (const user of [{ ...identity, is_anonymous: true }, { ...identity, email_confirmed_at: null },
  { ...identity, id: 'bad' }, { ...identity, role: 'anon' }, { ...identity, deleted_at: '2026-01-01' }]) {
  test('rejects an ineligible live account ' + JSON.stringify(user), async () => {
    const f = fixture({ user }); assert.equal((await f.request()).status, 403); assert.equal(f.calls.length, 1);
  });
}
test('revoked or deleted Auth identity stops before room or Nakama access', async () => {
  const f = fixture({ authStatus: 401 }); assert.equal((await f.request()).status, 401); assert.equal(f.calls.length, 1);
});
for (const options of [{ active: false }, { activeStatus: 403 }, { roomStatus: 403 }, { room: { ok: false } },
  { room: { ...membership, roomID: stranger } }, { room: { ...membership, ownerID: stranger } },
  { room: { ...membership, members: [owner, owner] } }, { room: { ...membership, members: [stranger, peer] } },
  { room: { ...membership, peerID: stranger } }, { room: { ...membership, peerID: owner } },
  { room: { ...membership, members: [owner, peer, 'invalid'] } },
  { room: { ...membership, members: Array.from({ length: 9 }, (_, i) => String(i).repeat(8) + '-1111-4111-8111-111111111111') } }]) {
  test('room authorization fails closed ' + JSON.stringify(options), async () => {
    const f = fixture(options); assert.equal((await f.request()).status, 403); assert.ok(!f.calls.some(call => call.url.startsWith(origin)));
  });
}
for (const config of [{ nakamaHTTPURL: 'http://bound-game.example.invalid' }, { nakamaHTTPURL: origin + '/proxy' },
  { nakamaHTTPURL: origin + '?token=secret' }, { nakamaHTTPURL: 'https://name:password@bound-game.example.invalid' },
  { nakamaHTTPURL: 'https://127.0.0.1' }, { nakamaHTTPURL: 'https://localhost' }, { nakamaHTTPURL: '' },
  { bridgeSecret: 'short' }, { nakamaServerKey: 'defaultkey' }, { publishableKey: '' }]) {
  test('configuration fails closed ' + JSON.stringify(config), async () => {
    const f = fixture({ config }); assert.deepEqual(await (await f.request()).json(), { error: 'not_configured' }); assert.equal(f.calls.length, 0);
  });
}
for (const options of [{ nakamaAuthStatus: 401 }, { rpcStatus: 500 }, { token: 'invalid' }, { token: token({ uid: owner }) },
  { token: token({ exp: 1000 }) }, { token: token({ exp: '5000' }) }, { rpc: {} }, { rpc: { payload: '{}' } },
  { rpc: { payload: 'invalid' } }, { match: { roomID: stranger } }, { match: { protocol: 'bad' } },
  { match: { nakamaUserID: owner } }, { match: { matchID: 'not-a-match' } }, { afterRPC: 1090 }]) {
  test('rejects upstream errors, expiry or mismatched identity ' + JSON.stringify(options), async () => {
    const f = fixture(options); const response = await f.request();
    assert.equal(response.status, 503); assert.deepEqual(await response.json(), { error: 'gameplay_unavailable' });
  });
}
test('a shorter Nakama session bounds the returned lease', async () => {
  const f = fixture({ token: token({ exp: 1050 }) }); const value = await (await f.request()).json(); assert.equal(value.expiresAt, 1050);
});
test('block, logout or deletion racing issuance returns no credentials', async () => {
  for (const finalRoom of [{ ok: false }, { ...membership, members: [owner, stranger], peerID: stranger }]) {
    const f = fixture({ finalRoom }); const response = await f.request();
    assert.equal(response.status, 403); assert.deepEqual(await response.json(), { error: 'forbidden' });
  }
});
for (const [failAt, error] of [['/auth/v1/user', 'identity_unavailable'], ['/rpc/cup117_account_active', 'identity_unavailable'],
  ['/rpc/bound_nakama_room_v1', 'membership_unavailable'], ['/authenticate/custom', 'gameplay_unavailable'], ['/rpc/bound_room_v1', 'gameplay_unavailable']]) {
  test('network failures return a redacted error at ' + failAt, async () => {
    const f = fixture({ failAt }); const response = await f.request();
    assert.equal(response.status, 503); assert.deepEqual(await response.json(), { error });
  });
}


test('save library broker authorizes without room resolution or match allocation', async () => {
  const f = fixture(); const response = await f.request({ protocol: 'bound-saves-v1' });
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
  const value = await response.json();
  assert.deepEqual(Object.keys(value).sort(), ['accessToken', 'expiresAt', 'httpEndpoint', 'ownerID', 'saveTicket'].sort());
  assert.equal(value.ownerID, owner); assert.equal(value.expiresAt, 1090);
  const [claims, signature] = value.saveTicket.split('.');
  assert.equal(signature, createHmac('sha256', bridgeSecret).update(claims).digest('hex'));
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { version: 1, protocol: 'bound-saves-v1', ownerID: owner, issuedAt: 1000, expiresAt: 1090 });
  assert.ok(!f.calls.some(call => /room_v1/.test(call.url)));
  assert.equal(f.calls.filter(call => call.url.endsWith('/rpc/cup117_account_active')).length, 2);
  assert.deepEqual(JSON.parse(f.calls.find(call => call.url.includes('/authenticate/custom')).body), { id: 'bound:' + owner, vars: { bound_ticket: value.saveTicket } });
});
test('save creation scope resolves an offline friend through an authorized existing room', async () => {
  const f = fixture(); const response = await f.request({ protocol: 'bound-saves-v1', roomID });
  assert.equal(response.status, 200); const value = await response.json();
  const claims = JSON.parse(Buffer.from(value.saveTicket.split('.')[0], 'base64url'));
  assert.deepEqual(claims, { version: 1, protocol: 'bound-saves-v1', ownerID: owner, issuedAt: 1000, expiresAt: 1090, partnerID: peer, roomID });
  assert.equal(value.partnerID, peer); assert.equal(value.roomID, roomID);
  assert.equal(f.calls.filter(call => call.url.endsWith('/rpc/bound_nakama_room_v1')).length, 2);
  assert.ok(!f.calls.some(call => call.url.endsWith('/rpc/bound_room_v1')));
});
for (const body of [{ protocol: 'bound-saves-v1', ownerID: stranger }, { protocol: 'bound-saves-v1', partnerID: peer },
  { protocol: 'bound-saves-v1', roomID: 'bad' }, { protocol: 'bound-saves-v1', roomID, members: [owner, stranger] }]) {
  test('save broker rejects caller-selected ownership ' + JSON.stringify(body), async () => {
    const f = fixture(); assert.equal((await f.request(body)).status, 400); assert.equal(f.calls.length, 0);
  });
}
for (const [options, status] of [[{ authStatus: 401 }, 401], [{ active: false }, 403], [{ finalActive: false }, 403],
  [{ user: { ...identity, email_confirmed_at: null } }, 403], [{ nakamaAuthStatus: 401 }, 503], [{ token: 'invalid' }, 503],
  [{ token: token({ exp: 1010 }) }, 503], [{ afterAuth: 1090 }, 503]]) {
  test('save broker refuses invalid or revoked sessions ' + JSON.stringify(options), async () => {
    const f = fixture(options); assert.equal((await f.request({ protocol: 'bound-saves-v1' })).status, status);
  });
}
for (const options of [{ roomStatus: 403 }, { room: { ...membership, peerID: stranger } },
  { finalRoom: { ...membership, members: [owner, stranger], peerID: stranger } }, { finalRoom: { ok: false } }]) {
  test('save creation scope refuses stale friendship ' + JSON.stringify(options), async () => {
    const f = fixture(options); assert.equal((await f.request({ protocol: 'bound-saves-v1', roomID })).status, 403);
    assert.ok(!f.calls.some(call => call.url.endsWith('/rpc/bound_room_v1')));
  });
}
test('save lease uses the shorter authenticated session lifetime', async () => {
  const f = fixture({ token: token({ exp: 1050 }) });
  assert.equal((await (await f.request({ protocol: 'bound-saves-v1' })).json()).expiresAt, 1050);
});
