import test from 'node:test';
import assert from 'node:assert/strict';
import { createEmailChangeHandler, normalizedEmail } from './handler.mjs';

const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const session = '33333333-3333-4333-8333-333333333333';
const temporarySession = '44444444-4444-4444-8444-444444444444';
const operation = '55555555-5555-4555-8555-555555555555';
const origin = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
const oldEmail = 'before@example.invalid';
const newEmail = 'after@example.invalid';
const password = ' SecretCurrentPassword! ';
const jwt = (sub, session_id, aal) => ['eyJhbGciOiJIUzI1NiJ9', Buffer.from(JSON.stringify({ sub, session_id, aal })).toString('base64url'), 'test-signature'].join('.');
const nativeToken = jwt(owner, session);
const temporaryToken = jwt(owner, temporarySession);
const user = (email = oldEmail, id = owner) => ({ id, email, role: 'authenticated', is_anonymous: false, email_confirmed_at: '2026-01-01T00:00:00Z' });
const json = (body, status = 200) => new Response(JSON.stringify(body), { status });
const request = (body = { newEmail, currentPassword: password }, headers = {}) => new Request('https://edge.invalid/change-account-email', {
  method: 'POST', headers: { Authorization: `Bearer ${nativeToken}`, 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body),
});
function fixture(overrides = {}) {
  const calls = [];
  let userReads = 0;
  const handler = createEmailChangeHandler({ serviceKey: 'server-only-secret', publishableKey: 'public-key', fetchImpl: async (url, options) => {
    assert.equal(new URL(url).origin, origin);
    assert.equal(options.redirect, 'error'); assert.ok(options.signal instanceof AbortSignal);
    const body = options.body && JSON.parse(options.body);
    const call = { path: new URL(url).pathname + new URL(url).search, ...options, body };
    calls.push(call);
    if (call.path.startsWith('/rest/')) {
      assert.equal(options.headers.Authorization, 'Bearer server-only-secret');
      assert.equal(options.headers.apikey, 'server-only-secret');
      assert.equal(body.payload.owner, owner); assert.equal(body.payload.session, session);
      if (overrides.rpc) { const result = await overrides.rpc(body.action, body.payload); if (result) return result; }
      return json(body.action === 'begin' ? { ok: true, operation } : { ok: true });
    }
    if (call.path === '/auth/v1/user') {
      assert.equal(options.headers.Authorization, `Bearer ${overrides.nativeToken ?? nativeToken}`);
      assert.equal(options.headers.apikey, 'public-key');
      userReads++;
      return overrides.getUser?.(userReads) ?? json(user());
    }
    if (call.path.includes('/token?')) {
      assert.deepEqual(body, { email: overrides.currentEmail ?? oldEmail, password });
      assert.equal(options.headers.apikey, 'public-key');
      return overrides.password?.() ?? json({ access_token: temporaryToken, refresh_token: 'never-return-this', user: user() });
    }
    if (call.path === '/auth/v1/logout?scope=local') {
      assert.equal(options.headers.Authorization, `Bearer ${overrides.logoutToken ?? temporaryToken}`);
      assert.equal(options.headers.apikey, 'public-key');
      return overrides.logout?.() ?? new Response(null, { status: 204 });
    }
    if (call.path === '/auth/v1/admin/users/' + owner) {
      assert.equal(options.headers.Authorization, 'Bearer server-only-secret');
      assert.equal(options.headers.apikey, 'server-only-secret');
      if (options.method === 'PUT') {
        assert.deepEqual(body, { email: newEmail, email_confirm: true });
        return overrides.update?.() ?? json(user(newEmail));
      }
      return overrides.reconcile?.() ?? json(user(newEmail));
    }
    throw Error('unexpected network request');
  } });
  return { handler, calls };
}
const updated = calls => calls.filter(x => x.path.includes('/admin/') && x.method === 'PUT');

test('password proof derives current email and updates only bearer owner, confirming only the new email', async () => {
  const { handler, calls } = fixture();
  const response = await handler(request({ newEmail: ' After@Example.Invalid\n', currentPassword: password }));
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), { ok: true, email: newEmail });
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(calls.map(c => c.path.includes('/rest/') ? c.body.action : c.path), [
    '/auth/v1/user', 'begin', '/auth/v1/token?grant_type=password', '/auth/v1/logout?scope=local',
    '/auth/v1/user', 'validate', '/auth/v1/admin/users/' + owner, 'release',
  ]);
  assert.equal(updated(calls).length, 1);
  assert.ok(calls.every(c => !String(JSON.stringify(c.body)).includes('never-return-this')));
});

test('rejects caller-selected owner, confirmation flags, malformed email and missing password before network', async () => {
  for (const body of [
    { newEmail, currentPassword: password, owner: other }, { newEmail, currentPassword: password, email_confirm: true },
    { newEmail: 'bad-address', currentPassword: password }, { newEmail, currentPassword: '' },
    { newEmail, currentPassword: 'x'.repeat(1025) }, { newEmail, currentPassword: '\0' }, [], null,
  ]) {
    const { handler, calls } = fixture(); const response = await handler(request(body));
    assert.equal(response.status, 400); assert.equal(calls.length, 0);
  }
});

test('rejects browser origin, unauthenticated, method and content-type without network', async () => {
  for (const req of [request(undefined, { origin: 'https://attacker.invalid' }), request(undefined, { Authorization: 'bad' }),
    request(undefined, { 'Content-Type': 'text/plain' }), new Request('https://edge.invalid', { method: 'GET' })]) {
    const { handler, calls } = fixture(); const response = await handler(req);
    assert.ok([400, 401, 403, 405].includes(response.status)); assert.equal(calls.length, 0);
  }
});

test('limits raw body bytes and rejects malformed JSON', async () => {
  for (const body of ['{"newEmail":', ' '.repeat(8193)]) {
    const { handler, calls } = fixture();
    const req = new Request('https://edge.invalid', { method: 'POST', headers: { Authorization: `Bearer ${nativeToken}`, 'Content-Type': 'application/json' }, body });
    assert.equal((await handler(req)).status, 400); assert.equal(calls.length, 0);
  }
});

test('requires confirmed non-anonymous Auth user', async () => {
  for (const value of [{ ...user(), is_anonymous: true }, { ...user(), email_confirmed_at: null }, { ...user(), role: 'anon' }]) {
    const { handler, calls } = fixture({ getUser: () => json(value) });
    assert.equal((await handler(request())).status, 401); assert.equal(calls.length, 1);
  }
});

test('same-address retry reconciles only after password proof and repeated live checks, without admin write', async () => {
  const { handler, calls } = fixture({ currentEmail: newEmail, getUser: () => json(user(newEmail)),
    password: () => json({ access_token: temporaryToken, user: user(newEmail) }) });
  const response = await handler(request()); assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, email: newEmail });
  assert.equal(updated(calls).length, 0);
  assert.ok(calls.some(c => c.path.includes('/token?')));
  assert.ok(calls.some(c => c.body?.action === 'validate'));
  const denied = fixture({ currentEmail: newEmail, getUser: () => json(user(newEmail)),
    password: () => json({ error: 'invalid_credentials' }, 400) });
  assert.equal((await denied.handler(request())).status, 403);
});

test('MFA accounts require existing AAL2 and cannot use this admin path to bypass MFA', async () => {
  for (const read of [1, 2]) {
    const { handler, calls } = fixture({ getUser: n => json(n === read ? { ...user(), factors: [{ status: 'verified', factor_type: 'totp' }] } : user()) });
    const response = await handler(request()); assert.equal(response.status, 401); assert.equal(updated(calls).length, 0);
  }
  const proof = fixture({ password: () => json({ access_token: temporaryToken,
    user: { ...user(), factors: [{ status: 'verified', factor_type: 'totp' }] } }) });
  assert.equal((await proof.handler(request())).status, 401); assert.equal(updated(proof.calls).length, 0);
  const aal2 = jwt(owner, session, 'aal2');
  const allowed = fixture({ nativeToken: aal2,
    getUser: () => json({ ...user(), factors: [{ status: 'verified', factor_type: 'totp' }] }) });
  const accepted = await allowed.handler(request(undefined, { Authorization: `Bearer ${aal2}` }));
  assert.equal(accepted.status, 200); assert.equal(updated(allowed.calls).length, 1);
});

test('wrong password returns sanitized error and releases lease without admin update', async () => {
  const { handler, calls } = fixture({ password: () => json({ error: 'private upstream password details' }, 400) });
  const response = await handler(request()); assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { error: 'invalid_password' });
  assert.equal(updated(calls).length, 0); assert.equal(calls.at(-1).body.action, 'release');
  assert.ok(!calls.some(c => c.path.includes('logout')));
});

test('different password-grant user or email cannot mutate account and temporary session is revoked', async () => {
  for (const proofUser of [user(oldEmail, other), user('wrong@example.invalid')]) {
    const { handler, calls } = fixture({ password: () => json({ access_token: temporaryToken, user: proofUser }) });
    const response = await handler(request()); assert.equal(response.status, 403);
    assert.equal(updated(calls).length, 0); assert.equal(calls.filter(c => c.path.includes('logout')).length, 1);
  }
  const wrongOwnerToken = jwt(other, temporarySession);
  const mismatch = fixture({ logoutToken: wrongOwnerToken, password: () => json({ access_token: wrongOwnerToken, user: user(oldEmail, other) }) });
  assert.equal((await mismatch.handler(request())).status, 403); assert.equal(updated(mismatch.calls).length, 0);
  assert.equal(mismatch.calls.filter(c => c.path.includes('logout')).length, 1);
});

test('missing temporary session and reused native session never trigger dangerous global logout', async () => {
  for (const access_token of [jwt(owner, undefined), nativeToken]) {
    const { handler, calls } = fixture({ password: () => json({ access_token, user: user() }) });
    assert.equal((await handler(request())).status, 403);
    assert.equal(updated(calls).length, 0); assert.ok(!calls.some(c => c.path.includes('logout')));
  }
});

test('failed local logout blocks identity update and retries only temporary session cleanup', async () => {
  const { handler, calls } = fixture({ logout: () => json({ error: 'private' }, 503) });
  const response = await handler(request()); assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'unavailable' });
  assert.equal(updated(calls).length, 0); assert.equal(calls.filter(c => c.path.includes('logout')).length, 2);
});

test('rechecks actual owner and email after password proof', async () => {
  for (const changed of [user('changed@example.invalid'), user(oldEmail, other)]) {
    const { handler, calls } = fixture({ getUser: n => json(n === 1 ? user() : changed) });
    const response = await handler(request()); assert.equal(response.status, 409);
    assert.deepEqual(await response.json(), { error: 'account_changed' }); assert.equal(updated(calls).length, 0);
  }
});

test('revocation/deletion and lease/rate errors block password or update at database fence', async () => {
  for (const [action, error, status] of [['begin', 'unauthorized', 401], ['begin', 'rate_limited', 429],
    ['begin', 'change_in_progress', 409], ['validate', 'unauthorized', 401], ['validate', 'account_changed', 409]]) {
    const { handler, calls } = fixture({ rpc: phase => phase === action ? json({ error }) : undefined });
    const response = await handler(request()); assert.equal(response.status, status);
    assert.deepEqual(await response.json(), { error }); assert.equal(updated(calls).length, 0);
    if (action === 'begin') assert.ok(!calls.some(c => c.path.includes('/token?')));
  }
});

test('email collision is generic, does not enumerate or return upstream body', async () => {
  const { handler, calls } = fixture({ update: () => json({ code: 'email_exists', message: 'private existing account' }, 422) });
  const response = await handler(request()); assert.equal(response.status, 409);
  assert.deepEqual(await response.json(), { error: 'email_unavailable' });
  assert.equal(calls.filter(c => c.path.includes('/admin/') && c.method === 'GET').length, 0);
});

test('lost successful admin response is reconciled by administrative owner lookup after proof', async () => {
  const { handler, calls } = fixture({ update: () => { throw Error('network response lost'); } });
  const response = await handler(request()); assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, email: newEmail });
  assert.equal(calls.filter(c => c.path.includes('/admin/') && c.method === 'GET').length, 1);
});

test('never reports success unless exact owner/new email/confirmed response verified', async () => {
  for (const value of [user(), user(newEmail, other), { ...user(newEmail), email_confirmed_at: null }]) {
    const { handler } = fixture({ update: () => json(value) });
    const response = await handler(request()); assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { error: 'unavailable' });
  }
  const { handler } = fixture({ update: () => { throw Error('lost'); }, reconcile: () => json(user()) });
  assert.equal((await handler(request())).status, 503);
});

test('configuration fails closed and network/database errors are sanitized', async () => {
  assert.equal((await createEmailChangeHandler({})(request())).status, 503);
  for (const overrides of [{ getUser: () => { throw Error('secret'); } }, { rpc: () => json({ message: 'secret' }, 500) }]) {
    const { handler } = fixture(overrides); const response = await handler(request());
    assert.equal(response.status, 503); assert.deepEqual(await response.json(), { error: 'unavailable' });
  }
});

test('release failure after verified update cannot manufacture a failed identity change', async () => {
  const { handler } = fixture({ rpc: action => action === 'release' ? json({}, 503) : undefined });
  assert.equal((await handler(request())).status, 200);
});

test('email normalization preserves existing ASCII account convention', () => {
  assert.equal(normalizedEmail(' A@B.Invalid\r\n'), 'a@b.invalid');
  for (const value of [null, 'ü@example.invalid', 'a b@example.invalid', 'a@@b', 'x'.repeat(255)]) assert.equal(normalizedEmail(value), null);
});
