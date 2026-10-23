import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, owner, peer, plain } from './fixture.mjs';
const gateway = 'synthetic-selfhost-gateway-secret-32-characters';
const session = '44444444-4444-4444-8444-444444444444';
function selfhost() {
  const f = fixture(); f.ctx.env.BOUND_ACCOUNT_MODE = 'nakama'; f.ctx.env.BOUND_GATEWAY_SECRET = gateway;
  f.nk.accountGetId = id => ({ customId: 'bound-selfhost:' + id, email: 'fixture@example.invalid', disableTime: 0,
    user: { userId: id, metadata: { bound_email_confirmed_at: '2026-01-01T00:00:00Z' } } });
  return f;
}
test('private native authentication strips gateway secret and rejects legacy/ticket-only access', () => {
  const f = selfhost(), request = { create: false, account: { id: 'bound-selfhost:' + owner, vars: { bound_gateway: gateway, session_id: session, session_nonce: session, aal: 'aal1', arbitrary: 'ignored' } } };
  const authenticated = plain(f.accounts.authenticate(f.ctx, f.logger, f.nk, request));
  assert.deepEqual(authenticated.account.vars, { session_id: session, session_nonce: session, aal: 'aal1', email: 'fixture@example.invalid' });
  assert.throws(() => f.accounts.authenticate(f.ctx, f.logger, f.nk, { create: false, account: { id: 'bound:' + owner, vars: { bound_ticket: f.ticket() } } }));
  assert.throws(() => f.accounts.authenticate(f.ctx, f.logger, f.nk, { ...request, create: true }));
  assert.throws(() => f.accounts.rpc(f.ctx, f.logger, f.nk, JSON.stringify({ gatewaySecret: gateway, action: 'account', id: owner })), 'player sessions cannot call account authority');
});
test('selfhost room admission uses stable Nakama UUID and never falls back to legacy custom identity', () => {
  const f = selfhost();
  const presence = { ...f.presence(owner), userId: owner };
  assert.equal(f.api.match.matchJoinAttempt(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state, presence, { bound_ticket: f.ticket() }).accept, true);
  assert.equal(f.api.match.matchJoinAttempt(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state, { ...presence, userId: peer }, { bound_ticket: f.ticket() }).accept, false);
  assert.equal(f.api.match.matchJoinAttempt(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state, f.presence(owner), { bound_ticket: f.ticket() }).accept, false);
});

test('client storage creation/deletion and account RPC cannot forge auth journal records', () => {
  const f = selfhost(); f.init();
  for (const name of ['registerBeforeWriteStorageObjects', 'registerBeforeDeleteStorageObjects']) {
    assert.throws(() => f.registrations[name][0](f.ctx, f.logger, f.nk, { objects: [{ collection: 'bound_auth_sessions_v1', key: session, value: { aal: 'aal2' } }] }));
  }
  assert.throws(() => f.accounts.rpc(f.ctx, f.logger, f.nk, JSON.stringify({ gatewaySecret: gateway, action: 'storage_write', id: owner,
    collection: 'bound_auth_sessions_v1', key: session, value: { aal: 'aal2', revoked: false } })));
});
