const supabaseOrigin = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
const protocol = 'bound-room-v1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const reply = (status, body) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});
const exactKeys = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));

async function boundedJSON(stream, limit, timeoutMs) {
  if (!stream) throw Error('missing body');
  const reader = stream.getReader(); const chunks = []; let size = 0; let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => { void reader.cancel().catch(() => {}); reject(Error('body timeout')); }, timeoutMs);
  });
  try {
    for (;;) {
      const { done, value } = await Promise.race([reader.read(), timeout]);
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw Error('body too large');
      chunks.push(value);
    }
  } finally { clearTimeout(timer); void reader.cancel().catch(() => {}); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}

function b64url(bytes) {
  let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

function decodeToken(token, current) {
  if (typeof token !== 'string' || token.length > 8192 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) throw Error('invalid session');
  const encoded = token.split('.')[1].replaceAll('-', '+').replaceAll('_', '/');
  const binary = atob(encoded + '='.repeat((4 - encoded.length % 4) % 4));
  const claims = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(binary, c => c.charCodeAt(0))));
  if (!uuid.test(claims.uid ?? '') || !Number.isSafeInteger(claims.exp) || claims.exp <= current + 10) throw Error('invalid session');
  return claims;
}

function endpoint(value) {
  if (typeof value !== 'string' || value.length > 2048) throw Error('invalid endpoint');
  const url = new URL(value);
  // This is server configuration, never a client-supplied host or an upstream redirect.
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
      !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/i.test(url.hostname) || !url.hostname.includes('.') ||
      /^\d+\.\d+\.\d+\.\d+$/.test(url.hostname) || url.hostname.endsWith('.localhost')) throw Error('invalid endpoint');
  return url.origin;
}

function checkedRoom(value, ownerID, roomID) {
  if (value?.roomID !== roomID || value.ownerID !== ownerID || !Array.isArray(value.members) ||
      value.members.length < 2 || value.members.length > 8 || value.members.some(id => !uuid.test(id ?? '')) ||
      new Set(value.members).size !== value.members.length || !value.members.includes(ownerID)) throw Error('invalid room');
  const members = [...value.members].sort();
  const peerOwnerID = value.peerOwnerID ?? value.peerID;
  if (!uuid.test(peerOwnerID ?? '') || peerOwnerID === ownerID || !members.includes(peerOwnerID)) throw Error('invalid peer');
  return { roomID, ownerID, members, peerOwnerID };
}

/** The broker derives every identity and room member from live Supabase authorization.
 * No Nakama server key, bridge secret, refresh token or Supabase JWT reaches the response.
 */
export function createNakamaSessionHandler({ publishableKey, nakamaHTTPURL, nakamaServerKey, bridgeSecret,
  fetchImpl = fetch, cryptoImpl = globalThis.crypto, now = () => Math.floor(Date.now() / 1000), requestTimeoutMs = 5000 } = {}) {
  let origin; let signingKey;
  try {
    origin = endpoint(nakamaHTTPURL);
    if (typeof publishableKey !== 'string' || !publishableKey || publishableKey.length > 2048 ||
        typeof nakamaServerKey !== 'string' || !/^[!-9;-~]{16,256}$/.test(nakamaServerKey) ||
        typeof bridgeSecret !== 'string' || new TextEncoder().encode(bridgeSecret).length < 32 ||
        new TextEncoder().encode(bridgeSecret).length > 1024 || !cryptoImpl?.subtle) throw Error('not configured');
    signingKey = cryptoImpl.subtle.importKey('raw', new TextEncoder().encode(bridgeSecret),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    // Avoid a rejected promise escaping when startup configuration is invalid.
    void signingKey.catch(() => {});
  } catch { origin = null; }
  const socketURL = origin ? new URL('/ws?format=json&status=false', origin) : null;
  if (socketURL) socketURL.protocol = 'wss:';
  const call = (url, options = {}) => fetchImpl(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(requestTimeoutMs) });

  return async request => {
    if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
    // A future website must explicitly add its origin and CORS policy here.
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    if (request.headers.get('content-type')?.split(';')[0] !== 'application/json') return reply(400, { error: 'invalid_request' });
    const authorization = request.headers.get('authorization') ?? '';
    if (!/^Bearer [A-Za-z0-9._-]{16,16384}$/.test(authorization)) return reply(401, { error: 'unauthorized' });
    let body;
    try { body = await boundedJSON(request.body, 512, requestTimeoutMs); } catch { return reply(400, { error: 'invalid_request' }); }
    if (!exactKeys(body, ['roomID', 'protocol']) || !uuid.test(body.roomID ?? '') || body.protocol !== protocol) return reply(400, { error: 'invalid_request' });
    if (!origin) return reply(503, { error: 'not_configured' });
    const headers = { Authorization: authorization, apikey: publishableKey, 'Content-Type': 'application/json' };
    let ownerID;
    try {
      const auth = await call(`${supabaseOrigin}/auth/v1/user`, { headers });
      if (!auth.ok) return reply(401, { error: 'unauthorized' });
      const user = await boundedJSON(auth.body, 65536, requestTimeoutMs);
      if (!uuid.test(user?.id ?? '') || user.is_anonymous !== false || user.role !== 'authenticated' ||
          user.deleted_at || !Number.isFinite(Date.parse(user.email_confirmed_at ?? ''))) return reply(403, { error: 'forbidden' });
      ownerID = user.id;
      const active = await call(`${supabaseOrigin}/rest/v1/rpc/cup117_account_active`, { method: 'POST', headers, body: '{}' });
      if (!active.ok || await boundedJSON(active.body, 32, requestTimeoutMs) !== true) return reply(403, { error: 'forbidden' });
    } catch { return reply(503, { error: 'identity_unavailable' }); }
    const resolveRoom = async () => {
      const result = await call(`${supabaseOrigin}/rest/v1/rpc/bound_nakama_room_v1`, {
        method: 'POST', headers, body: JSON.stringify({ payload: { roomID: body.roomID } }),
      });
      if (!result.ok) return null;
      const value = await boundedJSON(result.body, 4096, requestTimeoutMs);
      // The RPC deliberately returns no privileged data for a denied room.
      if (value?.ok === false) return null;
      try { return checkedRoom(value, ownerID, body.roomID); } catch { return null; }
    };
    let room;
    try { room = await resolveRoom(); } catch { return reply(503, { error: 'membership_unavailable' }); }
    if (!room) return reply(403, { error: 'forbidden' });
    try {
      const issuedAt = now();
      if (!Number.isSafeInteger(issuedAt) || issuedAt < 0) throw Error('invalid clock');
      const claims = { version: 1, protocol, ownerID, roomID: body.roomID, members: room.members, issuedAt, expiresAt: issuedAt + 90 };
      const encoded = b64url(new TextEncoder().encode(JSON.stringify(claims)));
      const signature = new Uint8Array(await cryptoImpl.subtle.sign('HMAC', await signingKey, new TextEncoder().encode(encoded)));
      const joinTicket = encoded + '.' + Array.from(signature, byte => byte.toString(16).padStart(2, '0')).join('');
      const auth = await call(`${origin}/v2/account/authenticate/custom?create=true`, {
        method: 'POST', headers: { Authorization: 'Basic ' + btoa(nakamaServerKey + ':'), 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: 'bound:' + ownerID, vars: { bound_ticket: joinTicket } }),
      });
      if (!auth.ok) throw Error('upstream authentication failed');
      const session = await boundedJSON(auth.body, 32768, requestTimeoutMs);
      const sessionClaims = decodeToken(session?.token, now());
      const result = await call(`${origin}/v2/rpc/bound_room_v1`, {
        method: 'POST', headers: { Authorization: 'Bearer ' + session.token, 'Content-Type': 'application/json' },
        // Nakama's REST RPC payload is a JSON string containing serialized JSON.
        body: JSON.stringify(JSON.stringify({ ticket: joinTicket })),
      });
      if (!result.ok) throw Error('upstream room failed');
      const rpc = await boundedJSON(result.body, 8192, requestTimeoutMs);
      if (typeof rpc?.payload !== 'string' || rpc.payload.length > 4096) throw Error('invalid upstream room');
      const match = JSON.parse(rpc.payload);
      if (match?.roomID !== body.roomID || match.protocol !== protocol || match.nakamaUserID !== sessionClaims.uid ||
          typeof match.matchID !== 'string' || !/^[0-9a-f-]{36}\.[A-Za-z0-9_.-]{1,128}$/.test(match.matchID) ||
          !uuid.test(match.matchID.split('.')[0])) throw Error('invalid upstream room');
      // A block, logout or deletion racing upstream issuance must not receive credentials.
      const finalRoom = await resolveRoom();
      if (!finalRoom || JSON.stringify(finalRoom) !== JSON.stringify(room)) return reply(403, { error: 'forbidden' });
      const current = now();
      const expiresAt = Math.min(claims.expiresAt, sessionClaims.exp);
      if (!Number.isSafeInteger(current) || expiresAt <= current + 10) throw Error('expired issuance');
      return reply(200, { endpoint: socketURL.toString(), httpEndpoint: origin, accessToken: session.token,
        expiresAt, matchID: match.matchID, roomID: body.roomID, ownerID, nakamaUserID: sessionClaims.uid,
        joinTicket, members: room.members, peerOwnerID: room.peerOwnerID });
    } catch { return reply(503, { error: 'gameplay_unavailable' }); }
  };
}
