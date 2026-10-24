import assert from 'node:assert/strict';
import test from 'node:test';
import { fixture, owner, peer, third, roomID, plain } from './fixture.mjs';

test('verifies HMAC tickets with fixed, sorted room membership', () => {
  const f = fixture(); const claims = plain(f.api.verifyTicket(f.ctx, f.nk, f.ticket()));
  assert.equal(claims.ownerID, owner); assert.deepEqual(claims.members, [owner, peer]);
  assert.equal(claims.expiresAt, 1090);
});

for (const fields of [
  { version: 2 }, { protocol: 'unknown' }, { ownerID: third }, { roomID: roomID.toUpperCase() },
  { roomID: 'invalid' }, { members: [peer, owner] }, { members: [owner, owner] }, { members: [owner] },
  { members: Array.from({ length: 9 }, (_, i) => `${i}1111111-1111-4111-8111-111111111111`) },
  { expiresAt: 1000 }, { expiresAt: 1091 }, { issuedAt: 1006 }, { issuedAt: 1000.5 }, { expiresAt: 1089.5 }, { extra: true },
]) {
  test('rejects malformed signed ticket ' + JSON.stringify(fields), () => {
    const f = fixture(); assert.throws(() => f.api.verifyTicket(f.ctx, f.nk, f.ticket(owner, fields)));
  });
}

test('rejects forged, noncanonical and missing signatures before authentication', () => {
  const f = fixture(); const good = f.ticket();
  for (const value of [null, '', good.replace(/.$/, 'z'), good + 'x', good.split('.')[0], 'x'.repeat(5000)]) {
    assert.throws(() => f.api.verifyTicket(f.ctx, f.nk, value));
  }
  f.now(1090); assert.throws(() => f.api.verifyTicket(f.ctx, f.nk, good));
});

test('custom authentication binds identity and discards all supplied session vars', () => {
  const f = fixture();
  const request = { account: { id: 'bound:' + owner, vars: { bound_ticket: f.ticket(), bound_owner_id: peer, arbitrary: 'ignored' } } };
  const result = f.api.authenticate(f.ctx, f.logger, f.nk, request);
  assert.deepEqual(plain(result.account.vars), { bound_owner_id: owner });
  assert.throws(() => f.api.authenticate(f.ctx, f.logger, f.nk, { account: { id: 'bound:' + peer, vars: { bound_ticket: f.ticket() } } }));
  assert.throws(() => f.api.authenticate(f.ctx, f.logger, f.nk, { account: { id: 'bound:' + owner } }));
});

test('module disables alternate authentication, identity relinking and client-created matches', () => {
  const f = fixture(); f.init();
  for (const method of ['registerBeforeAuthenticateDevice', 'registerBeforeAuthenticateEmail', 'registerBeforeAuthenticate', 'registerBeforeSessionRefresh',
    'registerBeforeAuthenticateApple', 'registerBeforeLinkCustom', 'registerBeforeUnlinkCustom']) {
    assert.throws(() => f.registrations[method][0]());
  }
  assert.equal(f.registrations.registerRtBefore[0], 'MatchCreate');
  assert.throws(() => f.registrations.registerRtBefore[1]());
  assert.equal(f.registrations.registerRpc[0], 'bound_room_v1');
  assert.equal(f.registrations.registerMatch[0], 'bound_room_v1');
  f.ctx.env.BOUND_NAKAMA_BRIDGE_SECRET = ''; assert.throws(() => f.init());
});

test('room allocation reuses one authoritative match and keeps directory server-only', () => {
  const f = fixture();
  const request = () => JSON.parse(f.api.roomRPC(f.ctx, f.logger, f.nk, JSON.stringify({ ticket: f.ticket() })));
  const first = request(); const second = request();
  assert.equal(first.matchID, second.matchID); assert.equal(f.active.size, 1);
  assert.equal(first.nakamaUserID, f.ctx.userId); assert.equal(first.protocol, 'bound-room-v1');
  assert.equal(f.stored.get(roomID).permissionRead, 0); assert.equal(f.stored.get(roomID).permissionWrite, 0);
});

test('concurrent allocation uses CAS and immediately cleans its losing match', () => {
  const f = fixture(); const write = f.nk.storageWrite; let interleave = true; let winner;
  f.nk.storageWrite = writes => {
    if (interleave) {
      interleave = false;
      const candidate = writes[0]; winner = f.nk.matchCreate('bound_room_v1', {});
      write([{ ...candidate, value: { ...candidate.value, matchID: winner } }]);
    }
    return write(writes);
  };
  const result = JSON.parse(f.api.roomRPC(f.ctx, f.logger, f.nk, JSON.stringify({ ticket: f.ticket() })));
  assert.equal(result.matchID, winner); assert.equal(f.active.size, 1); assert.equal(f.discarded.length, 1);
  assert.equal(f.discarded[0].signal.type, 'discard');
});

test('replaces stale directory with version CAS; refuses identity mismatch and membership changes', () => {
  const f = fixture(); const call = value => JSON.parse(f.api.roomRPC(f.ctx, f.logger, f.nk, JSON.stringify({ ticket: value })));
  const first = call(f.ticket()); f.active.delete(first.matchID);
  assert.notEqual(call(f.ticket()).matchID, first.matchID);
  assert.throws(() => call(f.ticket(peer)));
  assert.throws(() => call(f.ticket(owner, { members: [owner, peer, third] })));
  assert.throws(() => f.api.roomRPC({ ...f.ctx, userId: undefined }, f.logger, f.nk, JSON.stringify({ ticket: f.ticket() })));
});

test('signed room membership and protected custom identity are both required to join', () => {
  const f = fixture();
  assert.equal(f.join(owner).accept, true); assert.equal(f.join(peer).accept, true);
  assert.equal(f.join(third).accept, false);
  assert.equal(f.join(owner, 2).accept, true);
  assert.ok(f.kicks.some(p => p.sessionId === f.presence(owner).sessionId));
  const result = f.api.match.matchJoinAttempt(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state,
    f.presence(peer, 2), { bound_ticket: f.ticket(owner) });
  assert.equal(result.accept, false);
});

test('room design admits eight signed members without a two-player server assumption', () => {
  const group = Array.from({ length: 8 }, (_, i) => `${i + 1}1111111-1111-4111-8111-111111111111`);
  const f = fixture(group);
  for (const id of group) assert.equal(f.join(id).accept, true);
  const roster = f.broadcasts.at(-1); assert.equal(roster.opcode, 4);
  assert.equal(roster.data.members.length, 8); assert.ok(roster.data.members.every(m => m.online));
});

test('coalesces positions within each tick, preserves critical ordering and excludes the sender', () => {
  const f = fixture(); f.join(); f.join(peer); f.broadcasts.length = 0;
  f.loop([f.message(owner, 1, f.frame('old')), f.message(owner, 2, f.frame('event-1')),
    f.message(owner, 1, f.frame('latest')), f.message(owner, 3, f.frame('battle', peer)), f.message(owner, 2, f.frame('event-2'))]);
  assert.deepEqual(f.broadcasts.map(m => m.opcode), [2, 3, 2, 1]);
  assert.equal(Buffer.from(f.broadcasts.at(-1).data.body, 'base64').toString(), 'latest');
  assert.equal(f.broadcasts.at(-1).reliable, false);
  for (const message of f.broadcasts) {
    assert.equal(message.data.senderOwnerID, owner);
    assert.equal(message.recipients.length, 1); assert.equal(message.recipients[0].userId, f.presence(peer).userId);
  }
});

test('battle messages are pair-targeted and opaque bytes survive unchanged', () => {
  const f = fixture([owner, peer, third]); f.join(); f.join(peer); f.join(third); f.broadcasts.length = 0;
  const binary = Uint8Array.from([0, 255, 128, 10, 0]);
  f.loop([f.message(owner, 3, f.frame(binary, peer))]);
  assert.equal(f.broadcasts.length, 1); assert.equal(f.broadcasts[0].recipients.length, 1);
  assert.equal(f.broadcasts[0].recipients[0].userId, f.presence(peer).userId);
  assert.deepEqual([...Buffer.from(f.broadcasts[0].data.body, 'base64')], [...binary]);
});

test('position coalescing works when repeated state lookups rematerialize wrapper objects', () => {
  const f = fixture(); f.join(); f.join(peer); f.broadcasts.length = 0;
  const sessions = f.state.sessions;
  // Nakama's Goja state crosses Go maps between callbacks. Two JS lookups can
  // wrap the same stored session with different proxy object identities.
  f.state.sessions = new Proxy(sessions, { get(target, property) {
    const value = Reflect.get(target, property);
    return value && typeof value === 'object' ? new Proxy(value, {}) : value;
  } });
  f.loop([f.message(owner, 1, f.frame('old')), f.message(owner, 1, f.frame('latest'))]);
  assert.equal(f.broadcasts.length, 1);
  assert.equal(Buffer.from(f.broadcasts[0].data.body, 'base64').toString(), 'latest');
});

for (const makeFrame of [f => f.frame('battle'), f => f.frame('battle', owner), f => f.frame('battle', third),
  f => ({ ...f.frame('battle', peer), senderOwnerID: peer }), f => ({ v: 1, body: '<invalid>', targetOwnerID: peer }),
  f => f.frame('x'.repeat(8193), peer)]) {
  test('kicks malformed, forged or untargeted reliable gameplay', () => {
    const f = fixture(); f.join(); f.join(peer); f.broadcasts.length = 0;
    f.loop([f.message(owner, 3, makeFrame(f))]);
    assert.equal(f.kicks.length, 1); assert.equal(f.kicks[0].userId, f.presence(owner).userId);
    assert.ok(!f.broadcasts.some(m => m.opcode === 3));
  });
}

test('unknown sessions and mismatching transport user IDs cannot inject data', () => {
  const f = fixture(); f.join(); f.join(peer); f.broadcasts.length = 0;
  const forged = f.message(owner, 2, f.frame()); forged.sender.userId = f.presence(peer).userId;
  f.loop([forged, f.message(owner, 2, f.frame(), 9), f.message(third, 2, f.frame())]);
  assert.equal(f.broadcasts.length, 0);
});

test('reliable lane overload disconnects instead of silently dropping commands', () => {
  const f = fixture(); f.join(); f.join(peer); f.broadcasts.length = 0;
  f.loop(Array.from({ length: 241 }, () => f.message(owner, 3, f.frame('battle', peer))));
  assert.equal(f.kicks.length, 1);
  assert.equal(f.broadcasts.filter(m => m.opcode === 3).length, 240);
});

test('expired tickets close gameplay; a valid renewal extends only its own room lease', () => {
  const f = fixture(); f.join(); f.join(peer); f.now(1040);
  f.loop([f.message(owner, 5, { v: 1, ticket: f.ticket() })]);
  f.now(1090); f.loop([]);
  assert.deepEqual(f.kicks.map(p => p.userId), [f.presence(peer).userId]);
  f.now(1130); f.loop([]);
  assert.equal(f.kicks.length, 2);
});

test('renewal cannot impersonate a different member or change room membership', () => {
  const f = fixture(); f.join(); f.join(peer);
  f.loop([f.message(owner, 5, { v: 1, ticket: f.ticket(peer) })]);
  assert.equal(f.kicks.length, 1); assert.equal(f.kicks[0].userId, f.presence(owner).userId);
});

test('abandoned admissions expire and idle rooms terminate; cleanup cannot stop an occupied room', () => {
  const f = fixture();
  f.api.match.matchJoinAttempt(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state, f.presence(owner), { bound_ticket: f.ticket() });
  f.now(1005); f.loop([]); assert.equal(Object.keys(f.state.sessions).length, 0);
  f.now(1065); assert.equal(f.loop([]), null);
  const occupied = fixture(); occupied.join();
  assert.ok(occupied.api.match.matchSignal(occupied.ctx, occupied.logger, occupied.nk, occupied.dispatcher, 0,
    occupied.state, JSON.stringify({ type: 'discard', cleanupToken: 'cleanup' })));
  const empty = fixture();
  empty.api.match.matchSignal(empty.ctx, empty.logger, empty.nk, empty.dispatcher, 0,
    empty.state, JSON.stringify({ type: 'discard', cleanupToken: 'cleanup' }));
  assert.equal(empty.loop([]), null);
});
