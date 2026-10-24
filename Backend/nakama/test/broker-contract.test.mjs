import assert from 'node:assert/strict';
import test from 'node:test';
import { createNakamaSessionHandler } from '../../nakama-session/handler.mjs';
import { fixture, owner, peer, roomID, secret } from './fixture.mjs';

test('real broker signs a ticket accepted by runtime authentication, room RPC, join and renewal', async () => {
  const f = fixture();
  // The account's internal Nakama UUID differs from its Supabase owner UUID.
  const userID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  f.ctx.userId = userID;
  f.nk.accountGetId = id => { assert.equal(id, userID); return { customId: 'bound:' + owner }; };
  let now = 1000; let authCalls = 0;
  const json = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
  const broker = createNakamaSessionHandler({
    publishableKey: 'fixture-public', nakamaHTTPURL: 'https://bound-game.example.invalid',
    nakamaServerKey: 'fixture-server-key-123456789', bridgeSecret: secret, now: () => now,
    fetchImpl: async (url, options) => {
      if (url.endsWith('/auth/v1/user')) return json({ id: owner, role: 'authenticated', is_anonymous: false, email_confirmed_at: '2026-01-01T00:00:00Z' });
      if (url.endsWith('/rpc/cup117_account_active')) return json(true);
      if (url.endsWith('/rpc/bound_nakama_room_v1')) return json({ roomID, ownerID: owner, members: [peer, owner], peerID: peer });
      if (url.includes('/account/authenticate/custom')) {
        authCalls++;
        f.api.authenticate(f.ctx, f.logger, f.nk, { account: JSON.parse(options.body) });
        const token = Buffer.from('{"alg":"HS256"}').toString('base64url') + '.' +
          Buffer.from(JSON.stringify({ uid: userID, exp: now + 120 })).toString('base64url') + '.synthetic';
        return json({ token });
      }
      if (url.endsWith('/rpc/bound_room_v1')) return json({ payload: f.api.roomRPC(f.ctx, f.logger, f.nk, JSON.parse(options.body)) });
      throw Error('Unexpected request');
    },
  });
  const request = () => broker(new Request('https://fixture.invalid', {
    method: 'POST', headers: { Authorization: 'Bearer synthetic.valid.session', 'Content-Type': 'application/json' },
    body: JSON.stringify({ roomID, protocol: 'bound-room-v1' }),
  }));
  const response = await request(); assert.equal(response.status, 200);
  const first = await response.json();
  const presence = { userId: userID, sessionId: 'fixture-session', node: 'fixture', username: 'fixture' };
  const attempt = f.api.match.matchJoinAttempt(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state, presence, { bound_ticket: first.joinTicket });
  assert.equal(attempt.accept, true);
  f.api.match.matchJoin(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state, [presence]);
  now = 1040; f.now(now);
  const renewed = await (await request()).json();
  assert.equal(renewed.matchID, first.matchID); assert.equal(authCalls, 2); assert.equal(f.active.size, 1);
  f.loop([{ sender: presence, opCode: 5, data: new TextEncoder().encode(JSON.stringify({ v: 1, ticket: renewed.joinTicket })).buffer }]);
  assert.equal(f.state.sessions[presence.sessionId].expiresAt, 1130); assert.equal(f.kicks.length, 0);
});

test('real save broker scopes authenticate permanent offline saves without creating any match', async () => {
  const f = fixture(); let next = 100;
  f.nk.uuidv4 = () => `eeeeeeee-eeee-4eee-8eee-${String(++next).padStart(12, '0')}`;
  const users = { [owner]: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', [peer]: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' };
  f.nk.accountGetId = id => ({ customId: 'bound:' + Object.keys(users).find(who => users[who] === id) });
  const json = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
  const broker = createNakamaSessionHandler({ publishableKey: 'fixture-public', nakamaHTTPURL: 'https://bound-game.example.invalid',
    nakamaServerKey: 'fixture-server-key-123456789', bridgeSecret: secret, now: () => 1000,
    fetchImpl: async (url, options) => {
      const who = options.headers.Authorization === 'Bearer synthetic.peer.session' ? peer : owner;
      if (url.endsWith('/auth/v1/user')) return json({ id: who, role: 'authenticated', is_anonymous: false, email_confirmed_at: '2026-01-01T00:00:00Z' });
      if (url.endsWith('/rpc/cup117_account_active')) return json(true);
      if (url.endsWith('/rpc/bound_nakama_room_v1')) return json({ roomID, ownerID: who, members: [peer, owner], peerID: who === owner ? peer : owner });
      if (url.includes('/account/authenticate/custom')) {
        const account = JSON.parse(options.body), actual = account.id.slice(6);
        f.api.authenticate(f.ctx, f.logger, f.nk, { account });
        return json({ token: Buffer.from('{"alg":"HS256"}').toString('base64url') + '.' + Buffer.from(JSON.stringify({ uid: users[actual], exp: 1120 })).toString('base64url') + '.synthetic' });
      }
      assert.fail('save authorization must not allocate a room: ' + url);
    } });
  const credentials = async (who, create = false) => {
    const response = await broker(new Request('https://fixture.invalid', { method: 'POST',
      headers: { Authorization: who === peer ? 'Bearer synthetic.peer.session' : 'Bearer synthetic.owner.session', 'Content-Type': 'application/json' },
      body: JSON.stringify({ protocol: 'bound-saves-v1', ...(create ? { roomID } : {}) }) }));
    assert.equal(response.status, 200); return response.json();
  };
  const host = await credentials(owner, true), friend = await credentials(peer);
  const call = (who, auth, action, fields) => JSON.parse(f.independent.rpc({ ...f.ctx, userId: users[who] }, f.logger, f.nk,
    JSON.stringify({ action, saveTicket: auth.saveTicket, ...fields })));
  const settings = Buffer.alloc(32); settings[0] = 4; settings[12] = 187; settings.fill(255, 13, 20);
  const created = call(owner, host, 'create', { partnerID: host.partnerID, request_id: roomID, gameID: 'multi_red', romSHA256: 'a'.repeat(64), settings: settings.toString('base64') });
  assert.equal(call(peer, friend, 'list', { gameID: 'multi_red' }).runs[0].save_id, created.save_id);
  assert.equal(call(peer, friend, 'get', { save_id: created.save_id }).identity.owner, peer);
  assert.equal(f.active.size, 0);
});
