import { createHash, createHmac, createCipheriv, createDecipheriv, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';

const SESSIONS = 'bound_auth_sessions_v1', FACTORS = 'bound_auth_factors_v1', PROOFS = 'bound_auth_proofs_v1', CHALLENGES = 'bound_auth_challenges_v1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const now = () => Math.floor(Date.now() / 1000);
const hash = value => createHash('sha256').update(value).digest('hex');
const equal = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export class AuthError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
const fail = (status = 401, code = 'unauthorized') => { throw new AuthError(status, code); };
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
function claims(token) {
  try { const parts = token.split('.'); if (parts.length !== 3 || token.length > 16384) fail(); return JSON.parse(Buffer.from(parts[1], 'base64url')); } catch { fail(); }
}
function email(value) {
  const normalized = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (normalized.length < 10 || normalized.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) fail(400, 'invalid_email');
  return normalized;
}
function password(value, creating = false) {
  if (typeof value !== 'string' || value.includes('\0') || Buffer.byteLength(value) < (creating ? 8 : 1) || Buffer.byteLength(value) > (creating ? 72 : 1024)) fail(400, 'weak_password');
  return value;
}
function username(value) {
  if (typeof value !== 'string' || value.trim().length < 1 || value.trim().length > 40 || /[\x00-\x1f\x7f@]|https?:|www\./i.test(value)) fail(400, 'invalid_username');
  return value.trim();
}
async function body(request) {
  if (!request.headers.get('content-type')?.startsWith('application/json')) fail(415, 'invalid_request');
  const raw = await request.text();
  if (Buffer.byteLength(raw) > 8192) fail(413, 'invalid_request');
  try { const parsed = JSON.parse(raw); if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) fail(400, 'invalid_request'); return parsed; } catch { fail(400, 'invalid_request'); }
}
const exposeFactor = value => ({ id: value.id, status: value.status, factor_type: value.factor_type, friendly_name: value.friendly_name });
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function base32(bytes) {
  let bits = 0, value = 0, result = '';
  for (const byte of bytes) { value = (value << 8) | byte; bits += 8; while (bits >= 5) { result += alphabet[(value >>> (bits - 5)) & 31]; bits -= 5; } }
  if (bits) result += alphabet[(value << (5 - bits)) & 31];
  return result;
}
export function totp(secret, step) {
  let bits = 0, value = 0; const bytes = [];
  for (const ch of secret) { const index = alphabet.indexOf(ch); if (index < 0) fail(500, 'invalid_factor'); value = (value << 5) | index; bits += 5; if (bits >= 8) { bytes.push((value >>> (bits - 8)) & 255); bits -= 8; } }
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(step));
  const digest = createHmac('sha1', Buffer.from(bytes)).update(counter).digest(), offset = digest[19] & 15;
  return String((digest.readUInt32BE(offset) & 0x7fffffff) % 1000000).padStart(6, '0');
}

export function createAuth({ nakama, config, fetchImpl = fetch }) {
  const encryptionKey = Buffer.from(config.BOUND_AUTH_ENCRYPTION_KEY || '', 'base64');
  if (encryptionKey.length !== 32) throw Error('BOUND_AUTH_ENCRYPTION_KEY must be 32 random bytes encoded as base64');
  const origin = new URL(config.BOUND_PUBLIC_URL || config.PUBLIC_URL).origin;
  if (!origin.startsWith('https://') && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) throw Error('BOUND_PUBLIC_URL must use HTTPS');
  const limits = new Map();
  function limit(key, capacity = 10, seconds = 900) {
    const time = now(), item = limits.get(key);
    if (limits.size > 4096) { for (const [k, v] of limits) if (v.until <= time) limits.delete(k); if (limits.size > 4096 && !item) fail(429, 'rate_limited'); }
    if (!item || item.until <= time) { limits.set(key, { count: 1, until: time + seconds }); return; }
    if (++item.count > capacity) fail(429, 'rate_limited');
  }
  function seal(secret) {
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', encryptionKey, iv);
    return Buffer.concat([iv, cipher.update(secret, 'utf8'), cipher.final(), cipher.getAuthTag()]).toString('base64');
  }
  function unseal(value) {
    const encrypted = Buffer.from(value, 'base64');
    if (encrypted.length < 29) fail(503, 'factor_unavailable');
    const decipher = createDecipheriv('aes-256-gcm', encryptionKey, encrypted.subarray(0, 12)); decipher.setAuthTag(encrypted.subarray(-16));
    try { return Buffer.concat([decipher.update(encrypted.subarray(12, -16)), decipher.final()]).toString('utf8'); } catch { fail(503, 'factor_unavailable'); }
  }
  async function factors(id) { return (await nakama.list(id, FACTORS)).map(record => ({ ...record.value, id: record.key, version: record.version })); }
  async function user(id) { const account = await nakama.account(id); return { ...account, aud: 'authenticated', role: 'authenticated', is_anonymous: false, factors: (await factors(id)).map(exposeFactor) }; }
  async function authenticate(request, { allowMFA = false, allowRecovery = false } = {}) {
    const match = /^Bearer ([^\s]+)$/.exec(request.headers.get('authorization') || '');
    if (!match) fail(); const token = match[1], native = claims(token);
    if (!uuid.test(native.uid || '') || !uuid.test(native.vrs?.session_id || '') || native.exp <= now()) fail();
    let valid;
    try { valid = await nakama.validate(token); } catch (error) { if ([401, 403].includes(error.status)) fail(); throw error; } // Nakama verifies signature, expiry and native revocation.
    if ((valid.user?.id ?? valid.user?.user_id) !== native.uid) fail();
    const record = await nakama.read(native.uid, SESSIONS, native.vrs.session_id);
    if (!record || record.value.revoked || record.value.expiresAt <= now() || !equal(record.value.accessHash, hash(token)) || record.value.aal !== native.vrs.aal) fail();
    const account = await user(native.uid);
    if (!account.email_confirmed_at || native.vrs.email !== account.email) fail();
    if (record.value.purpose === 'recovery' && !allowRecovery) fail(403, 'recovery_session');
    if (!allowMFA && account.factors.some(factor => factor.status === 'verified') && native.vrs.aal !== 'aal2') fail(403, 'mfa_required');
    const trustedClaims = { sub: native.uid, session_id: native.vrs.session_id, aal: native.vrs.aal, email: account.email, exp: native.exp, role: 'authenticated' };
    return { ...account, ownerID: account.id, nakamaUserID: account.id, session_id: trustedClaims.session_id, sessionID: trustedClaims.session_id,
      token, nakamaToken: token, user: account, claims: trustedClaims, aal: trustedClaims.aal, record };
  }
  async function saveSession(account, native, sessionID, aal, purpose = 'normal', version = '*') {
    const token = native.token, refresh = native.refresh_token ?? native.refreshToken;
    if (!token || !refresh) fail(503, 'session_unavailable');
    const c = claims(token), r = claims(refresh);
    if (c.uid !== account.id || c.vrs?.session_id !== sessionID || c.vrs?.aal !== aal || c.exp <= now() || r.uid !== account.id || r.exp <= now()) fail(503, 'session_unavailable');
    await nakama.write(account.id, SESSIONS, sessionID, { expiresAt: purpose === 'recovery' ? Math.min(r.exp, now() + 900) : r.exp, aal, purpose, accessHash: hash(token), refreshHash: hash(refresh), revoked: false }, version);
    return { access_token: token, refresh_token: refresh, token_type: 'bearer', expires_in: c.exp - now(), expires_at: c.exp, user: await user(account.id) };
  }
  async function issue(account, aal = 'aal1', purpose = 'normal') {
    const sessionID = randomUUID();
    return saveSession(account, await nakama.session(account.id, sessionID, aal), sessionID, aal, purpose);
  }
  async function revoke(identity) {
    await nakama.write(identity.id, SESSIONS, identity.session_id, { ...identity.record.value, revoked: true }, identity.record.version);
    await nakama.logout(identity.id, identity.token);
  }
  async function revokeAll(id) {
    // Native revocation covers every session; journal revocation also persists through restart.
    await nakama.logout(id);
    for (const record of await nakama.list(id, SESSIONS)) if (!record.value.revoked) await nakama.write(id, SESSIONS, record.key, { ...record.value, revoked: true }, record.version);
  }
  async function mail(to, subject, text) {
    if (!config.RESEND_API_KEY || !config.RESEND_FROM) fail(503, 'email_unavailable');
    const response = await fetchImpl('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: 'Bearer ' + config.RESEND_API_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: config.RESEND_FROM, to: [to], subject, text }), redirect: 'error', signal: AbortSignal.timeout(10000) });
    if (!response.ok) fail(503, 'email_unavailable');
  }
  async function sendProof(account, type) {
    const token = randomBytes(32).toString('base64url'), key = randomUUID();
    await nakama.write(account.id, PROOFS, key, { type, tokenHash: hash(token), email: account.email, expiresAt: now() + 3600, consumed: false });
    const capability = `${account.id}.${key}.${token}`;
    const link = `${origin}/auth/${type === 'signup' ? 'confirm' : 'reset-password'}#token=${encodeURIComponent(capability)}`;
    await mail(account.email, type === 'signup' ? 'Confirm your Bound account' : 'Reset your Bound password', `${type === 'signup' ? 'Confirm your email address' : 'Choose a new password'}: ${link}\n\nThis link expires in one hour. If you did not request this, you can ignore it.`);
  }
  async function consumeProof(value, type) {
    if (typeof value !== 'string' || value.length > 300) fail(400, 'invalid_token');
    const parts = value.split('.'); if (parts.length !== 3 || !uuid.test(parts[0]) || !uuid.test(parts[1])) fail(400, 'invalid_token');
    const [id, key, token] = parts, record = await nakama.read(id, PROOFS, key);
    if (!record || record.value.type !== type || record.value.consumed || record.value.expiresAt <= now() || !equal(record.value.tokenHash, hash(token))) fail(400, 'invalid_token');
    const account = await nakama.account(id);
    if (record.value.email !== account.email) fail(400, 'invalid_token');
    await nakama.write(id, PROOFS, key, { ...record.value, consumed: true }, record.version);
    return account;
  }
  async function handle(request) {
    const url = new URL(request.url), path = url.pathname;
    if (request.method === 'GET' && ['/auth/confirm', '/auth/reset-password'].includes(path)) return authPage(path.endsWith('confirm') ? 'signup' : 'recovery');
    if (!path.startsWith('/auth/v1/') && path !== '/functions/v1/change-account-email') return null;
    try {
      const browserOrigin = request.headers.get('origin');
      if (browserOrigin && browserOrigin !== origin) fail(403, 'forbidden');
      // The HTTP adapter must replace this header with the actual peer/proxy IP.
      limit('ip:' + (request.headers.get('x-bound-client-ip') || 'unknown'), 80, 60);
      if (path === '/auth/v1/signup' && request.method === 'POST') {
        const input = await body(request), address = email(input.email), pass = password(input.password, true), name = username(input.data?.bound_username_v1);
        limit('signup:' + address, 3, 3600);
        const existing = await nakama.lookup(address);
        if (existing) { if (!existing.email_confirmed_at) await sendProof(existing, 'signup'); return json({ user: { id: randomUUID(), email: address } }); }
        const account = await nakama.signup(address, pass, name);
        if (account.existing) return json({ user: { id: randomUUID(), email: address } });
        await sendProof(account, 'signup'); return json({ user: account });
      }
      if (path === '/auth/v1/token' && request.method === 'POST') {
        const input = await body(request);
        if (url.searchParams.get('grant_type') === 'password') {
          const address = email(input.email); limit('login:' + address, 10);
          let account;
          try { account = await nakama.password(address, password(input.password)); } catch { fail(400, 'invalid_credentials'); }
          if (!account.email_confirmed_at) fail(400, 'email_not_confirmed');
          return json(await issue(account));
        }
        if (url.searchParams.get('grant_type') === 'refresh_token') {
          const refresh = input.refresh_token;
          if (typeof refresh !== 'string') fail(); const c = claims(refresh), id = c.uid, sid = c.vrs?.session_id;
          if (!uuid.test(id || '') || !uuid.test(sid || '') || c.exp <= now()) fail(401, 'refresh_token_not_found');
          const record = await nakama.read(id, SESSIONS, sid);
          if (!record || record.value.revoked || record.value.purpose === 'recovery' || record.value.expiresAt <= now() || !equal(record.value.refreshHash, hash(refresh))) fail(401, 'refresh_token_already_used');
          const account = await nakama.account(id); if (!account.email_confirmed_at || account.email !== c.vrs.email) fail();
          const lease = await nakama.write(id, SESSIONS, sid, { ...record.value, revoked: true }, record.version);
          const native = await nakama.refresh(refresh, sid, record.value.aal, account.email);
          return json(await saveSession(account, native, sid, record.value.aal, record.value.purpose, lease.version));
        }
        fail(400, 'unsupported_grant_type');
      }
      if (path === '/auth/v1/recover' && request.method === 'POST') {
        const input = await body(request), address = email(input.email); limit('recover:' + address, 3, 3600);
        const account = await nakama.lookup(address); if (account?.email_confirmed_at) await sendProof(account, 'recovery');
        return json({});
      }
      if (path === '/auth/v1/resend' && request.method === 'POST') {
        const input = await body(request), address = email(input.email); limit('resend:' + address, 3, 3600);
        const account = await nakama.lookup(address); if (account && !account.email_confirmed_at) await sendProof(account, 'signup');
        return json({});
      }
      if (path === '/auth/v1/verify' && request.method === 'POST') {
        const input = await body(request); if (!['signup', 'recovery'].includes(input.type)) fail(400, 'invalid_request');
        const account = await consumeProof(input.token ?? input.token_hash, input.type);
        if (input.type === 'signup') { await nakama.confirm(account.id); return json({ verified: true }); }
        return json(await issue(account, 'aal1', 'recovery'));
      }
      if (path.startsWith('/auth/v1/passkeys')) return json({ error: 'not_enabled' }, 501);
      if (path === '/functions/v1/change-account-email') {
        if (request.method !== 'POST') fail(405, 'method_not_allowed');
        if (browserOrigin) fail(403, 'forbidden');
        const identity = await authenticate(request), input = await body(request);
        if (Object.keys(input).sort().join(',') !== 'currentPassword,newEmail') fail(400, 'invalid_request');
        const address = email(input.newEmail); limit('email:' + identity.id, 5);
        let proof; try { proof = await nakama.password(identity.email, password(input.currentPassword)); } catch { fail(403, 'invalid_password'); }
        if (proof.id !== identity.id) fail(403, 'invalid_password');
        if (address !== identity.email) {
          // Same account UUID and existing password; preserve the app's password-authorized change contract.
          await authenticate(request);
          try { await nakama.updateEmail(identity.id, address); } catch { fail(409, 'email_unavailable'); }
          await revokeAll(identity.id);
        }
        return json({ ok: true, email: address });
      }
      if (path === '/auth/v1/user' && request.method === 'GET') return json((await authenticate(request, { allowMFA: true, allowRecovery: true })).user);
      if (path === '/auth/v1/user' && request.method === 'PUT') {
        const identity = await authenticate(request, { allowRecovery: true }), input = await body(request);
        if (Object.keys(input).join(',') !== 'password') fail(400, 'invalid_request');
        await nakama.updatePassword(identity.id, password(input.password, true)); await revokeAll(identity.id);
        return json(identity.user);
      }
      if (path === '/auth/v1/logout' && request.method === 'POST') {
        const identity = await authenticate(request, { allowMFA: true, allowRecovery: true });
        if (url.searchParams.get('scope') === 'global') await revokeAll(identity.id); else await revoke(identity);
        return json({});
      }
      const factorPath = /^\/auth\/v1\/factors(?:\/([0-9a-f-]{36})(?:\/(challenge|verify))?)?$/.exec(path);
      if (factorPath) {
        const identity = await authenticate(request, { allowMFA: true, allowRecovery: true });
        const factorID = factorPath[1], action = factorPath[2];
        if (!factorID && request.method === 'GET') return json({ all: identity.user.factors, totp: identity.user.factors.filter(f => f.factor_type === 'totp') });
        if (!factorID && request.method === 'POST') {
          if (identity.record.value.purpose === 'recovery') fail(403, 'recovery_session');
          if (identity.user.factors.some(f => f.status === 'verified') && identity.aal !== 'aal2') fail(403, 'mfa_required');
          if (identity.user.factors.length >= 10) fail(400, 'factor_limit');
          const input = await body(request); if (input.factor_type !== 'totp') fail(400, 'unsupported_factor');
          const id = randomUUID(), secret = base32(randomBytes(20)), friendly = String(input.friendly_name || 'Authenticator').slice(0, 100);
          await nakama.write(identity.id, FACTORS, id, { status: 'unverified', factor_type: 'totp', friendly_name: friendly, secret: seal(secret), lastStep: -1 });
          return json({ id, type: 'totp', friendly_name: friendly, totp: { secret, uri: `otpauth://totp/Bound:${encodeURIComponent(identity.email)}?secret=${secret}&issuer=Bound&algorithm=SHA1&digits=6&period=30` } });
        }
        if (!uuid.test(factorID || '')) fail(404, 'factor_not_found');
        const factor = await nakama.read(identity.id, FACTORS, factorID); if (!factor) fail(404, 'factor_not_found');
        if (factor.value.status !== 'verified' && (identity.record.value.purpose === 'recovery' || (identity.user.factors.some(f => f.status === 'verified') && identity.aal !== 'aal2'))) fail(403, 'mfa_required');
        if (request.method === 'DELETE' && !action) {
          if (identity.record.value.purpose === 'recovery' || (factor.value.status === 'verified' && identity.aal !== 'aal2')) fail(403, 'mfa_required');
          await nakama.remove(identity.id, FACTORS, factorID, factor.version); return json({ id: factorID });
        }
        if (request.method === 'POST' && action === 'challenge') {
          limit('challenge:' + identity.id, 15);
          const id = randomUUID(); await nakama.write(identity.id, CHALLENGES, id, { factorID, sessionID: identity.session_id, expiresAt: now() + 300, consumed: false });
          return json({ id, expires_at: now() + 300 });
        }
        if (request.method === 'POST' && action === 'verify') {
          limit('totp:' + identity.id, 10);
          const input = await body(request); if (!uuid.test(input.challenge_id || '') || !/^\d{6}$/.test(input.code || '')) fail(400, 'invalid_code');
          const challenge = await nakama.read(identity.id, CHALLENGES, input.challenge_id);
          if (!challenge || challenge.value.factorID !== factorID || challenge.value.sessionID !== identity.session_id || challenge.value.consumed || challenge.value.expiresAt <= now()) fail(400, 'invalid_challenge');
          const current = Math.floor(now() / 30), secret = unseal(factor.value.secret);
          const step = [current - 1, current, current + 1].find(step => step > (factor.value.lastStep ?? -1) && equal(totp(secret, step), input.code));
          if (step === undefined) fail(400, 'invalid_code');
          await nakama.write(identity.id, CHALLENGES, input.challenge_id, { ...challenge.value, consumed: true }, challenge.version);
          await nakama.write(identity.id, FACTORS, factorID, { ...factor.value, status: 'verified', lastStep: step }, factor.version);
          await revoke(identity);
          return json(await issue(identity.user, 'aal2', identity.record.value.purpose));
        }
      }
      return json({ error: 'not_found' }, 404);
    } catch (error) {
      if (error instanceof AuthError) return json({ error: error.code, error_code: error.code }, error.status);
      return json({ error: 'unavailable' }, 503);
    }
  }
  return { handle, authenticate, deleteAccount: async id => { await revokeAll(id); await nakama.deleteAccount(id); } };
}

function authPage(type) {
  const recovery = type === 'recovery', nonce = randomBytes(18).toString('base64');
  const script = `const token=new URLSearchParams(location.hash.slice(1)).get('token');history.replaceState(null,'',location.pathname);const form=document.querySelector('form'),status=document.querySelector('[role=status]');let access=null;form.addEventListener('submit',async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{if(!access){const response=await fetch('/auth/v1/verify',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:${JSON.stringify(type)},token})});const data=await response.json();if(!response.ok)throw Error('This link is invalid or expired. Request a new link.');access=data.access_token;${recovery ? '' : "status.textContent='Email confirmed. Return to Bound to sign in.';form.hidden=true;return;"}}${recovery ? "const response=await fetch('/auth/v1/user',{method:'PUT',headers:{'Content-Type':'application/json',Authorization:'Bearer '+access},body:JSON.stringify({password:form.password.value})});if(!response.ok){const data=await response.json();if(data.error==='mfa_required')throw Error('This account uses an authenticator. Enter its code below.');throw Error('Could not update your password. Use 8–72 bytes and try again.');}status.textContent='Password updated. Return to Bound to sign in.';form.hidden=true;" : ''}}catch(error){status.textContent=error.message;}finally{button.disabled=false;}});${recovery ? recoveryMFAScript() : ''}`;
  const html = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${recovery ? 'Reset password' : 'Confirm email'} · Bound</title><style nonce="${nonce}">body{font:17px system-ui;max-width:420px;margin:10vh auto;padding:24px}input,button{box-sizing:border-box;display:block;width:100%;font:inherit;padding:12px;margin:14px 0}button{cursor:pointer}</style><main><h1>${recovery ? 'Reset password' : 'Confirm email'}</h1><form>${recovery ? '<label>New password<input name="password" type="password" minlength="8" autocomplete="new-password" required></label>' : ''}<button>${recovery ? 'Update password' : 'Confirm email'}</button></form>${recovery ? '<form id="mfa" hidden><label>Authenticator code<input name="code" inputmode="numeric" pattern="[0-9]{6}" autocomplete="one-time-code" required></label><button>Verify</button></form>' : ''}<p role="status"></p></main><script nonce="${nonce}">${script}</script></html>`;
  return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'` } });
}
function recoveryMFAScript() {
  return `const mfa=document.querySelector('#mfa');new MutationObserver(()=>{if(status.textContent.includes('authenticator'))mfa.hidden=false;}).observe(status,{childList:true});mfa.addEventListener('submit',async event=>{event.preventDefault();const headers={'Content-Type':'application/json',Authorization:'Bearer '+access};try{let response=await fetch('/auth/v1/user',{headers}),account=await response.json();const factor=account.factors?.find(f=>f.status==='verified'&&f.factor_type==='totp');if(!factor)throw Error('No supported authenticator is available.');response=await fetch('/auth/v1/factors/'+factor.id+'/challenge',{method:'POST',headers,body:'{}'});const challenge=await response.json();if(!response.ok)throw Error('Could not start verification.');response=await fetch('/auth/v1/factors/'+factor.id+'/verify',{method:'POST',headers,body:JSON.stringify({challenge_id:challenge.id,code:mfa.code.value})});const verified=await response.json();if(!response.ok)throw Error('Invalid or expired code.');access=verified.access_token;mfa.hidden=true;form.requestSubmit();}catch(error){status.textContent=error.message;}});`;
}
