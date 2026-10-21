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
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const reply = (status, body) => new Response(JSON.stringify(body), { status,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
const exact = (v, keys) => v && typeof v === 'object' && !Array.isArray(v) &&
  Object.keys(v).sort().join(',') === [...keys].sort().join(',');
const b64 = bytes => btoa(String.fromCharCode(...bytes));
const unb64 = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));
async function json(stream, limit = 32768) {
  if (!stream) throw Error('body');
  const reader = stream.getReader(); const chunks = []; let size = 0; let timer;
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => {
    void reader.cancel().catch(() => {}); reject(Error('deadline'));
  }, 10000); });
  try {
    for (;;) {
      const { done, value } = await Promise.race([reader.read(), deadline]);
      if (done) break;
      size += value.length; if (size > limit) throw Error('body'); chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } finally { clearTimeout(timer); void reader.cancel().catch(() => {}); }
}

// AES-256-GCM uses an independent server-only key. The owner and Dropbox app
// identity are authenticated, so copying ciphertext to another owner fails closed.
export function createGrantCipher(keyBase64, appKey, cryptoImpl = globalThis.crypto) {
  const bytes = unb64(keyBase64);
  if (bytes.length !== 32) throw Error('configuration');
  const key = cryptoImpl.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
  const aad = owner => new TextEncoder().encode(`bound-dropbox:v1:${appKey}:${owner}`);
  return {
    async seal(owner, token) {
      const iv = cryptoImpl.getRandomValues(new Uint8Array(12));
      const data = await cryptoImpl.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad(owner) },
        await key, new TextEncoder().encode(token));
      return JSON.stringify({ v: 1, iv: b64(iv), data: b64(new Uint8Array(data)) });
    },
    async open(owner, value) {
      const envelope = JSON.parse(value);
      if (envelope.v !== 1) throw Error('ciphertext');
      const data = await cryptoImpl.subtle.decrypt({ name: 'AES-GCM', iv: unb64(envelope.iv), additionalData: aad(owner) },
        await key, unb64(envelope.data));
      return new TextDecoder('utf-8', { fatal: true }).decode(data);
    },
  };
}

export function createDropboxHandler({ serviceKey, publishableKey, appKey, encryptionKey,
  fetchImpl = fetch, cryptoImpl = globalThis.crypto }) {
  // Fail closed, without emitting credentials or raw upstream errors.
  let cipher;
  try {
    if (!serviceKey || !publishableKey || !/^[A-Za-z0-9]{8,64}$/.test(appKey ?? '')) throw Error('configuration');
    cipher = createGrantCipher(encryptionKey, appKey, cryptoImpl);
  } catch { return async () => reply(503, { error: 'not_configured' }); }
  async function call(url, options) {
    return fetchImpl(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(15000) });
  }
  async function rpc(action, owner, session, extra = {}) {
    const result = await call(origin + '/rest/v1/rpc/bound_dropbox_grant', { method: 'POST',
      headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, payload: { owner, session, ...extra } }) });
    if (!result.ok) throw Error('database');
    const value = await json(result.body);
    if (value?.error) throw Object.assign(Error('grant'), { code: value.error });
    return value;
  }
  async function token(form) {
    const result = await call('https://api.dropboxapi.com/oauth2/token', { method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ ...form, client_id: appKey }).toString() });
    const value = await json(result.body);
    if (result.status === 400 && value?.error === 'invalid_grant') throw Object.assign(Error('grant'), { code: 'reconnect_required' });
    if (!result.ok || typeof value?.access_token !== 'string' || !value.access_token ||
        value.access_token.length > 16384 || !Number.isFinite(value.expires_in) || value.expires_in <= 0) throw Error('dropbox');
    return value;
  }
  return async request => {
    if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    if (request.headers.get('content-type')?.split(';')[0] !== 'application/json') return reply(400, { error: 'invalid_request' });
    const authorization = request.headers.get('authorization') ?? '';
    if (!/^Bearer [A-Za-z0-9._-]{16,16384}$/.test(authorization)) return reply(401, { error: 'unauthorized' });
    let body;
    try { body = await json(request.body, 4096); } catch { return reply(400, { error: 'invalid_request' }); }
    if (!(exact(body, ['action']) && ['token', 'unlink'].includes(body.action)) &&
        !(exact(body, ['action', 'code', 'verifier']) && body.action === 'link' &&
          typeof body.code === 'string' && /^[\x21-\x7e]{1,2048}$/.test(body.code) &&
          typeof body.verifier === 'string' && /^[A-Za-z0-9._~-]{43,128}$/.test(body.verifier))) {
      return reply(400, { error: 'invalid_request' });
    }
    try {
      const auth = await call(origin + '/auth/v1/user', { headers: { Authorization: authorization, apikey: publishableKey } });
      if (!auth.ok) return reply(auth.status >= 500 ? 503 : 401, { error: 'unauthorized' });
      const user = await json(auth.body);
      if (!uuid.test(user?.id ?? '') || user.is_anonymous !== false || user.role !== 'authenticated' ||
          !Number.isFinite(Date.parse(user.email_confirmed_at ?? ''))) return reply(403, { error: 'unauthorized' });
      // Claims are read ONLY after getUser has verified this exact bearer token.
      const part = authorization.slice(7).split('.')[1];
      const claims = JSON.parse(new TextDecoder().decode(unb64(part.replaceAll('-', '+').replaceAll('_', '/'))));
      if (claims.sub !== user.id || !uuid.test(claims.session_id ?? '')) return reply(401, { error: 'unauthorized' });
      if (!permitsSecondFactor(user, authorization)) return reply(403, {error:'second_factor_required'});
      const owner = user.id.toLowerCase(); const session = claims.session_id;
      const snapshot = await rpc('snapshot', owner, session);
      if (!uuid.test(snapshot?.revision ?? '')) throw Error('database');
      const revision = snapshot.revision;
      if (body.action === 'unlink') {
        const removed = await rpc('unlink', owner, session, { revision });
        // Delete first. Network/revocation failures must never restore the grant.
        if (removed.ciphertext) {
          try {
            const refresh = await cipher.open(owner, removed.ciphertext);
            const access = await token({ grant_type: 'refresh_token', refresh_token: refresh });
            await call('https://api.dropboxapi.com/2/auth/token/revoke', { method: 'POST',
              headers: { Authorization: `Bearer ${access.access_token}` } });
          } catch { /* Best effort; Bound's stored grant is already removed. */ }
        }
        return reply(200, { ok: true });
      }
      if (body.action === 'token' && !snapshot.ciphertext) return reply(404, { error: 'not_linked' });
      let access; let connectionID = revision;
      if (body.action === 'link') {
        access = await token({ grant_type: 'authorization_code', code: body.code, code_verifier: body.verifier,
          redirect_uri: `db-${appKey}://2/token` });
        if (typeof access.refresh_token !== 'string' || !access.refresh_token || access.refresh_token.length > 16384) throw Error('dropbox');
        const ciphertext = await cipher.seal(owner, access.refresh_token);
        const stored = await rpc('store', owner, session, { revision, ciphertext });
        if (!uuid.test(stored?.revision ?? '')) throw Error('database');
        connectionID = stored.revision;
      } else {
        try {
          access = await token({ grant_type: 'refresh_token', refresh_token: await cipher.open(owner, snapshot.ciphertext) });
        } catch (error) {
          if (error.code === 'reconnect_required') await rpc('invalidate', owner, session, { revision });
          throw error;
        }
        // Re-check unlink, deletion and session revocation after network work.
        await rpc('validate', owner, session, { revision });
      }
      return reply(200, { accessToken: access.access_token, expiresIn: access.expires_in, connectionID });
    } catch (error) {
      const status = { unauthorized: 401, connection_changed: 409, reconnect_required: 409, rate_limited: 429 }[error.code];
      return reply(status ?? 503, { error: status ? error.code : 'unavailable' });
    }
  };
}
