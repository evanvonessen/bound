import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fixture, owner, peer, third, roomID, plain } from './fixture.mjs';
const runID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const history = 'a'.repeat(64);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function setup() {
  const f = fixture(); let sequence = 0;
  f.nk.uuidv4 = () => `eeeeeeee-eeee-4eee-8eee-${String(++sequence).padStart(12, '0')}`;
  const identity = who => ({ run: runID.toUpperCase(), gameID: 'fixture', owner: who.toUpperCase(),
    partner: (who === owner ? peer : owner).toUpperCase(), roomID, settingsOwner: owner.toUpperCase(),
    settings: 'AA==', localSeed: who === owner ? 1 : 2, partnerSeed: who === owner ? 2 : 1,
    romSHA256: 'b'.repeat(64), protocolVersion: 1, saveVersion: 1 });
  const rpc = (who, action, fields = {}) => JSON.parse(f.runs.rpc({ ...f.ctx, userId: f.presence(who).userId }, f.logger, f.nk,
    JSON.stringify({ ticket: f.ticket(who), runID, action, ...fields })));
  const session = (who, fields = {}) => rpc(who, 'session', { identity: identity(who), history, bits: 'AA==', checkpoint: null, checkpointHistory: null, ...fields });
  const upload = (who, checkpoint, mutate = value => value) => {
    const payload = mutate({ version: 1, manifest: { identity: identity(who), deviceOwner: who },
      checkpoint: checkpoint.id.toUpperCase(), predecessor: checkpoint.predecessor, sharedEventDigest: checkpoint.history,
      files: { 'game.sav': { data: 'AA==', sha256: hash(Buffer.from([0])) }, 'checkpoint.state': { data: 'AA==', sha256: hash(Buffer.from([0])) } } });
    const bytes = Buffer.from(JSON.stringify(payload)), encoded = bytes.toString('base64');
    const receipt = { run: runID.toUpperCase(), checkpoint: checkpoint.id.toUpperCase(), owner: who.toUpperCase(),
      payloadSHA256: hash(bytes), sharedEventDigest: checkpoint.history };
    const fields = { checkpoint: checkpoint.id, receipt, count: Math.ceil(encoded.length / 12000), bytes: bytes.length };
    rpc(who, 'prepare', { checkpoint: checkpoint.id, history: checkpoint.history });
    rpc(who, 'upload', fields);
    for (let i = 0; i < fields.count; i++) rpc(who, 'chunk', { ...fields, index: i, data: encoded.slice(i * 12000, (i + 1) * 12000) });
    return { fields, bytes, seal: () => rpc(who, 'seal', fields) };
  };
  return { f, rpc, session, identity, upload };
}

test('idle run registration and history updates never create a game save', () => {
  const { f, session } = setup();
  for (let i = 0; i < 20; i++) { session(owner); session(peer); }
  assert.equal(f.stored.get(runID).value.pending, null);
  assert.equal(f.stored.get(runID).value.head, null);
  assert.equal(f.stored.size, 1);
  assert.equal(f.stored.get(runID).value.revision, 2, 'identical polling does not write storage');
  assert.equal(f.stored.get(runID).permissionWrite, 0);
});
test('server allocates one checkpoint for concurrent explicit save requests; both uploads must be durable', () => {
  const { rpc, session, upload } = setup(); session(owner); session(peer);
  const first = rpc(owner, 'begin', { history, predecessor: null });
  assert.deepEqual(rpc(peer, 'begin', { history, predecessor: null }).pending, first.pending);
  const a = upload(owner, first.pending); assert.equal(a.seal().head, null);
  const b = upload(peer, first.pending); const committed = b.seal();
  assert.equal(committed.pending, null); assert.equal(committed.head.id, first.pending.id);
  assert.equal(Object.keys(committed.head.uploads).length, 2);
  assert.equal(a.seal().head.id, first.pending.id, 'lost acknowledgement can be retried');
  const downloaded = rpc(owner, 'download', { checkpoint: first.pending.id, index: 0 });
  assert.deepEqual(Buffer.from(downloaded.data, 'base64'), a.bytes);
});
test('server head and partial transactions survive a new handler and expired room sockets', () => {
  const { f, rpc, session, upload } = setup(); session(owner); session(peer);
  const pending = rpc(owner, 'begin', { history, predecessor: null }).pending;
  upload(owner, pending).seal(); f.now(1200);
  const restored = session(peer);
  assert.equal(restored.pending.id, pending.id);
  assert.ok(restored.pending.uploads[owner]);
  assert.equal(upload(peer, pending).seal().head.id, pending.id);
});
test('cross-account reads, configuration changes, wrong history and wrong ancestry fail closed', () => {
  const { rpc, session, identity } = setup(); session(owner); session(peer);
  assert.throws(() => rpc(third, 'download', { checkpoint: runID, index: 0 }));
  assert.throws(() => session(owner, { identity: { ...identity(owner), localSeed: 99 } }));
  assert.throws(() => rpc(owner, 'begin', { history: 'c'.repeat(64), predecessor: null }));
  assert.throws(() => rpc(owner, 'begin', { history, predecessor: runID }));
});
test('tampered, missing, or conflicting upload chunks cannot publish a checkpoint', () => {
  const { rpc, session, upload } = setup(); session(owner); session(peer);
  const pending = rpc(owner, 'begin', { history, predecessor: null }).pending;
  const a = upload(owner, pending);
  assert.throws(() => rpc(owner, 'chunk', { ...a.fields, index: 0, data: 'x'.repeat(Math.ceil(a.bytes.length / 3) * 4) }));
  assert.throws(() => rpc(owner, 'seal', { ...a.fields, receipt: { ...a.fields.receipt, payloadSHA256: '0'.repeat(64) } }));
  assert.throws(() => rpc(owner, 'cancel', { checkpoint: pending.id }), 'uploaded preparation cannot be cancelled');
  assert.equal(session(owner).head, null);
});
test('cancels a save only before durable uploads and never reuses the cancelled identifier', () => {
  const { rpc, session } = setup(); session(owner); session(peer);
  const pending = rpc(owner, 'begin', { history, predecessor: null }).pending;
  assert.equal(rpc(peer, 'cancel', { checkpoint: pending.id }).pending, null);
  assert.notEqual(rpc(owner, 'begin', { history, predecessor: null }).pending.id, pending.id);
});
test('retains a last pose across socket replacement and reloads it as stale presentation only', () => {
  const f = fixture(); f.join(); f.join(peer); f.broadcasts.length = 0;
  const body = JSON.stringify({ version: 1, pose: { x: 104 } });
  f.loop([f.message(owner, 1, f.frame(body, peer))]);
  f.api.match.matchLeave(f.ctx, f.logger, f.nk, f.dispatcher, 0, f.state, [f.presence(owner)]);
  assert.ok(f.stored.get(roomID).value.positions[owner]);
  const fresh = f.api.match.matchInit(f.ctx, f.logger, f.nk, { roomID, members: [owner, peer], cleanupToken: 'restart' }).state;
  f.broadcasts.length = 0;
  const p = f.presence(peer, 2);
  f.api.match.matchJoinAttempt(f.ctx, f.logger, f.nk, f.dispatcher, 0, fresh, p, { bound_ticket: f.ticket(peer) });
  f.api.match.matchJoin(f.ctx, f.logger, f.nk, f.dispatcher, 0, fresh, [p]);
  assert.equal(f.broadcasts[0].opcode, 6);
  assert.equal(Buffer.from(f.broadcasts[0].data.positions[0].body, 'base64').toString(), body);
  assert.equal(f.broadcasts[0].sender, null, 'snapshot originates at server, never forged as a live peer packet');
});

test('persistent event history cannot be rolled back by a reconnecting client', () => {
  const { session } = setup(); session(owner);
  session(owner, { bits: Buffer.from([1]).toString('base64'), history: 'c'.repeat(64) });
  assert.throws(() => session(owner), /./);
  assert.throws(() => session(owner, { bits: Buffer.from([1]).toString('base64'), history: 'd'.repeat(64) }), /./);
});
test('commits successive checkpoints with verified ancestry', () => {
  const { rpc, session, upload } = setup(); session(owner); session(peer);
  const first = rpc(owner, 'begin', { history, predecessor: null }).pending;
  upload(owner, first).seal(); upload(peer, first).seal();
  assert.throws(() => rpc(owner, 'begin', { history, predecessor: null }));
  const next = rpc(owner, 'begin', { history, predecessor: first.id }).pending;
  upload(owner, next).seal(); const final = upload(peer, next).seal();
  assert.equal(final.head.predecessor, first.id);
});

test('explicit end is idempotent and the ended run cannot start another save', () => {
  const { rpc, session } = setup(); session(owner); session(peer);
  assert.equal(rpc(owner, 'end').ended, true);
  assert.equal(rpc(owner, 'end').ended, true);
  assert.equal(session(peer).ended, true);
  assert.throws(() => rpc(peer, 'begin', { history, predecessor: null }));
});

test('a capture reservation fences cancellation before any bytes are written', () => {
  const { rpc, session } = setup(); session(owner); session(peer);
  const pending = rpc(owner, 'begin', { history, predecessor: null }).pending;
  rpc(owner, 'prepare', { checkpoint: pending.id, history });
  assert.throws(() => rpc(peer, 'cancel', { checkpoint: pending.id }));
  const next = session(peer);
  assert.equal(next.head, null); assert.equal(Object.keys(next.pending.uploads).length, 0);
  assert.equal(next.pending.reservations[owner], true);
});

test('JSONB key reordering does not rewrite polling state or reject upload retries', () => {
  const { f, rpc, session, upload } = setup(); session(owner); session(peer);
  const original = f.nk.storageRead;
  const reorder = value => Array.isArray(value) ? value.map(reorder) : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).reverse().map(key => [key, reorder(value[key])])) : value;
  f.nk.storageRead = refs => original(refs).map(value => ({ ...value, value: reorder(value.value) }));
  const before = session(owner).revision;
  assert.equal(session(owner).revision, before);
  const pending = rpc(owner, 'begin', { history, predecessor: null }).pending;
  upload(owner, pending).seal();
  assert.equal(upload(peer, pending).seal().head.id, pending.id);
});
