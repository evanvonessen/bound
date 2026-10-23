// Run only against an explicitly started, isolated local Nakama instance using
// synthetic secrets and a disposable database. No SDK or live account needed.
import assert from 'node:assert/strict';
import { createHmac, randomUUID } from 'node:crypto';

const origin = new URL(process.env.BOUND_NAKAMA_SMOKE_URL ?? 'http://127.0.0.1:57350');
if (origin.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(origin.hostname) || origin.pathname !== '/') {
  throw Error('Local smoke requires a localhost-only HTTP endpoint');
}
const secret = 'synthetic-local-smoke-bridge-secret-123456';
const serverKey = 'synthetic-local-server-key';
const owners = [randomUUID(), randomUUID(), randomUUID()];
const roomID = randomUUID(); const members = [...owners].sort(); const sockets = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const checks = [];
const check = label => { checks.push(label); console.log('PASS ' + label); };
const current = () => Math.floor(Date.now() / 1000);
const ticket = (ownerID, seconds = 90, overrides = {}) => {
  const payload = Buffer.from(JSON.stringify({ version: 1, protocol: 'bound-room-v1', ownerID,
    roomID, members, issuedAt: current(), expiresAt: current() + seconds, ...overrides })).toString('base64url');
  return payload + '.' + createHmac('sha256', secret).update(payload).digest('hex');
};
const http = async (path, payload, token) => {
  const response = await fetch(new URL(path, origin), { method: 'POST', headers: {
    Authorization: token ? 'Bearer ' + token : 'Basic ' + Buffer.from(serverKey + ':').toString('base64'),
    'Content-Type': 'application/json',
  }, body: JSON.stringify(payload), signal: AbortSignal.timeout(5000) });
  return { status: response.status, body: await response.json() };
};
const auth = async (ownerID, admission) => {
  const result = await http('/v2/account/authenticate/custom?create=true', { id: 'bound:' + ownerID, vars: { bound_ticket: admission } });
  assert.equal(result.status, 200, 'signed custom authentication');
  assert.equal(typeof result.body.token, 'string'); return result.body;
};
const resolve = async (session, admission) => {
  const result = await http('/v2/rpc/bound_room_v1', JSON.stringify({ ticket: admission }), session.token);
  assert.equal(result.status, 200, 'authorized room RPC'); return JSON.parse(result.body.payload);
};

class Socket {
  constructor(socket) {
    this.ws = socket; this.messages = []; this.waiters = []; this.nextCID = 0;
    socket.addEventListener('message', event => {
      const message = JSON.parse(String(event.data));
      const waiter = this.waiters.find(item => item.predicate(message));
      if (waiter) { this.waiters.splice(this.waiters.indexOf(waiter), 1); clearTimeout(waiter.timer); waiter.resolve(message); }
      else this.messages.push(message);
    });
  }
  static async connect(token) {
    const endpoint = new URL('/ws', origin); endpoint.protocol = 'ws:';
    endpoint.search = new URLSearchParams({ format: 'json', status: 'false', token }).toString();
    const socket = new WebSocket(endpoint); const client = new Socket(socket); sockets.push(client);
    await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
    return client;
  }
  wait(predicate, timeout = 5000) {
    const index = this.messages.findIndex(predicate);
    if (index >= 0) return Promise.resolve(this.messages.splice(index, 1)[0]);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, timer: setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(waiter), 1); reject(Error('Timed out waiting for a local Nakama response; queued messages: ' + JSON.stringify(this.messages)));
      }, timeout) }; this.waiters.push(waiter);
    });
  }
  async request(body) {
    const cid = String(++this.nextCID); const response = this.wait(message => message.cid === cid);
    this.ws.send(JSON.stringify({ cid, ...body })); return response;
  }
  async join(matchID, admission) {
    const result = await this.request({ match_join: { match_id: matchID, metadata: { bound_ticket: admission } } });
    assert.ok(result.match, 'join must return a match: ' + JSON.stringify(result));
  }
  send(matchID, opcode, envelope) {
    this.ws.send(JSON.stringify({ match_data_send: { match_id: matchID, op_code: String(opcode),
      data: Buffer.from(JSON.stringify(envelope)).toString('base64'), reliable: opcode !== 1 } }));
  }
  frame(matchID, opcode, bytes, targetOwnerID) {
    this.send(matchID, opcode, { v: 1, body: Buffer.from(bytes).toString('base64'), ...(targetOwnerID ? { targetOwnerID } : {}) });
  }
  data(opcode, predicate = () => true, timeout) {
    return this.wait(message => message.match_data && Number(message.match_data.op_code) === opcode &&
      predicate(JSON.parse(Buffer.from(message.match_data.data, 'base64'))), timeout)
      .then(message => JSON.parse(Buffer.from(message.match_data.data, 'base64')));
  }
  close() { if (this.ws.readyState < WebSocket.CLOSING) this.ws.close(); }
}

try {
  const deniedDevice = await http('/v2/account/authenticate/device?create=true', { id: randomUUID() });
  assert.equal(deniedDevice.status, 403);
  const deniedCustom = await http('/v2/account/authenticate/custom?create=true', { id: 'bound:' + owners[0] });
  assert.equal(deniedCustom.status, 403);
  const wrongOwner = await http('/v2/account/authenticate/custom?create=true', { id: 'bound:' + owners[1], vars: { bound_ticket: ticket(owners[0]) } });
  assert.equal(wrongOwner.status, 403); check('alternate, unsigned and impersonated authentication rejected');

  const admissions = owners.map((ownerID, index) => ticket(ownerID, index === 1 ? 90 : 8));
  const sessions = await Promise.all(owners.map((ownerID, index) => auth(ownerID, admissions[index])));
  const rooms = await Promise.all(sessions.map((session, index) => resolve(session, admissions[index])));
  assert.equal(new Set(rooms.map(room => room.matchID)).size, 1);
  const matchID = rooms[0].matchID; check('three concurrent accounts resolve the same authoritative room');

  const clients = await Promise.all(sessions.map(session => Socket.connect(session.token)));
  await Promise.all(clients.map((client, index) => client.join(matchID, admissions[index])));
  await clients[1].data(4, roster => roster.members.length === 3 && roster.members.every(member => member.online));
  check('three real WebSocket clients join and receive the authorized roster');

  const relayed = await clients[0].request({ match_create: { name: 'forbidden-client-room' } });
  assert.ok(relayed.error); check('client-created relay matches rejected');

  clients.forEach(client => { client.messages.length = 0; });
  clients[0].frame(matchID, 1, 'latest-position');
  const position = await clients[1].data(1);
  assert.equal(position.senderOwnerID, owners[0]); assert.equal(Buffer.from(position.body, 'base64').toString(), 'latest-position');
  await clients[2].data(1); await sleep(100);
  assert.ok(!clients[0].messages.some(message => Number(message.match_data?.op_code) === 1));
  check('movement reaches other players with a trusted sender and no self echo');

  const battle = Uint8Array.from({ length: 8192 }, (_, index) => index % 256);
  clients[0].frame(matchID, 3, battle, owners[1]);
  const received = await clients[1].data(3);
  assert.deepEqual(Buffer.from(received.body, 'base64'), Buffer.from(battle));
  await sleep(100); assert.ok(!clients[2].messages.some(message => Number(message.match_data?.op_code) === 3));
  check('maximum-size binary battle payload survives JSON framing and reaches only its target');

  clients[0].send(matchID, 5, { v: 1, ticket: ticket(owners[0]) });
  const outsider = randomUUID(); const outsiderTicket = ticket(outsider, 90, { roomID: randomUUID(), members: [outsider, owners[0]].sort() });
  const outsiderSession = await auth(outsider, outsiderTicket); const outsiderClient = await Socket.connect(outsiderSession.token);
  const outsiderJoin = await outsiderClient.request({ match_join: { match_id: matchID, metadata: { bound_ticket: outsiderTicket } } });
  assert.ok(outsiderJoin.error); check('valid account with a different signed room cannot join');

  clients[1].messages.length = 0;
  const expiredRoster = await clients[1].data(4, roster => roster.members.find(member => member.ownerID === owners[2])?.online === false, 11000);
  assert.equal(expiredRoster.members.find(member => member.ownerID === owners[0]).online, true);
  clients[0].frame(matchID, 2, 'after-renewal');
  const event = await clients[1].data(2);
  assert.equal(Buffer.from(event.body, 'base64').toString(), 'after-renewal');
  check('unrenewed membership expires while renewed admission keeps its existing socket active');

  clients[0].send(matchID, 2, { v: 1, body: Buffer.from('forged').toString('base64'), senderOwnerID: owners[1] });
  await clients[1].data(4, roster => roster.members.find(member => member.ownerID === owners[0])?.online === false);
  assert.ok(!clients[1].messages.some(message => Number(message.match_data?.op_code) === 2));
  check('sender forgery removes the session without forwarding its payload');

  console.log(JSON.stringify({ passed: checks.length, backend: 'Nakama 3.41.0', scope: 'isolated localhost HTTP/WebSocket; synthetic accounts only' }));
} finally {
  sockets.forEach(client => client.close());
}
