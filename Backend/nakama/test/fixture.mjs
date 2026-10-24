import fs from 'node:fs';
import vm from 'node:vm';
import { createHmac, createHash } from 'node:crypto';

export const owner = '11111111-1111-4111-8111-111111111111';
export const peer = '22222222-2222-4222-8222-222222222222';
export const third = '33333333-3333-4333-8333-333333333333';
export const roomID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
export const secret = 'synthetic-fixture-bridge-secret-123456789';
export const members = [owner, peer];
export const plain = value => JSON.parse(JSON.stringify(value));
const buffer = bytes => Uint8Array.from(bytes).buffer;

export function fixture(roomMembers = members) {
  let now = 1000; let nextMatch = 0; let version = 0;
  const logs = []; const broadcasts = []; const kicks = []; const registrations = {};
  const active = new Map(); const stored = new Map(); const discarded = [];
  const presence = (ownerID, session = 1) => ({ userId: 'nakama-' + ownerID, sessionId: ownerID + ':' + session, node: 'fixture', username: 'fixture' });
  const ctx = { env: { BOUND_NAKAMA_BRIDGE_SECRET: secret }, userId: presence(owner).userId };
  const logger = { info: (...values) => logs.push(values) };
  const nk = {
    hmacSha256Hash: (input, key) => buffer(createHmac('sha256', key).update(input).digest()),
    base16Encode: input => Buffer.from(input).toString('hex'),
    base64UrlDecode: input => buffer(Buffer.from(input, 'base64url')),
    base64Decode: input => buffer(Buffer.from(input, 'base64')),
    sha256Hash: input => createHash('sha256').update(input).digest('hex'),
    base64UrlEncode: input => Buffer.from(input).toString('base64url'),
    binaryToString: input => Buffer.from(input).toString('utf8'),
    accountGetId: userID => ({ customId: userID.startsWith('nakama-') ? 'bound:' + userID.slice(7) : 'unbound' }),
    uuidv4: () => 'fixture-cleanup-' + nextMatch,
    matchCreate: (_handler, params) => {
      const matchID = `cccccccc-cccc-4ccc-8ccc-${String(++nextMatch).padStart(12, '0')}.fixture`;
      active.set(matchID, { matchId: matchID, authoritative: true, params: plain(params) });
      return matchID;
    },
    matchGet: id => active.get(id) ?? null,
    matchSignal: (id, signal) => { active.delete(id); discarded.push({ id, signal: JSON.parse(signal) }); },
    storageRead: reads => reads.flatMap(read => {
      const key = ['bound_independent_v2', 'bound_events_v2'].includes(read.collection) ? read.collection + ':' + read.key : read.key;
      return stored.has(key) ? [stored.get(key)] : [];
    }),
    storageWrite: writes => writes.map(write => {
      const key = ['bound_independent_v2', 'bound_events_v2'].includes(write.collection) ? write.collection + ':' + write.key : write.key;
      const current = stored.get(key);
      if ((write.version === '*' && current) || (write.version && write.version !== '*' && current?.version !== write.version)) throw Error('CAS conflict');
      const record = { ...plain(write), version: String(++version) };
      stored.set(key, record); return record;
    }),
  };
  const dispatcher = {
    broadcastMessage: (opcode, data, recipients, sender, reliable) => broadcasts.push({ opcode, data: JSON.parse(data), recipients: plain(recipients), sender: plain(sender), reliable }),
    matchKick: presences => kicks.push(...plain(presences)),
  };
  const context = vm.createContext({ Date: class extends Date { static now() { return now * 1000; } } });
  vm.runInContext(fs.readFileSync(new URL('../build/index.js', import.meta.url), 'utf8'), context);
  const api = context.BoundRooms;
  const ticket = (ownerID = owner, fields = {}) => {
    const claims = { version: 1, protocol: api.protocol, ownerID, roomID, members: roomMembers, issuedAt: Math.floor(now), expiresAt: Math.floor(now) + 90, ...fields };
    const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
    return payload + '.' + createHmac('sha256', secret).update(payload).digest('hex');
  };
  let state = api.match.matchInit(ctx, logger, nk, { roomID, members: roomMembers, cleanupToken: 'cleanup' }).state;
  const join = (ownerID = owner, session = 1, value = ticket(ownerID)) => {
    const p = presence(ownerID, session);
    const result = api.match.matchJoinAttempt(ctx, logger, nk, dispatcher, 0, state, p, { bound_ticket: value });
    if (result.accept) state = api.match.matchJoin(ctx, logger, nk, dispatcher, 0, state, [p]).state;
    return result;
  };
  const message = (ownerID, opCode, frame, session = 1) => ({ sender: presence(ownerID, session), opCode, data: buffer(Buffer.from(JSON.stringify(frame))), reliable: opCode !== 1 });
  const frame = (body = 'fixture', targetOwnerID) => ({ v: 1, body: Buffer.from(body).toString('base64'), ...(targetOwnerID ? { targetOwnerID } : {}) });
  const loop = messages => api.match.matchLoop(ctx, logger, nk, dispatcher, 0, state, messages);
  const init = () => context.InitModule(ctx, logger, nk, new Proxy({}, { get: (_target, name) => (...args) => { registrations[name] = args; } }));
  return { api, runs: context.BoundRuns, independent: context.BoundIndependent, accounts: context.BoundAccounts, ctx, logger, nk, dispatcher, logs, broadcasts, kicks, registrations, active, stored, discarded,
    ticket, join, message, frame, loop, init, state, presence, now: value => { now = value; } };
}
