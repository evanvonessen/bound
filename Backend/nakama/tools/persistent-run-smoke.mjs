// Synthetic integration test. Use an isolated local Nakama/database, never a
// live account backend. Credentials match tools/local-smoke.mjs fixtures only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { randomUUID, createHmac, createHash } from 'node:crypto';
const origin = new URL(process.env.BOUND_NAKAMA_SMOKE_URL ?? 'http://127.0.0.1:57350');
if (origin.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(origin.hostname) || origin.pathname !== '/') throw Error('Isolated localhost Nakama required');
const receiptPath = process.env.BOUND_NAKAMA_SMOKE_RECEIPT;
const resumed = process.env.BOUND_NAKAMA_SMOKE_RESTORE === '1' ? JSON.parse(fs.readFileSync(receiptPath, 'utf8')) : null;
const owners = resumed?.owners ?? [randomUUID(), randomUUID(), randomUUID()].sort(), room = resumed?.room ?? randomUUID(), run = resumed?.run ?? randomUUID();
const key = 'synthetic-local-server-key', secret = 'synthetic-local-smoke-bridge-secret-123456';
const hash = value => createHash('sha256').update(value).digest('hex');
const ticket = owner => {
  const now = Math.floor(Date.now() / 1000);
  const data = Buffer.from(JSON.stringify({ version: 1, protocol: 'bound-room-v1', ownerID: owner, roomID: room,
    members: owners, issuedAt: now, expiresAt: now + 90 })).toString('base64url');
  return data + '.' + createHmac('sha256', secret).update(data).digest('hex');
};
async function post(path, body, token) {
  const response = await fetch(new URL(path, origin), { method: 'POST', headers: { 'Content-Type': 'application/json',
    Authorization: token ? 'Bearer ' + token : 'Basic ' + Buffer.from(key + ':').toString('base64') },
    body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
  const value = await response.json();
  if (!response.ok) throw Error(path + ' HTTP ' + response.status + ' ' + JSON.stringify(value));
  return value;
}
const sessions = resumed?.sessions ?? await Promise.all(owners.map(owner => post('/v2/account/authenticate/custom?create=true', { id: 'bound:' + owner, vars: { bound_ticket: ticket(owner) } })));
const rpc = async (index, action, fields = {}) => JSON.parse((await post('/v2/rpc/bound_run_v1',
  JSON.stringify({ ticket: ticket(owners[index]), runID: run, action, ...fields }), sessions[index].token)).payload);
async function verifyRoomPresence(index, publish = false) {
  const roomInfo = JSON.parse((await post('/v2/rpc/bound_room_v1', JSON.stringify({ ticket: ticket(owners[index]) }), sessions[index].token)).payload);
  const endpoint = new URL('/ws', origin); endpoint.protocol = 'ws:';
  endpoint.search = new URLSearchParams({ format: 'json', status: 'false', token: sessions[index].token }).toString();
  const socket = new WebSocket(endpoint), queued = [], pending = [];
  socket.addEventListener('message', event => {
    const message = JSON.parse(String(event.data)); const found = pending.find(waiter => waiter.matches(message));
    if (found) { pending.splice(pending.indexOf(found), 1); clearTimeout(found.timer); found.resolve(message); }
    else queued.push(message);
  });
  const wait = matches => {
    const index = queued.findIndex(matches); if (index >= 0) return Promise.resolve(queued.splice(index, 1)[0]);
    return new Promise((resolve, reject) => { const waiter = { matches, resolve, timer: setTimeout(() => reject(Error('Room snapshot timed out')), 5000) }; pending.push(waiter); });
  };
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  try {
    const joined = wait(message => message.cid === 'join');
    socket.send(JSON.stringify({ cid: 'join', match_join: { match_id: roomInfo.matchID, metadata: { bound_ticket: ticket(owners[index]) } } }));
    assert.ok((await joined).match);
    if (publish) {
      const body = Buffer.from(JSON.stringify({ version: 1, pose: { x: 104 }, sequence: 1 })).toString('base64');
      socket.send(JSON.stringify({ match_data_send: { match_id: roomInfo.matchID, op_code: '1', reliable: false,
        data: Buffer.from(JSON.stringify({ v: 1, body, targetOwnerID: owners[1] })).toString('base64') } }));
      await new Promise(resolve => setTimeout(resolve, 200));
    } else {
      const message = await wait(message => Number(message.match_data?.op_code) === 6);
      const snapshot = JSON.parse(Buffer.from(message.match_data.data, 'base64'));
      assert.equal(snapshot.positions[0].ownerID, owners[0]);
      assert.equal(JSON.parse(Buffer.from(snapshot.positions[0].body, 'base64')).pose.x, 104);
    }
  } finally { socket.close(); }
}
const history = hash(Buffer.from([0]));
const identity = i => ({ run, gameID: 'synthetic-smoke', owner: owners[i], partner: owners[1 - i], roomID: room,
  settingsOwner: owners[0], settings: 'AA==', localSeed: i + 1, partnerSeed: 2 - i, romSHA256: 'b'.repeat(64), protocolVersion: 1, saveVersion: 1 });
if (resumed) {
  const state = await rpc(0, 'session', { identity: identity(0), history, bits: 'AA==', checkpoint: null, checkpointHistory: null });
  assert.equal(state.head.id, resumed.checkpoint);
  assert.ok((await rpc(0, 'download', { checkpoint: resumed.checkpoint, index: 0 })).data.length > 0);
  await verifyRoomPresence(1);
  console.log('PASS real Nakama restart: persistent run head, saved chunks, and retained player position restored');
  process.exit(0);
}
for (let i = 0; i < 2; i++) {
  const state = await rpc(i, 'session', { identity: identity(i), history, bits: 'AA==', checkpoint: null, checkpointHistory: null });
  assert.equal(state.head, null); assert.equal(state.pending, null);
}
const save = await rpc(0, 'begin', { history, predecessor: null }); assert.ok(save.pending.id);
const checkpoint = save.pending.id;
for (let i = 0; i < 2; i++) {
  const battery = Buffer.alloc(131072, i), snapshot = Buffer.alloc(131072, 7);
  const payload = { version: 1, manifest: { identity: identity(i), deviceOwner: owners[i] }, checkpoint, predecessor: null, sharedEventDigest: history,
    files: { 'game.sav': { data: battery.toString('base64'), sha256: hash(battery) }, 'checkpoint.state': { data: snapshot.toString('base64'), sha256: hash(snapshot) } } };
  const bytes = Buffer.from(JSON.stringify(payload)), encoded = bytes.toString('base64'), count = Math.ceil(encoded.length / 12000);
  const fields = { checkpoint, receipt: { run, checkpoint, owner: owners[i], payloadSHA256: hash(bytes), sharedEventDigest: history }, bytes: bytes.length, count };
  await rpc(i, 'prepare', { checkpoint, history });
  await rpc(i, 'upload', fields);
  for (let n = 0; n < count; n++) await rpc(i, 'chunk', { ...fields, index: n, data: encoded.slice(n * 12000, (n + 1) * 12000) });
  const state = await rpc(i, 'seal', fields); assert.equal(state.head?.id ?? null, i === 0 ? null : checkpoint);
}
const committed = await rpc(0, 'session', { identity: identity(0), history, bits: 'AA==', checkpoint: null, checkpointHistory: null });
assert.equal(committed.head.id, checkpoint); assert.equal(committed.pending, null);
const first = await rpc(0, 'download', { checkpoint, index: 0 }); assert.ok(first.data.length > 0);
await assert.rejects(rpc(2, 'download', { checkpoint, index: 0 }));
await verifyRoomPresence(0, true);
if (receiptPath) fs.writeFileSync(receiptPath, JSON.stringify({ owners, room, run, sessions, checkpoint }), { mode: 0o600 });
console.log('PASS real Nakama: authenticated runs, no implicit saves, multipart checksums, paired commit, recovery download, outsider rejection');
