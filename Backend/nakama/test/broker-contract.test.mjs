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
