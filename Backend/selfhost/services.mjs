import { createHmac, randomBytes } from 'node:crypto';
import { connect as connectHTTP2 } from 'node:http2';
import { createTokenHandler } from '../moderation/agora-handler.mjs';
import { createDropboxHandler } from '../dropbox-link/handler.mjs';
import { createJiggleHandler } from '../social/handler.mjs';

const legacyOrigin = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
export const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const reply = (status, value) => new Response(JSON.stringify(value), { status,
  headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).sort().join(',') === [...keys].sort().join(',');
export async function readJSON(request, limit = 16384) {
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw Error('invalid_request');
  const reader = request.body?.getReader();
  if (!reader) throw Error('invalid_request');
  let size = 0; const chunks = []; let timer;
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => {
    void reader.cancel().catch(() => {}); reject(Error('invalid_request'));
  }, 10000); });
  try {
    for (;;) {
      const { value, done } = await Promise.race([reader.read(), deadline]);
      if (done) break;
      size += value.length;
      if (size > limit) throw Error('invalid_request');
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally { clearTimeout(timer); void reader.cancel().catch(() => {}); }
}

// Only constant statement templates are reachable. Parameters never select a
// function or SQL expression, and service-only RPCs are never exposed over HTTP.
const statements = {
  cup050_friends: ['SELECT public.cup050_friends($1,$2::jsonb) AS result', ['action', 'payload']],
  bound_social_v1: ['SELECT public.bound_social_v1($1,$2::jsonb) AS result', ['action', 'payload']],
  bound_social_v2: ['SELECT public.bound_social_v2($1,$2::jsonb) AS result', ['action', 'payload']],
  bound_notification_preferences: ['SELECT public.bound_notification_preferences($1::jsonb) AS result', ['payload']],
  bound_notification_device: ['SELECT public.bound_notification_device($1::jsonb) AS result', ['payload']],
  bound_run_lease_v1: ['SELECT public.bound_run_lease_v1($1,$2::jsonb) AS result', ['action', 'payload']],
  bound_username_available: ['SELECT public.bound_username_available($1) AS result', ['username']],
  bound_nakama_room_v1: ['SELECT public.bound_nakama_room_v1($1::jsonb) AS result', ['payload']],
  cup117_account_active: ['SELECT public.cup117_account_active() AS result', []],
  bound_account_mfa_allowed: ['SELECT public.bound_account_mfa_allowed() AS result', []],
  bound_dropbox_grant: ['SELECT public.bound_dropbox_grant($1,$2::jsonb) AS result', ['action', 'payload']],
  bound_jiggle_dispatch: ['SELECT public.bound_jiggle_dispatch($1::uuid,$2::uuid,$3::uuid) AS result', ['sender', 'room', 'request']],
  bound_game_notification_dispatch: ['SELECT public.bound_game_notification_dispatch($1::uuid,$2::uuid,$3::uuid,$4,$5::uuid,$6::uuid) AS result', ['sender', 'room', 'request', 'kind', 'run', 'installation']],
  bound_jiggle_finish: ['SELECT public.bound_jiggle_finish($1::uuid,$2::boolean,$3::text[]) AS result', ['job', 'delivered', 'invalid_tokens']],
};
const privileged = new Set(['bound_dropbox_grant', 'bound_jiggle_dispatch', 'bound_jiggle_finish', 'bound_game_notification_dispatch']);
function claimsFor(identity) {
  if (!identity || !uuid.test(identity.ownerID ?? identity.id ?? '') || !uuid.test(identity.sessionID ?? identity.session_id ?? '')) throw Error('unauthorized');
  return { ...identity.claims, sub: identity.ownerID ?? identity.id,
    session_id: identity.sessionID ?? identity.session_id, role: 'authenticated', aal: identity.claims?.aal ?? 'aal1' };
}

// APNs requires HTTP/2; Node's ordinary fetch does not negotiate it.
async function apnsFetch(url, options) {
  const target = new URL(url);
  return await new Promise((resolve, reject) => {
    const client = connectHTTP2(target.origin);
    const finish = error => { client.destroy(); reject(error); };
    client.on('error', finish);
    const stream = client.request({ ':method': options.method ?? 'POST', ':path': target.pathname, ...options.headers });
    stream.setTimeout(10000, () => finish(Error('APNs timeout')));
    const chunks = []; let size = 0; let status = 503;
    stream.on('response', headers => { status = Number(headers[':status']); });
    stream.on('data', value => { size += value.length; if (size > 4096) finish(Error('APNs response too large')); else chunks.push(value); });
    stream.on('error', finish);
    stream.on('end', () => { client.close(); resolve(new Response(Buffer.concat(chunks), { status })); });
    stream.end(options.body);
  });
}

export function createServices({ pool, authenticate, config = process.env, fetchImpl = fetch, signAgora,
  withDropbox = async (_identity, _action, work) => work() } = {}) {
  const internalKey = randomBytes(32).toString('hex');
  async function rpc(identity, name, args = {}, { service = false } = {}) {
    const statement = statements[name];
    if (!statement || privileged.has(name) !== service || !exact(args, statement[1])) throw Error('invalid_request');
    const anonymous = name === 'bound_username_available' && !identity;
    const claims = anonymous ? { role: 'anon' } : claimsFor(identity);
    if (service) {
      if (name === 'bound_dropbox_grant' && (args.payload?.owner !== claims.sub || args.payload?.session !== claims.session_id)) throw Error('unauthorized');
      if (['bound_jiggle_dispatch', 'bound_game_notification_dispatch'].includes(name) && args.sender !== claims.sub) throw Error('unauthorized');
      claims.role = 'service_role';
    }
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL statement_timeout='5s'");
      await client.query("SELECT set_config('request.jwt.claims',$1,true)", [JSON.stringify(claims)]);
      if (!anonymous) {
        await client.query(name === 'bound_account_mfa_allowed' ? 'SELECT cup117_private.assert_active(auth.uid())' :
          'SELECT public.bound_require_mfa(),cup117_private.assert_active(auth.uid())');
        const active = await client.query('SELECT EXISTS(SELECT 1 FROM auth.sessions WHERE id=$1 AND user_id=$2 AND not_after>now()) AS active', [claims.session_id, claims.sub]);
        if (active.rows[0]?.active !== true) throw Error('unauthorized');
      }
      const result = await client.query(statement[0], statement[1].map(key => ['payload'].includes(key) ? JSON.stringify(args[key]) : args[key]));
      await client.query('COMMIT');
      return result.rows[0]?.result ?? null;
    } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
    finally { client.release(); }
  }

  async function gameplay(request, identity) {
    let body;
    try { body = await readJSON(request, 512); } catch { return reply(400, { error: 'invalid_request' }); }
    const saves = body?.protocol === 'bound-saves-v1';
    if (saves ? !(exact(body, ['protocol']) || exact(body, ['protocol', 'roomID']) && uuid.test(body.roomID ?? '')) :
        !exact(body, ['roomID', 'protocol']) || !uuid.test(body.roomID) || body.protocol !== 'bound-room-v1') return reply(400, { error: 'invalid_request' });
    if (!config.PUBLIC_URL || !config.NAKAMA_HTTP_URL || (config.BOUND_NAKAMA_BRIDGE_SECRET?.length ?? 0) < 32) return reply(503, { error: 'not_configured' });
    try {
      const room = saves && !body.roomID ? null : await rpc(identity, 'bound_nakama_room_v1', { payload: { roomID: body.roomID } });
      const ownerID = claimsFor(identity).sub;
      const partnerID = room?.peerOwnerID ?? room?.peerID;
      if ((!saves || body.roomID) && (room?.ownerID !== ownerID || room.roomID !== body.roomID ||
          !Array.isArray(room.members) || room.members.length < 2 || room.members.length > 8 ||
          room.members.some(member => typeof member !== 'string' || !uuid.test(member) || member !== member.toLowerCase()) ||
          new Set(room.members).size !== room.members.length || !room.members.includes(ownerID) ||
          typeof partnerID !== 'string' || !uuid.test(partnerID) || partnerID === ownerID || !room.members.includes(partnerID))) return reply(403, { error: 'forbidden' });
      const now = Math.floor(Date.now() / 1000);
      const ticket = saves ? { version: 1, protocol: 'bound-saves-v1', ownerID, issuedAt: now, expiresAt: now + 90,
        ...(room ? { partnerID: room.peerOwnerID ?? room.peerID, roomID: room.roomID } : {}) } :
        { version: 1, protocol: body.protocol, ownerID, roomID: body.roomID, members: [...room.members].sort(), issuedAt: now, expiresAt: now + 90 };
      const encoded = Buffer.from(JSON.stringify(ticket)).toString('base64url');
      const joinTicket = encoded + '.' + createHmac('sha256', config.BOUND_NAKAMA_BRIDGE_SECRET).update(encoded).digest('hex');
      const token = identity.nakamaToken ?? identity.token;
      if (saves) {
        const fresh = await authenticate(request);
        if (claimsFor(fresh).sub !== ownerID) return reply(403, { error: 'forbidden' });
        if (room && JSON.stringify(await rpc(fresh, 'bound_nakama_room_v1', { payload: { roomID: body.roomID } })) !== JSON.stringify(room)) return reply(403, { error: 'forbidden' });
        if (await rpc(fresh, 'cup117_account_active') !== true) return reply(403, { error: 'forbidden' });
        const expiresAt = Math.min(now + 90, Number(identity.claims?.exp ?? now + 90));
        if (!Number.isSafeInteger(expiresAt) || expiresAt <= Math.floor(Date.now() / 1000) + 10) throw Error('expired issuance');
        return reply(200, { httpEndpoint: new URL(config.PUBLIC_URL).origin, accessToken: token, ownerID,
          expiresAt, saveTicket: joinTicket,
          ...(room ? { partnerID: ticket.partnerID, roomID: room.roomID } : {}) });
      }
      const upstream = await fetchImpl(new URL('/v2/rpc/bound_room_v1', config.NAKAMA_HTTP_URL), {
        method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify(JSON.stringify({ ticket: joinTicket })), redirect: 'error', signal: AbortSignal.timeout(5000),
      });
      if (!upstream.ok) throw Error('gameplay_unavailable');
      const raw = await readJSON(new Request('http://internal/response', { method: 'POST', headers: { 'content-type': 'application/json' }, body: upstream.body, duplex: 'half' }), 8192);
      const match = JSON.parse(raw.payload);
      if (match?.roomID !== body.roomID || match.protocol !== body.protocol || match.nakamaUserID !== ownerID ||
        typeof match.matchID !== 'string' || !/^[0-9a-f-]{36}\.[A-Za-z0-9_.-]{1,128}$/.test(match.matchID)) throw Error('gameplay_unavailable');
      const fresh = await authenticate(request);
      if (claimsFor(fresh).sub !== ownerID || JSON.stringify(await rpc(fresh, 'bound_nakama_room_v1', { payload: { roomID: body.roomID } })) !== JSON.stringify(room)) return reply(403, { error: 'forbidden' });
      const endpoint = new URL('/ws?format=json&status=false', config.PUBLIC_URL); endpoint.protocol = 'wss:';
      return reply(200, { endpoint: endpoint.toString(), httpEndpoint: new URL(config.PUBLIC_URL).origin,
        accessToken: token, expiresAt: Math.min(now + 90, Number(identity.claims?.exp ?? now + 90)),
        matchID: match.matchID, roomID: body.roomID, ownerID, nakamaUserID: ownerID,
        joinTicket, members: ticket.members, peerOwnerID: room.peerOwnerID ?? room.peerID });
    } catch { return reply(503, { error: 'gameplay_unavailable' }); }
  }

  async function handle(request) {
    const path = new URL(request.url).pathname;
    if (!path.startsWith('/rest/v1/rpc/') && !['/functions/v1/agora-token', '/functions/v1/bound-dropbox', '/functions/v1/bound-jiggle', '/functions/v1/nakama-session'].includes(path)) return null;
    if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    const name = path.split('/').pop();
    let identity;
    try {
      if (name !== 'bound_username_available' || request.headers.has('authorization')) identity =
        await authenticate(request, { allowMFA: name === 'bound_account_mfa_allowed' });
      if (!identity && name !== 'bound_username_available') return reply(401, { error: 'unauthorized' });
      if (identity) claimsFor(identity);
    } catch { return reply(401, { error: 'unauthorized' }); }
    if (path.startsWith('/rest/v1/rpc/')) {
      if (!Object.hasOwn(statements, name) || privileged.has(name)) return reply(404, { error: 'not_found' });
      try { return reply(200, await rpc(identity, name, await readJSON(request))); }
      catch (error) { return reply(error.message === 'invalid_request' ? 400 : 403, { error: error.message === 'invalid_request' ? 'invalid_request' : 'forbidden' }); }
    }
    if (name === 'nakama-session') return gameplay(request, identity);

    // Existing, reviewed feature handlers run unchanged. Their legacy URL is an
    // in-process dispatch key only: this adapter never contacts Supabase.
    const claims = claimsFor(identity);
    const compatibilityBearer = `Bearer ${Buffer.from('{}').toString('base64url')}.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.internal`;
    const adapter = async (url, options = {}) => {
      const target = new URL(url);
      if (target.origin !== legacyOrigin) {
        if (target.protocol !== 'https:' || !['api.dropboxapi.com', 'api.push.apple.com', 'api.sandbox.push.apple.com'].includes(target.hostname)) throw Error('unexpected_upstream');
        if (target.hostname.endsWith('push.apple.com') && fetchImpl === fetch) return apnsFetch(url, options);
        return fetchImpl(url, options);
      }
      const fresh = await authenticate(request);
      const current = claimsFor(fresh);
      if (current.sub !== claims.sub || current.session_id !== claims.session_id) throw Error('unauthorized');
      if (target.pathname === '/auth/v1/user') return reply(200, { ...fresh.user, id: current.sub,
        email: fresh.email ?? fresh.user?.email, email_confirmed_at: fresh.email_confirmed_at ?? fresh.user?.email_confirmed_at,
        is_anonymous: false, role: 'authenticated' });
      const rpcName = target.pathname.replace('/rest/v1/rpc/', '');
      if (target.pathname !== `/rest/v1/rpc/${rpcName}`) throw Error('unexpected_upstream');
      const service = new Headers(options.headers).get('authorization') === `Bearer ${internalKey}`;
      return reply(200, await rpc(fresh, rpcName, JSON.parse(options.body), { service }));
    };
    const headers = new Headers(request.headers); headers.set('authorization', compatibilityBearer);
    const adapted = new Request(request.url, { method: request.method, headers, body: request.body, duplex: 'half' });
    try {
      if (name === 'agora-token') {
        if (!config.AGORA_APP_ID || !config.AGORA_APP_CERTIFICATE) return reply(503, { error: 'not_configured' });
        let sign = signAgora;
        if (!sign) {
          const pkg = await import('agora-token');
          const { RtcTokenBuilder, RtcRole } = pkg.default ?? pkg;
          sign = ({ appID, certificate, channel, uid, ttl }) => RtcTokenBuilder.buildTokenWithUid(appID, certificate, channel, uid, RtcRole.PUBLISHER, ttl, ttl);
        }
        return await createTokenHandler({ appID: config.AGORA_APP_ID, certificate: config.AGORA_APP_CERTIFICATE,
          publishableKey: internalKey, rooms: {}, sign, fetchImpl: adapter })(adapted);
      }
      if (name === 'bound-dropbox') {
        let input;
        try { input = await readJSON(adapted.clone(), 4096); }
        catch { return reply(400, { error: 'invalid_request' }); }
        return await withDropbox(identity, input?.action, () => createDropboxHandler({ serviceKey: internalKey, publishableKey: internalKey,
          appKey: config.DROPBOX_APP_KEY, encryptionKey: config.DROPBOX_ENCRYPTION_KEY, fetchImpl: adapter })(adapted));
      }
      return await createJiggleHandler({ publishableKey: internalKey, serviceRoleKey: internalKey,
        apnsKeyID: config.APNS_KEY_ID, apnsTeamID: config.APNS_TEAM_ID, apnsPrivateKey: config.APNS_PRIVATE_KEY,
        apnsSandboxKeyID: config.APNS_SANDBOX_KEY_ID, apnsSandboxTeamID: config.APNS_SANDBOX_TEAM_ID, apnsSandboxPrivateKey: config.APNS_SANDBOX_PRIVATE_KEY,
        apnsProductionKeyID: config.APNS_PRODUCTION_KEY_ID, apnsProductionTeamID: config.APNS_PRODUCTION_TEAM_ID, apnsProductionPrivateKey: config.APNS_PRODUCTION_PRIVATE_KEY,
        fetchImpl: adapter })(adapted);
    } catch { return reply(503, { error: 'unavailable' }); }
  }
  return { handle, rpc, close: async () => {} };
}
