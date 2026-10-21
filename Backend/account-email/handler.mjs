const origin = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const bearer = /^Bearer [A-Za-z0-9._-]{16,16384}$/;
const reply = (status, body) => new Response(JSON.stringify(body), { status,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
export function normalizedEmail(value) {
  if (typeof value !== 'string') return null;
  const email = value.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '').toLowerCase();
  return email.length <= 254 && /^[\x21-\x7e]+$/.test(email) && /^[^@]+@[^@]+$/.test(email) ? email : null;
}
async function json(stream, limit = 65536) {
  if (!stream) throw Error('body');
  const reader = stream.getReader(); const chunks = []; let size = 0; let timer;
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => {
    void reader.cancel().catch(() => {}); reject(Error('deadline'));
  }, 5000); });
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
function claims(token) {
  const parts = token.split('.');
  if (parts.length !== 3 || parts[1].length > 12000) throw Error('claims');
  const bytes = Uint8Array.from(atob(parts[1].replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}
function validUser(user, owner, email) {
  return uuid.test(user?.id ?? '') && (!owner || user.id.toLowerCase() === owner) &&
    user.is_anonymous === false && user.role === 'authenticated' &&
    Number.isFinite(Date.parse(user.email_confirmed_at ?? '')) &&
    normalizedEmail(user.email) !== null && (!email || normalizedEmail(user.email) === email);
}
const requiresMFA = user => Array.isArray(user?.factors) && user.factors.some(factor => factor?.status === 'verified');
const fault = code => Object.assign(Error('request'), { code });

// This adapter alone holds the administrative key. Passwords and temporary
// tokens are never logged, persisted, returned, or copied to another service.
export function createEmailChangeHandler({ serviceKey, publishableKey, fetchImpl = fetch }) {
  if (!serviceKey || !publishableKey) return async () => reply(503, { error: 'not_configured' });
  async function call(path, method, body, authorization = `Bearer ${serviceKey}`, key = serviceKey) {
    return fetchImpl(origin + path, { method, redirect: 'error', signal: AbortSignal.timeout(10000),
      headers: { Authorization: authorization, apikey: key, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body) });
  }
  async function rpc(action, payload) {
    const response = await call('/rest/v1/rpc/bound_account_email', 'POST', { action, payload });
    if (!response.ok) throw Error('database');
    const value = await json(response.body);
    if (value?.error) throw fault(value.error);
    if (!value || value.ok !== true) throw Error('database');
    return value;
  }
  async function getUser(authorization) {
    const response = await call('/auth/v1/user', 'GET', undefined, authorization, publishableKey);
    if (!response.ok) throw fault(response.status >= 500 ? 'unavailable' : 'unauthorized');
    return json(response.body);
  }
  async function revokeTemporary(token) {
    // A JWT without session_id makes upstream logout fall back to global even
    // with scope=local. Callers validate a distinct temporary session first.
    const response = await call('/auth/v1/logout?scope=local', 'POST', undefined, `Bearer ${token}`, publishableKey);
    if (!response.ok && response.status !== 401 && response.status !== 404) throw Error('logout');
  }
  return async request => {
    if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    if (request.headers.get('content-type')?.split(';')[0] !== 'application/json') return reply(400, { error: 'invalid_request' });
    const authorization = request.headers.get('authorization') ?? '';
    if (!bearer.test(authorization)) return reply(401, { error: 'unauthorized' });
    let body;
    try { body = await json(request.body, 8192); } catch { return reply(400, { error: 'invalid_request' }); }
    const newEmail = normalizedEmail(body?.newEmail);
    if (!body || Array.isArray(body) || Object.keys(body).sort().join(',') !== 'currentPassword,newEmail' ||
        !newEmail || typeof body.currentPassword !== 'string' || !body.currentPassword.length ||
        new TextEncoder().encode(body.currentPassword).length > 1024 || body.currentPassword.includes('\0')) {
      return reply(400, { error: 'invalid_request' });
    }
    let operation; let owner; let session; let temporaryToken;
    try {
      const user = await getUser(authorization);
      if (!validUser(user)) throw fault('unauthorized');
      owner = user.id.toLowerCase(); const email = normalizedEmail(user.email);
      const originalClaims = claims(authorization.slice(7));
      if (originalClaims.sub?.toLowerCase() !== owner || !uuid.test(originalClaims.session_id ?? '')) throw fault('unauthorized');
      if (requiresMFA(user) && originalClaims.aal !== 'aal2') throw fault('unauthorized');
      session = originalClaims.session_id;
      const reserved = await rpc('begin', { owner, session, email, newEmail });
      if (!uuid.test(reserved.operation ?? '')) throw Error('database');
      operation = reserved.operation;
      const passwordResponse = await call('/auth/v1/token?grant_type=password', 'POST',
        { email, password: body.currentPassword }, `Bearer ${publishableKey}`, publishableKey);
      body.currentPassword = ''; // Drop our reference as soon as verification finishes.
      if (!passwordResponse.ok) throw fault(passwordResponse.status === 429 ? 'rate_limited' :
        passwordResponse.status >= 500 ? 'unavailable' : 'invalid_password');
      const proof = await json(passwordResponse.body);
      if (typeof proof?.access_token !== 'string' || !bearer.test(`Bearer ${proof.access_token}`)) throw Error('proof');
      const proofClaims = claims(proof.access_token);
      if (!uuid.test(proofClaims.session_id ?? '') || proofClaims.session_id === session ||
          !uuid.test(proofClaims.sub ?? '')) throw fault('invalid_password');
      temporaryToken = proof.access_token;
      if (proofClaims.sub.toLowerCase() !== owner || !validUser(proof.user, owner, email)) throw fault('invalid_password');
      if (requiresMFA(proof.user) && originalClaims.aal !== 'aal2') throw fault('unauthorized');
      // Remove the password-grant session before changing identity. Never sign
      // out the native bearer or all devices as a side effect of password proof.
      await revokeTemporary(temporaryToken); temporaryToken = undefined;
      const current = await getUser(authorization);
      if (!validUser(current, owner, email)) throw fault('account_changed');
      if (requiresMFA(current) && originalClaims.aal !== 'aal2') throw fault('unauthorized');
      await rpc('validate', { owner, session, operation, email, newEmail });
      // A lost response may leave the app displaying the old email after a
      // committed update. Reconcile only after proving the actual current
      // email's password and repeating the live-session/deletion authorization.
      if (newEmail === email) return reply(200, { ok: true, email });
      let updated;
      try {
        const response = await call('/auth/v1/admin/users/' + owner, 'PUT', { email: newEmail, email_confirm: true });
        if (!response.ok) {
          const error = await json(response.body);
          if (['email_exists', 'email_address_invalid', 'email_address_not_authorized'].includes(error?.code)) throw fault('email_unavailable');
          throw Error('update');
        }
        updated = await json(response.body);
      } catch (error) {
        if (error.code === 'email_unavailable') throw error;
        // Reconcile a successful write whose response was lost. This happens
        // only after fresh owner/password proof and the final authorization.
        const checked = await call('/auth/v1/admin/users/' + owner, 'GET');
        if (!checked.ok) throw Error('update');
        updated = await json(checked.body);
      }
      if (!validUser(updated, owner, newEmail)) throw Error('update');
      return reply(200, { ok: true, email: normalizedEmail(updated.email) });
    } catch (error) {
      const status = { invalid_request: 400, unauthorized: 401, invalid_password: 403,
        email_unavailable: 409, account_changed: 409, change_in_progress: 409, rate_limited: 429 }[error.code];
      return reply(status ?? 503, { error: status ? error.code : 'unavailable' });
    } finally {
      body.currentPassword = '';
      if (temporaryToken) { try { await revokeTemporary(temporaryToken); } catch { /* No token is exposed. */ } }
      if (operation) { try { await rpc('release', { owner, session, operation }); } catch { /* Lease expires; no password/token is stored. */ } }
    }
  };
}
