// Read claims only after Auth has verified this exact bearer. Accounts that
// opt in to MFA cannot use an AAL1 password session for privileged operations.
function permitsSecondFactor(user, authorization) {
  if (!Array.isArray(user?.factors) || !user.factors.some(f => f?.status === 'verified')) return true;
  try {
    const part = authorization.slice(7).split('.')[1];
    const claims = JSON.parse(atob(part.replaceAll('-', '+').replaceAll('_', '/')));
    return claims.sub === user.id && claims.aal === 'aal2';
  } catch { return false; }
}
const origin = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
const topic = 'com.evanvonessen.bound';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const requestIDPattern = uuid;
const tokenPattern = /^(?=.{32,512}$)(?:[a-f0-9]{2})+$/i;
const errorStatus = { invalid_request: 400, rate_limited: 429, friend_unavailable: 403, request_conflict: 409, not_configured: 503, unavailable: 503 };

const response = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});

async function boundedJSON(stream, limit = 8192) {
  if (!stream) throw Error('missing response body');
  const reader = stream.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw Error('response too large');
      chunks.push(value);
    }
  } finally {
    void reader.cancel().catch(() => {});
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}

async function boundedRequestJSON(request, limit = 2048) {
  const stream = request.body;
  if (!stream) throw Error('missing request body');
  const reader = stream.getReader();
  const chunks = [];
  let size = 0;
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => { void reader.cancel().catch(() => {}); reject(Error('request timeout')); }, 5000); });
  try {
    for (;;) {
      const { done, value } = await Promise.race([reader.read(), timeout]);
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw Error('request too large');
      chunks.push(value);
    }
  } finally {
    clearTimeout(timer);
    void reader.cancel().catch(() => {});
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}

function exactKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function b64url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/g, '');
}

function pemBytes(pem) {
  const normalized = pem.replaceAll('\\n', '\n').trim();
  const match = normalized.match(/^-----BEGIN PRIVATE KEY-----\s*([\s\S]+?)\s*-----END PRIVATE KEY-----$/);
  if (!match) throw Error('invalid APNs key');
  const encoded = match[1].replace(/\s/g, '');
  const binary = atob(encoded);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

/** Creates a cached ES256 provider. The JWT rotates after 30 minutes, below APNs' one-hour limit. */
export function createAPNsJWTProvider({ keyID, teamID, privateKey, cryptoImpl = globalThis.crypto, now = () => Math.floor(Date.now() / 1000) }) {
  if (!/^[A-Z0-9]{10}$/.test(keyID ?? '') || !/^[A-Z0-9]{10}$/.test(teamID ?? '') || typeof privateKey !== 'string') {
    throw Error('invalid APNs credentials');
  }
  const keyData = pemBytes(privateKey);
  let keyPromise;
  let cached;
  let cachedAt = 0;
  return async () => {
    const current = now();
    if (cached && current - cachedAt < 30 * 60) return cached;
    keyPromise ??= cryptoImpl.subtle.importKey('pkcs8', keyData, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const key = await keyPromise;
    const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: keyID })));
    const payload = b64url(new TextEncoder().encode(JSON.stringify({ iss: teamID, iat: current })));
    const signingInput = `${header}.${payload}`;
    const signature = new Uint8Array(await cryptoImpl.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(signingInput)));
    if (signature.byteLength !== 64) throw Error('invalid APNs signature');
    cached = `${signingInput}.${b64url(signature)}`;
    cachedAt = current;
    return cached;
  };
}

function validDispatch(value, sender) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  if (value.ok === false && typeof value.error === 'string' && Object.hasOwn(errorStatus, value.error)) {
    return { kind: 'error', error: value.error };
  }
  if (value.ok === true && value.duplicate === true && ['queued', 'sent', 'failed'].includes(value.status)) {
    return { kind: 'duplicate', status: value.status };
  }
  const username = typeof value.username === 'string' ? value.username.trim() : '';
  if (value.ok !== true || !uuid.test(value.jobID ?? '') || !uuid.test(value.recipientID ?? '') ||
      value.recipientID.toLowerCase() === sender.toLowerCase() || Array.from(username).length < 1 || Array.from(username).length > 40 ||
      /[\p{Cc}\p{Cf}]/u.test(username) || !Array.isArray(value.devices) || value.devices.length < 1 || value.devices.length > 5) return null;
  const devices = [];
  const seen = new Set();
  for (const device of value.devices) {
    if (!device || typeof device !== 'object' || !tokenPattern.test(device.token ?? '') ||
        !['sandbox', 'production'].includes(device.environment) || seen.has(device.token.toLowerCase())) return null;
    seen.add(device.token.toLowerCase());
    devices.push({ token: device.token.toLowerCase(), environment: device.environment });
  }
  return { kind: 'dispatch', jobID: value.jobID, recipientID: value.recipientID, username, devices };
}

async function responseReason(response) {
  try {
    const body = await boundedJSON(response.body, 4096);
    return typeof body?.reason === 'string' ? body.reason : '';
  } catch { return ''; }
}

function otherEnvironment(environment) { return environment === 'sandbox' ? 'production' : 'sandbox'; }

async function sendToAPNs({ device, payload, jwtProviders, fetchImpl, now, timeoutMs }) {
  const send = async environment => {
    try {
      const jwt = jwtProviders[environment];
      if (!jwt) return { response: null, reason: '', configured: false };
      const authorization = await jwt();
      const host = environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
      const result = await fetchImpl(`https://${host}/3/device/${device.token}`, {
        method: 'POST',
        headers: {
          authorization: `bearer ${authorization}`,
          'apns-topic': topic,
          'apns-push-type': 'alert',
          'apns-priority': '10',
          'apns-expiration': String(now() + 60),
          'content-type': 'application/json',
        },
        body: JSON.stringify(payload),
        redirect: 'error',
        signal: AbortSignal.timeout(timeoutMs),
      });
      return { response: result, reason: result.ok ? '' : await responseReason(result), configured: true };
    } catch { return { response: null, reason: '', configured: Boolean(jwtProviders[environment]) }; }
  };

  let result = await send(device.environment);
  if (result.response?.status === 200) return 'delivered';
  if (!result.configured) return 'not_configured';
  if (result.response?.status === 410) return 'invalid';
  if (result.response?.status === 400 && result.reason === 'BadDeviceToken') {
    // A topic-scoped APNs key may be authorized for only one environment.
    // Without an alternate-environment key, retain the token instead of
    // treating a BadDeviceToken response as proof that the token is invalid.
    if (!jwtProviders[otherEnvironment(device.environment)]) return 'failed';
    result = await send(otherEnvironment(device.environment));
    if (result.response?.status === 200) return 'delivered';
    if (result.response?.status === 410 || (result.response?.status === 400 && result.reason === 'BadDeviceToken')) return 'invalid';
  }
  return 'failed';
}

export function createJiggleHandler({ publishableKey, serviceRoleKey, apnsKeyID, apnsTeamID, apnsPrivateKey,
  apnsSandboxKeyID, apnsSandboxTeamID, apnsSandboxPrivateKey,
  apnsProductionKeyID, apnsProductionTeamID, apnsProductionPrivateKey,
  fetchImpl = fetch, cryptoImpl = globalThis.crypto, now = () => Math.floor(Date.now() / 1000), requestTimeoutMs = 5000 }) {
  if (!publishableKey || !serviceRoleKey) throw Error('invalid Supabase configuration');
  const genericCredentials = { keyID: apnsKeyID, teamID: apnsTeamID, privateKey: apnsPrivateKey };
  const environmentCredentials = {
    sandbox: { keyID: apnsSandboxKeyID, teamID: apnsSandboxTeamID, privateKey: apnsSandboxPrivateKey },
    production: { keyID: apnsProductionKeyID, teamID: apnsProductionTeamID, privateKey: apnsProductionPrivateKey },
  };
  const jwtProviders = {};
  const environmentConfigured = { sandbox: false, production: false };
  for (const environment of ['sandbox', 'production']) {
    const specific = environmentCredentials[environment];
    const hasSpecificValue = Object.values(specific).some(value => typeof value === 'string' && value.trim().length > 0);
    const selected = hasSpecificValue ? specific : genericCredentials;
    if (!hasSpecificValue && Object.values(genericCredentials).some(value => typeof value !== 'string' || !value.trim())) continue;
    // Partial environment-specific config is an explicit disabled environment,
    // not a signal to fall back to credentials scoped for something else.
    if (hasSpecificValue && Object.values(specific).some(value => typeof value !== 'string' || !value.trim())) continue;
    try {
      jwtProviders[environment] = createAPNsJWTProvider({ ...selected, cryptoImpl, now });
      environmentConfigured[environment] = true;
    } catch { /* Treat malformed environment credentials as unconfigured. */ }
  }
  const apnsConfigured = environmentConfigured.sandbox || environmentConfigured.production;

  const rpc = async (name, args, parseResponse = true) => {
    const result = await fetchImpl(`${origin}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: { authorization: `Bearer ${serviceRoleKey}`, apikey: serviceRoleKey, 'content-type': 'application/json' },
      body: JSON.stringify(args), redirect: 'error', signal: AbortSignal.timeout(requestTimeoutMs),
    });
    if (!result.ok) throw Error('rpc unavailable');
    if (!parseResponse) { void result.body?.cancel().catch(() => {}); return null; }
    return await boundedJSON(result.body, 16384);
  };

  return async request => {
    if (request.method !== 'POST') return response(405, { ok: false, error: 'method_not_allowed' });
    if (request.headers.has('origin')) return response(403, { ok: false, error: 'forbidden' });
    if (request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json') {
      return response(400, { ok: false, error: 'invalid_request' });
    }
    const authorization = request.headers.get('authorization') ?? '';
    if (!/^Bearer [A-Za-z0-9._~-]{16,16384}$/.test(authorization)) return response(401, { ok: false, error: 'unauthorized' });

    let body;
    try { body = await boundedRequestJSON(request); }
    catch { return response(400, { ok: false, error: 'invalid_request' }); }
    const isStatus = exactKeys(body, ['operation']) && body.operation === 'status';
    const isDispatch = exactKeys(body, ['roomID', 'requestID']) && uuid.test(body.roomID ?? '') && requestIDPattern.test(body.requestID ?? '');
    if (!isStatus && !isDispatch) return response(400, { ok: false, error: 'invalid_request' });

    let user;
    try {
      const auth = await fetchImpl(`${origin}/auth/v1/user`, {
        headers: { authorization, apikey: publishableKey }, redirect: 'error', signal: AbortSignal.timeout(requestTimeoutMs),
      });
      if (auth.status === 401 || auth.status === 403) return response(401, { ok: false, error: 'unauthorized' });
      if (!auth.ok) return response(503, { ok: false, error: 'identity_unavailable' });
      user = await boundedJSON(auth.body, 65536);
    } catch { return response(503, { ok: false, error: 'identity_unavailable' }); }
    if (!uuid.test(user?.id ?? '') || user.is_anonymous !== false || user.role !== 'authenticated') {
      return response(403, { ok: false, error: 'forbidden' });
    }

    if (!permitsSecondFactor(user, authorization)) return response(403, { ok: false, error: 'second_factor_required' });

    if (isStatus) return response(200, { ok: true, configured: apnsConfigured, environments: environmentConfigured });
    if (!apnsConfigured) return response(503, { ok: false, error: 'not_configured' });

    let raw;
    try { raw = await rpc('bound_jiggle_dispatch', { sender: user.id, room: body.roomID, request: body.requestID }); }
    catch { return response(503, { ok: false, error: 'unavailable' }); }
    const dispatch = validDispatch(raw, user.id);
    if (!dispatch) return response(503, { ok: false, error: 'unavailable' });
    if (dispatch.kind === 'error') return response(errorStatus[dispatch.error], { ok: false, error: dispatch.error });
    if (dispatch.kind === 'duplicate') return response(200, { ok: true, duplicate: true, status: dispatch.status });

    const payload = {
      aps: { alert: { title: 'Bound', body: `${dispatch.username} wants to play.` }, sound: 'default', category: 'BOUND_JIGGLE' },
      kind: 'bound-jiggle', recipientID: dispatch.recipientID, roomID: body.roomID.toLowerCase(),
    };
    const results = await Promise.all(dispatch.devices.map(device => sendToAPNs({ device, payload, jwtProviders, fetchImpl, now, timeoutMs: requestTimeoutMs })));
    const invalidTokens = [...new Set(dispatch.devices.filter((_, index) => results[index] === 'invalid').map(device => device.token))];
    const delivered = results.some(result => result === 'delivered');
    const missingEnvironmentKey = results.includes('not_configured');
    try { await rpc('bound_jiggle_finish', { job: dispatch.jobID, delivered, invalid_tokens: invalidTokens }, false); }
    catch { return response(503, { ok: false, error: 'unavailable' }); }
    // Do not report the request as fully sent when one registered environment
    // could not be attempted, even if another device accepted the alert.
    if (missingEnvironmentKey) return response(503, { ok: false, error: 'not_configured' });
    if (!delivered) return response(200, { ok: true, status: 'failed' });
    return response(200, { ok: true, status: 'sent' });
  };
}
