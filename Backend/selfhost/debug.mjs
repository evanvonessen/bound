import { createHash, createHmac } from 'node:crypto';
import { readJSON, reply, uuid } from './services.mjs';

export function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value !== null && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
export function createDebug({ authenticate, nakama, rpc, config }) {
  const enabled = config.BOUND_DEBUG_MODE === 'local';
  async function dispatch(identity, request, room = null) {
    const authorization = { ownerID: identity.ownerID, sessionID: identity.sessionID, sessionVersion: identity.record.version,
      accessHash: identity.record.value.accessHash, expiresAt: Math.floor(Date.now() / 1000) + 20,
      requestSHA256: createHash('sha256').update(canonical({ request, room })).digest('hex') };
    const signature = createHmac('sha256', config.BOUND_DEBUG_GATEWAY_SECRET).update(canonical(authorization)).digest('hex');
    return nakama.debug({ request, room, authorization, signature });
  }
  return { async handle(request) {
    if (new URL(request.url).pathname !== '/functions/v1/bound-debug') return null;
    if (!enabled) return reply(404, { error: 'not_found' });
    if (request.method !== 'POST') return reply(405, { error: 'method' });
    try {
      const origin = request.headers.get('origin');
      if (origin && origin !== new URL(config.PUBLIC_URL).origin) return reply(403, { error: 'forbidden' });
      let identity = await authenticate(request);
      if (!config.BOUND_DEBUG_ALLOWED_OWNERS.split(',').includes(identity.ownerID)) return reply(403, { error: 'debug_forbidden' });
      const input = await readJSON(request, 65536);
      if (!input || typeof input !== 'object' || Array.isArray(input) || typeof input.action !== 'string') return reply(400, { error: 'debug_request' });
      let room = null;
      if (input.action === 'create' || input.action === 'join') {
        let roomID = input.roomID;
        if (input.action === 'join') {
          if (!uuid.test(input.sessionID ?? '')) return reply(400, { error: 'debug_request' });
          roomID = (await dispatch(identity, { action: 'status', sessionID: input.sessionID })).session?.roomID;
        }
        if (!uuid.test(roomID ?? '')) return reply(400, { error: 'debug_request' });
        room = await rpc(identity, 'bound_nakama_room_v1', { payload: { roomID } });
      }
      // Friendship lookup may await SQL. Refresh the exact auth journal used by
      // the private runtime CAS proof; never copy trusted fields from input.
      const fresh = await authenticate(request);
      if (fresh.ownerID !== identity.ownerID || fresh.sessionID !== identity.sessionID) return reply(401, { error: 'unauthorized' });
      identity = fresh;
      const result = await dispatch(identity, input, room);
      if (input.action === 'realtime') {
        const endpoint = new URL('/ws?format=json&status=false', config.PUBLIC_URL); endpoint.protocol = 'wss:';
        result.realtime = { ...result.realtime, endpoint: endpoint.toString(), httpEndpoint: new URL(config.PUBLIC_URL).origin,
          accessToken: identity.nakamaToken, ownerID: identity.ownerID, nakamaUserID: identity.nakamaUserID,
          members: result.session.owners, peerOwnerID: result.session.owners.find(id => id !== identity.ownerID),
          joinTicket: result.realtime.ticket, sessionID: result.session.sessionID,
          membershipEpoch: result.session.membershipEpoch, generation: input.generation };
        delete result.realtime.ticket;
      }
      return reply(200, result);
    } catch (error) {
      const status = ({ 3: 400, 7: 403, 9: 409, 10: 409, 16: 401 }[error.code]) ?? error.status ?? (error.message === 'invalid_request' ? 400 : 503);
      const code = /^debug_[a-z_]+$/.test(error.message ?? '') ? error.message : status === 401 ? 'unauthorized' : status === 409 ? 'debug_conflict' : 'debug_unavailable';
      return reply(status, { error: code });
    }
  } };
}
