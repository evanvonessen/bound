import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createAuth, totp } from '../auth.mjs';
const owner = '11111111-1111-4111-8111-111111111111';
function fixture() {
  const account = { id: owner, email: 'player@example.com', email_confirmed_at: '2026-01-01T00:00:00Z', user_metadata: { bound_username_v1: 'Player' } };
  const records = new Map(), tokens = new Set(), sent = [], changed = []; let version = 0;
  const clone = object => JSON.parse(JSON.stringify(object));
  const jwt = payload => Buffer.from('{}').toString('base64url') + '.' + Buffer.from(JSON.stringify(payload)).toString('base64url') + '.signature';
  const native = (id, sessionID, aal) => {
    const vars = { session_id: sessionID, aal, email: account.email, nonce: randomUUID() }, exp = Math.floor(Date.now() / 1000) + 3600;
    const token = jwt({ uid: id, vrs: vars, exp }), refresh_token = jwt({ uid: id, vrs: vars, exp: exp + 86400 }); tokens.add(token); return { token, refresh_token };
  };
  const nk = {
    account: async id => { assert.equal(id, owner); return clone(account); },
    lookup: async email => email === account.email ? clone(account) : null,
    password: async (email, password) => { if (email !== account.email || password !== 'password123') throw Error('invalid'); return clone(account); },
    session: async (...args) => native(...args),
    refresh: async (token, sessionID, aal) => native(owner, sessionID, aal),
    validate: async token => { if (!tokens.has(token)) throw Error('bad signature'); return { user: { id: owner } }; },
    read: async (id, collection, key) => clone(records.get([id, collection, key].join('/')) ?? null),
    write: async (id, collection, key, value, expected = '*') => {
      const k = [id, collection, key].join('/'), existing = records.get(k);
      if (expected === '*' ? existing : existing?.version !== expected) throw Error('CAS conflict');
      const record = { key, value: clone(value), version: String(++version) }; records.set(k, record); return clone(record);
    },
    list: async (id, collection) => [...records].filter(([key]) => key.startsWith(id + '/' + collection + '/')).map(([, value]) => clone(value)),
    remove: async (id, collection, key, expected) => { const k = [id, collection, key].join('/'); assert.equal(records.get(k).version, expected); records.delete(k); },
    logout: async (id, token) => { if (token) tokens.delete(token); else tokens.clear(); },
    updatePassword: async (id, password) => changed.push({ id, password }),
    updateEmail: async (id, email) => { account.email = email; changed.push({ id, email }); },
    confirm: async () => { account.email_confirmed_at = new Date().toISOString(); },
    deleteAccount: async id => changed.push({ deleted: id }),
  };
  const config = { BOUND_AUTH_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64'), BOUND_PUBLIC_URL: 'https://accounts.example.com', RESEND_API_KEY: 'synthetic', RESEND_FROM: 'Bound <bound@example.com>' };
  const auth = createAuth({ nakama: nk, config, fetchImpl: async (url, options) => { sent.push(JSON.parse(options.body)); return new Response('{}'); } });
  const request = (path, data, token, method) => new Request(config.BOUND_PUBLIC_URL + path, { method: method ?? (data ? 'POST' : 'GET'), headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, ...(data ? { body: JSON.stringify(data) } : {}) });
  const call = async (path, data, token, method) => { const response = await auth.handle(request(path, data, token, method)); return { status: response.status, body: await response.json() }; };
  const login = async () => { const result = await call('/auth/v1/token?grant_type=password', { email: account.email, password: 'password123' }); assert.equal(result.status, 200); return result.body; };
  return { auth, request, call, login, records, tokens, account, changed, sent };
}

test('native Nakama sessions preserve UUID and refresh rejects replay, then logout revokes', async () => {
  const f = fixture(), first = await f.login();
  const identity = await f.auth.authenticate(f.request('/rpc', null, first.access_token)); assert.equal(identity.id, owner); assert.equal(identity.claims.sub, owner);
  const refreshed = await f.call('/auth/v1/token?grant_type=refresh_token', { refresh_token: first.refresh_token }); assert.equal(refreshed.status, 200);
  assert.equal((await f.call('/auth/v1/token?grant_type=refresh_token', { refresh_token: first.refresh_token })).status, 401);
  await assert.rejects(f.auth.authenticate(f.request('/rpc', null, first.access_token)));
  assert.equal((await f.call('/auth/v1/logout', {}, refreshed.body.access_token)).status, 200);
  await assert.rejects(f.auth.authenticate(f.request('/rpc', null, refreshed.body.access_token)));
});

test('TOTP enrollment, required second factor, encrypted secret and replay protection', async () => {
  const f = fixture(), session = await f.login();
  const enrollment = await f.call('/auth/v1/factors', { factor_type: 'totp', friendly_name: 'Phone' }, session.access_token); assert.equal(enrollment.status, 200);
  const factor = enrollment.body.id, secret = enrollment.body.totp.secret;
  assert.ok(!JSON.stringify([...f.records.values()]).includes(secret));
  const challenge = await f.call('/auth/v1/factors/' + factor + '/challenge', {}, session.access_token);
  const step = Math.floor(Date.now() / 30000), code = totp(secret, step);
  const verified = await f.call('/auth/v1/factors/' + factor + '/verify', { challenge_id: challenge.body.id, code }, session.access_token); assert.equal(verified.status, 200);
  assert.equal((await f.auth.authenticate(f.request('/rpc', null, verified.body.access_token))).aal, 'aal2');
  const signin = await f.login(); await assert.rejects(f.auth.authenticate(f.request('/rpc', null, signin.access_token)), /mfa_required/);
  assert.equal((await f.call('/auth/v1/factors', { factor_type: 'totp' }, signin.access_token)).status, 403);
  const next = await f.call('/auth/v1/factors/' + factor + '/challenge', {}, signin.access_token);
  assert.equal((await f.call('/auth/v1/factors/' + factor + '/verify', { challenge_id: next.body.id, code }, signin.access_token)).status, 400);
});

test('recovery capability is one use, mailbox bound and cannot authorize service access', async () => {
  const f = fixture();
  assert.equal((await f.call('/auth/v1/recover', { email: f.account.email })).status, 200);
  const link = /https:\/\/\S+/.exec(f.sent[0].text)[0], token = new URLSearchParams(new URL(link).hash.slice(1)).get('token');
  const verified = await f.call('/auth/v1/verify', { token, type: 'recovery' }); assert.equal(verified.status, 200);
  await assert.rejects(f.auth.authenticate(f.request('/rpc', null, verified.body.access_token)), /recovery_session/);
  assert.equal((await f.call('/auth/v1/verify', { token, type: 'recovery' })).status, 400);
  assert.equal((await f.call('/auth/v1/user', { password: 'replacement123' }, verified.body.access_token, 'PUT')).status, 200);
  assert.deepEqual(f.changed, [{ id: owner, password: 'replacement123' }]);
  assert.equal((await f.call('/auth/v1/user', null, verified.body.access_token)).status, 503);
});

test('email change requires correct current password, preserves owner and revokes sessions', async () => {
  const f = fixture(), session = await f.login();
  assert.equal((await f.call('/functions/v1/change-account-email', { currentPassword: 'wrong', newEmail: 'new@example.com' }, session.access_token)).status, 403);
  assert.equal(f.changed.length, 0);
  const result = await f.call('/functions/v1/change-account-email', { currentPassword: 'password123', newEmail: 'new@example.com' }, session.access_token);
  assert.equal(result.status, 200); assert.deepEqual(result.body, { ok: true, email: 'new@example.com' }); assert.equal(f.changed[0].id, owner);
  await assert.rejects(f.auth.authenticate(f.request('/rpc', null, session.access_token)));
});

test('unconfirmed accounts and forged native bearer fail closed', async () => {
  const f = fixture(); f.account.email_confirmed_at = null;
  assert.equal((await f.call('/auth/v1/token?grant_type=password', { email: f.account.email, password: 'password123' })).status, 400);
  await assert.rejects(f.auth.authenticate(f.request('/rpc', null, 'forged.token.value')));
});

test('TOTP RFC 6238 known SHA1 value and email form do not auto-consume proof', async () => {
  assert.equal(totp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 1), '287082');
  const f = fixture(), response = await f.auth.handle(new Request('https://accounts.example.com/auth/confirm'));
  assert.equal(response.status, 200); assert.match(response.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  const html = await response.text(); assert.match(html, /addEventListener\('submit'/); assert.ok(!html.includes('supabase'));
});
