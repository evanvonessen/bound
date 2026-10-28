import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { createAPNsJWTProvider, createJiggleHandler } from './handler.mjs';

const sender = '11111111-1111-4111-8111-111111111111';
const recipient = '22222222-2222-4222-8222-222222222222';
const room = '33333333-3333-4333-8333-333333333333';
const requestID = '44444444-4444-4444-8444-444444444444';
const job = '55555555-5555-4555-8555-555555555555';
const token = 'a'.repeat(64);
const identity = { id: sender, role: 'authenticated', is_anonymous: false };
const json = (body, status = 200) => new Response(JSON.stringify(body), { status });

async function keyFixture() {
  const pair = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await webcrypto.subtle.exportKey('pkcs8', pair.privateKey));
  let binary = '';
  for (const byte of der) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).match(/.{1,64}/g).join('\n');
  return `-----BEGIN PRIVATE KEY-----\n${encoded}\n-----END PRIVATE KEY-----`;
}

async function fixture({ dispatch, auth = identity, authStatus = 200, apns = () => new Response(null, { status: 200 }), configured = true, apnsCredentials } = {}) {
  const calls = [];
  const privateKey = configured ? await keyFixture() : undefined;
  const handler = createJiggleHandler({
    publishableKey: 'synthetic-public-key', serviceRoleKey: 'synthetic-server-key',
    ...(configured ? { apnsKeyID: 'ABCDEFGHIJ', apnsTeamID: 'KLMNOPQRST', apnsPrivateKey: privateKey } : {}),
    ...apnsCredentials, cryptoImpl: webcrypto, now: () => 1_800_000_000,
    fetchImpl: async (url, options = {}) => {
      const body = options.body ? JSON.parse(options.body) : undefined;
      calls.push({ url: String(url), options, body });
      if (String(url).endsWith('/auth/v1/user')) return json(auth, authStatus);
      if (String(url).endsWith('/rest/v1/rpc/bound_game_notification_dispatch')) return json(dispatch ?? {
        ok: true, jobID: job, username: 'River', recipientID: recipient,
        devices: [{ token, environment: 'sandbox' }],
      });
      if (String(url).endsWith('/rest/v1/rpc/bound_jiggle_finish')) return new Response(null, { status: 204 });
      if (String(url).includes('.push.apple.com/3/device/')) return apns(String(url), options, calls);
      throw Error(`unexpected endpoint: ${url}`);
    },
  });
  const request = (body, headers = {}) => handler(new Request('https://function.invalid/jiggle', {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer synthetic.valid.session', ...headers },
    body: JSON.stringify(body),
  }));
  return { calls, handler, request };
}

test('APNs ES256 JWT is cached and renewed before its one-hour limit', async () => {
  const provider = createAPNsJWTProvider({ keyID: 'ABCDEFGHIJ', teamID: 'KLMNOPQRST', privateKey: await keyFixture(), cryptoImpl: webcrypto, now: () => clock });
  let clock = 1_800_000_000;
  const first = await provider();
  assert.equal(await provider(), first);
  clock += 30 * 60;
  const renewed = await provider();
  assert.notEqual(renewed, first);
  assert.deepEqual(JSON.parse(Buffer.from(renewed.split('.')[0], 'base64url').toString()), { alg: 'ES256', kid: 'ABCDEFGHIJ' });
  assert.equal(JSON.parse(Buffer.from(renewed.split('.')[1], 'base64url').toString()).iss, 'KLMNOPQRST');
});

test('verified identity dispatches only RPC-owned recipient data and sends bounded native alert', async () => {
  const f = await fixture();
  const result = await f.request({ roomID: room, requestID });
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { ok: true, status: 'sent' });
  const dispatch = f.calls.find(call => call.url.endsWith('/bound_game_notification_dispatch'));
  assert.deepEqual(dispatch.body, { sender, room, request: requestID, kind: 'bound-jiggle', run: null, installation: null });
  assert.equal(dispatch.options.headers.apikey, 'synthetic-server-key');
  const push = f.calls.find(call => call.url.includes('.push.apple.com/'));
  assert.equal(push.url, `https://api.sandbox.push.apple.com/3/device/${token}`);
  assert.equal(push.options.headers['apns-topic'], 'com.evanvonessen.bound');
  assert.equal(push.options.headers['apns-expiration'], '1800000060');
  assert.deepEqual(JSON.parse(push.options.body), {
    aps: { alert: { title: 'Bound', body: 'River wants to play Pokémon!' }, sound: 'default', category: 'BOUND_JIGGLE' },
    kind: 'bound-jiggle', recipientID: recipient, roomID: room,
  });
  const finish = f.calls.find(call => call.url.endsWith('/bound_jiggle_finish'));
  assert.deepEqual(finish.body, { job, delivered: true, invalid_tokens: [] });
});

test('shared join, server start and game invitation use server-authenticated context and distinct native alerts', async () => {
  const run = '66666666-6666-4666-8666-666666666666';
  const installation = '77777777-7777-4777-8777-777777777777';
  for (const [kind, message] of [['shared-join','joined your shared game.'], ['shared-start','started a shared server.'], ['shared-invite','invited you to a shared game.']]) {
    const f=await fixture();
    assert.equal((await f.request({roomID:room,requestID,runID:run,installationID:installation,kind})).status,200);
    assert.deepEqual(f.calls.find(call=>call.url.endsWith('/bound_game_notification_dispatch')).body,
      {sender,room,request:requestID,run,installation,kind});
    const push=f.calls.find(call=>call.url.includes('.push.apple.com/'));
    assert.equal(push.body.aps.alert.body,'River '+message);
    assert.equal(push.body.kind,kind); assert.equal(push.body.runID,run);
  }
});

test('suppressed child preference produces no APNs request', async () => {
  const f=await fixture({dispatch:{ok:true,duplicate:true,status:'suppressed'}});
  assert.deepEqual(await (await f.request({roomID:room,requestID})).json(),{ok:true,duplicate:true,status:'suppressed'});
  assert.equal(f.calls.some(call=>call.url.includes('.push.apple.com/')),false);
});

test('production-only credentials sign pushes to production devices', async () => {
  const f = await fixture({ configured: false, apnsCredentials: {
    apnsProductionKeyID: 'PRODKEY123', apnsProductionTeamID: 'KLMNOPQRST', apnsProductionPrivateKey: await keyFixture(),
  }, dispatch: {
    ok: true, jobID: job, username: 'River', recipientID: recipient,
    devices: [{ token, environment: 'production' }],
  } });
  const result = await f.request({ roomID: room, requestID });
  assert.deepEqual(await result.json(), { ok: true, status: 'sent' });
  const push = f.calls.find(call => call.url.includes('.push.apple.com/'));
  assert.equal(push.url, `https://api.push.apple.com/3/device/${token}`);
  const jwt = push.options.headers.authorization.slice('bearer '.length);
  assert.equal(JSON.parse(Buffer.from(jwt.split('.')[0], 'base64url').toString()).kid, 'PRODKEY123');
});

test('sandbox-only credentials sign pushes to sandbox devices', async () => {
  const f = await fixture({ configured: false, apnsCredentials: {
    apnsSandboxKeyID: 'SANDKEY123', apnsSandboxTeamID: 'KLMNOPQRST', apnsSandboxPrivateKey: await keyFixture(),
  } });
  const result = await f.request({ roomID: room, requestID });
  assert.deepEqual(await result.json(), { ok: true, status: 'sent' });
  const push = f.calls.find(call => call.url.includes('.push.apple.com/'));
  assert.equal(push.url, `https://api.sandbox.push.apple.com/3/device/${token}`);
  const jwt = push.options.headers.authorization.slice('bearer '.length);
  assert.equal(JSON.parse(Buffer.from(jwt.split('.')[0], 'base64url').toString()).kid, 'SANDKEY123');
});

test('a partial environment tuple is not treated as configured or replaced by the generic fallback', async () => {
  const f = await fixture({ configured: true, apnsCredentials: {
    apnsProductionKeyID: 'PRODKEY123', apnsProductionTeamID: 'KLMNOPQRST',
  }, dispatch: {
    ok: true, jobID: job, username: 'River', recipientID: recipient,
    devices: [{ token, environment: 'production' }],
  } });
  const status = await f.request({ operation: 'status' });
  assert.deepEqual(await status.json(), {
    ok: true, configured: true, environments: { sandbox: true, production: false },
  });
  const result = await f.request({ roomID: room, requestID }, {
    // Test the env that is intentionally partial.
  });
  assert.equal(result.status, 503);
  assert.deepEqual(await result.json(), { ok: false, error: 'not_configured' });
  assert.equal(f.calls.some(call => call.url.includes('.push.apple.com/')), false);
  const finish = f.calls.find(call => call.url.endsWith('/bound_jiggle_finish'));
  assert.deepEqual(finish.body, { job, delivered: false, invalid_tokens: [] });
});

test('a sandbox-only key does not send a production token or claim success', async () => {
  const f = await fixture({ configured: false, apnsCredentials: {
    apnsSandboxKeyID: 'SANDKEY123', apnsSandboxTeamID: 'KLMNOPQRST', apnsSandboxPrivateKey: await keyFixture(),
  }, dispatch: {
    ok: true, jobID: job, username: 'River', recipientID: recipient,
    devices: [{ token, environment: 'production' }],
  } });
  const result = await f.request({ roomID: room, requestID });
  assert.equal(result.status, 503);
  assert.deepEqual(await result.json(), { ok: false, error: 'not_configured' });
  assert.equal(f.calls.some(call => call.url.includes('.push.apple.com/')), false);
  assert.deepEqual(f.calls.find(call => call.url.endsWith('/bound_jiggle_finish')).body,
    { job, delivered: false, invalid_tokens: [] });
});

test('a missing environment key is reported even when another device accepts the alert', async () => {
  const f = await fixture({ configured: false, apnsCredentials: {
    apnsSandboxKeyID: 'SANDKEY123', apnsSandboxTeamID: 'KLMNOPQRST', apnsSandboxPrivateKey: await keyFixture(),
  }, dispatch: {
    ok: true, jobID: job, username: 'River', recipientID: recipient,
    devices: [
      { token, environment: 'sandbox' },
      { token: 'b'.repeat(64), environment: 'production' },
    ],
  } });
  const result = await f.request({ roomID: room, requestID });
  assert.equal(result.status, 503);
  assert.deepEqual(await result.json(), { ok: false, error: 'not_configured' });
  assert.equal(f.calls.filter(call => call.url.includes('.push.apple.com/')).length, 1);
  assert.deepEqual(f.calls.find(call => call.url.endsWith('/bound_jiggle_finish')).body,
    { job, delivered: true, invalid_tokens: [] });
});

test('BadDeviceToken does not cross environments when the alternate key is missing', async () => {
  const f = await fixture({ configured: false, apnsCredentials: {
    apnsSandboxKeyID: 'SANDKEY123', apnsSandboxTeamID: 'KLMNOPQRST', apnsSandboxPrivateKey: await keyFixture(),
  }, apns: () => new Response(JSON.stringify({ reason: 'BadDeviceToken' }), { status: 400 }) });
  const result = await f.request({ roomID: room, requestID });
  assert.deepEqual(await result.json(), { ok: true, status: 'failed' });
  assert.deepEqual(f.calls.filter(call => call.url.includes('.push.apple.com/')).map(call => call.url), [
    `https://api.sandbox.push.apple.com/3/device/${token}`,
  ]);
  assert.deepEqual(f.calls.find(call => call.url.endsWith('/bound_jiggle_finish')).body,
    { job, delivered: false, invalid_tokens: [] });
});

test('dispatch accepts a 40-codepoint username made of astral Unicode characters', async () => {
  const username = '😀'.repeat(40);
  const f = await fixture({ dispatch: {
    ok: true, jobID: job, username, recipientID: recipient,
    devices: [{ token, environment: 'sandbox' }],
  } });
  const result = await f.request({ roomID: room, requestID });
  assert.deepEqual(await result.json(), { ok: true, status: 'sent' });
  const push = f.calls.find(call => call.url.includes('.push.apple.com/'));
  assert.equal(JSON.parse(push.options.body).aps.alert.body, `${username} wants to play Pokémon!`);
});

test('strict request shape and server-verified nonanonymous identity block spoofed calls', async () => {
  const f = await fixture();
  for (const body of [
    { roomID: room, requestID, sender: recipient }, { operation: 'status', sender },
    { roomID: 'not-a-uuid', requestID }, { roomID: room, requestID, username: 'spoofed' },
  ]) assert.equal((await f.request(body)).status, 400);
  assert.equal(f.calls.length, 0);
  assert.equal((await f.request({ roomID: room, requestID }, { origin: 'https://evil.invalid' })).status, 403);
  assert.equal(f.calls.length, 0);
  const anonymous = await fixture({ auth: { ...identity, is_anonymous: true } });
  assert.equal((await anonymous.request({ roomID: room, requestID })).status, 403);
  assert.equal(anonymous.calls.length, 1);
});

test('duplicate request does not send again and reports SQL status', async () => {
  const f = await fixture({ dispatch: { ok: true, duplicate: true, status: 'queued' } });
  assert.deepEqual(await (await f.request({ roomID: room, requestID })).json(), { ok: true, duplicate: true, status: 'queued' });
  assert.equal(f.calls.some(call => call.url.includes('.push.apple.com/')), false);
  assert.equal(f.calls.some(call => call.url.endsWith('/bound_jiggle_finish')), false);
});

test('revoked identity and SQL rate limit are returned without sending a push', async () => {
  const revoked = await fixture({ authStatus: 401 });
  assert.deepEqual(await (await revoked.request({ roomID: room, requestID })).json(), { ok: false, error: 'unauthorized' });
  assert.equal(revoked.calls.length, 1);

  const limited = await fixture({ dispatch: { ok: false, error: 'rate_limited' } });
  const result = await limited.request({ roomID: room, requestID });
  assert.equal(result.status, 429);
  assert.deepEqual(await result.json(), { ok: false, error: 'rate_limited' });
  assert.equal(limited.calls.some(call => call.url.includes('.push.apple.com/')), false);
});

test('BadDeviceToken retries the alternate environment; invalid token is purged only after both reject it', async () => {
  const callsByHost = [];
  const f = await fixture({ apns: url => {
    callsByHost.push(url);
    return new Response(JSON.stringify({ reason: 'BadDeviceToken' }), { status: 400 });
  } });
  const result = await f.request({ roomID: room, requestID });
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { ok: true, status: 'failed' });
  assert.deepEqual(callsByHost, [
    `https://api.sandbox.push.apple.com/3/device/${token}`,
    `https://api.push.apple.com/3/device/${token}`,
  ]);
  const finish = f.calls.find(call => call.url.endsWith('/bound_jiggle_finish'));
  assert.deepEqual(finish.body, { job, delivered: false, invalid_tokens: [token] });
});

test('410 purges an expired token, while transient APNs errors remain registered', async () => {
  const expired = await fixture({ apns: () => new Response(null, { status: 410 }) });
  await expired.request({ roomID: room, requestID });
  assert.deepEqual(expired.calls.find(call => call.url.endsWith('/bound_jiggle_finish')).body,
    { job, delivered: false, invalid_tokens: [token] });

  const transient = await fixture({ apns: () => new Response(null, { status: 500 }) });
  const result = await transient.request({ roomID: room, requestID });
  assert.deepEqual(await result.json(), { ok: true, status: 'failed' });
  assert.deepEqual(transient.calls.find(call => call.url.endsWith('/bound_jiggle_finish')).body,
    { job, delivered: false, invalid_tokens: [] });
});

test('invalid APNs configuration is observable as unavailable without exposing secrets', async () => {
  const f = await fixture({ configured: false });
  const status = await f.request({ operation: 'status' });
  assert.deepEqual(await status.json(), { ok: true, configured: false, environments: { sandbox: false, production: false } });
  const result = await f.request({ roomID: room, requestID });
  assert.equal(result.status, 503);
  assert.deepEqual(await result.json(), { ok: false, error: 'not_configured' });
  assert.equal(f.calls.some(call => call.url.endsWith('/bound_game_notification_dispatch')), false);
});


test('MFA enrolled users cannot dispatch or inspect configuration with AAL1', async () => {
  const f = await fixture({auth:{...identity,factors:[{status:'verified',factor_type:'totp'}]}});
  for (const body of [{operation:'status'},{roomID:room,requestID}]) {
    assert.equal((await f.request(body)).status,403);
  }
  assert.ok(f.calls.every(call=>call.url.endsWith('/auth/v1/user')));
});

test('MFA enrolled AAL2 caller retains Jiggle dispatch',async()=>{
  const f=await fixture({auth:{...identity,factors:[{status:'verified',factor_type:'totp'}]}});
  const token=`header.${Buffer.from(JSON.stringify({sub:sender,aal:'aal2'})).toString('base64url')}.signature`;
  assert.equal((await f.request({roomID:room,requestID},{authorization:`Bearer ${token}`})).status,200);
  assert.ok(f.calls.some(call=>call.url.endsWith('/bound_game_notification_dispatch')));
});
