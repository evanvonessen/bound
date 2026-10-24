import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fixture, owner, peer, third, roomID, plain } from './fixture.mjs';

const runID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const hash = data => createHash('sha256').update(data).digest('hex');
const history = 'a'.repeat(64);
const checkpoint = n => `dddddddd-dddd-4ddd-8ddd-${String(n).padStart(12, '0')}`;
const settings = () => {
  const bytes = Buffer.alloc(32); bytes[0] = 4; bytes[1] = 1;
  bytes.set([193, 213, 230, 237, 255, 255, 255, 255], 12);
  return bytes.toString('base64');
};
function setup() {
  const f = fixture();
  const identity = (who, fields = {}) => ({ run: runID.toUpperCase(), gameID: 'local-' + who, owner: who.toUpperCase(),
    partner: (who === owner ? peer : owner).toUpperCase(), roomID, settingsOwner: owner.toUpperCase(),
    settings: settings(), localSeed: who === owner ? 1 : 2, partnerSeed: who === owner ? 2 : 1,
    romSHA256: 'b'.repeat(64), protocolVersion: 1, saveVersion: 1, ...fields });
  const rpc = (who, action, fields = {}) => JSON.parse(f.independent.rpc({ ...f.ctx, userId: f.presence(who).userId }, f.logger, f.nk,
    JSON.stringify({ ticket: f.ticket(who), runID, action, ...fields })));
  const commit = () => { rpc(owner, 'setup', { identity: identity(owner) }); return rpc(owner, 'commit', { identity: identity(owner), epoch: 1 }); };
  const event = (who, sequence, fields = {}) => ({ run: runID.toUpperCase(), id: { origin: who.toUpperCase(), sequence },
    kind: 'soul-link', payload: Buffer.from(JSON.stringify({ run: runID, kind: 'death', slot: 'area:' + sequence })).toString('base64'),
    idempotencyKey: 'death:area:' + sequence, ...fields });
  const events = (who, batch = [], after = {}) => rpc(who, 'events', { events: batch, after });
  const upload = (who, id, expectedHead = null, change = value => value) => {
    const payload = change({ version: 2, manifest: { identity: identity(who), deviceOwner: who }, checkpoint: id,
      predecessor: expectedHead, sharedEventDigest: history,
      files: { 'game.sav': { data: 'AA==', sha256: hash(Buffer.from([0])) }, 'checkpoint.state': { data: 'AA==', sha256: hash(Buffer.from([0])) } } });
    const bytes = Buffer.from(JSON.stringify(payload)), encoded = bytes.toString('base64');
    const receipt = { run: runID.toUpperCase(), checkpoint: id.toUpperCase(), owner: who.toUpperCase(), payloadSHA256: hash(bytes), sharedEventDigest: history };
    const fields = { checkpoint: id, receipt, bytes: bytes.length, count: Math.ceil(encoded.length / 12000), expectedHead };
    rpc(who, 'save', fields);
    for (let i = 0; i < fields.count; i++) rpc(who, 'saveChunk', { ...fields, index: i, data: encoded.slice(i * 12000, (i + 1) * 12000) });
    return { bytes, fields, seal: () => rpc(who, 'saveSeal', fields) };
  };
  const legacySession = (who, bits, fields = {}) => JSON.parse(f.runs.rpc({ ...f.ctx, userId: f.presence(who).userId }, f.logger, f.nk,
    JSON.stringify({ ticket: f.ticket(who), runID, action: 'session', identity: identity(who), history, bits: bits.toString('base64'), checkpoint: null, checkpointHistory: null, ...fields })));
  return { f, identity, rpc, commit, event, events, upload, legacySession };
}

test('one immutable shared configuration starts without the partner entering or acknowledging', () => {
  const { f, identity, rpc, commit } = setup();
  const state = commit(); assert.equal(state.committed, true);
  assert.equal(state.identity.settings, settings()); assert.equal(state.identity.settingsOwner, owner);
  assert.equal(rpc(peer, 'setup', { identity: identity(peer) }).committed, true, 'gameID remains personal');
  assert.throws(() => rpc(owner, 'draft', { identity: identity(owner, { settings: 'AA==' }), epoch: 1 }));
  assert.equal(rpc(owner, 'commit', { identity: identity(owner), epoch: 1 }).committed, true);
  const record = f.stored.get('bound_independent_v2:' + runID);
  assert.equal(record.permissionRead, 0); assert.equal(record.permissionWrite, 0);
  assert.throws(() => rpc(third, 'get'));
});
test('draft survives reconnect, cancellation is durable, and incomplete native configuration cannot commit', () => {
  const { identity, rpc } = setup();
  rpc(owner, 'setup', { identity: identity(owner, { settings: 'AA==' }) });
  rpc(owner, 'draft', { identity: identity(owner, { settings: 'AA==' }), epoch: 1 });
  assert.equal(rpc(peer, 'get').identity.settings, 'AA==');
  assert.throws(() => rpc(owner, 'commit', { identity: identity(owner, { settings: 'AA==' }), epoch: 1 }));
  assert.equal(rpc(peer, 'cancelSetup').cancelled, true);
  assert.equal(rpc(owner, 'get').cancelled, true);
  assert.throws(() => rpc(owner, 'commit', { identity: identity(owner), epoch: 1 }));
});
test('cancellation before the first response leaves a tombstone and a lost cancellation acknowledgement retries safely', () => {
  const { identity, rpc } = setup();
  assert.equal(rpc(owner, 'cancelSetup', { identity: identity(owner) }).cancelled, true);
  assert.equal(rpc(peer, 'setup', { identity: identity(peer) }).cancelled, true);
  assert.equal(rpc(owner, 'cancelSetup', { identity: identity(owner) }).cancelled, true);
  assert.throws(() => rpc(owner, 'commit', { identity: identity(owner), epoch: 1 }));
});
test('a cancellation racing an irreversible commit reports the committed outcome without undoing it', () => {
  const { identity, rpc, commit } = setup(); commit();
  const state = rpc(peer, 'cancelSetup', { identity: identity(peer) });
  assert.equal(state.committed, true); assert.equal(state.cancelled, false);
  assert.equal(rpc(owner, 'get').committed, true);
});
test('authorized takeover fences the disappeared chooser and preserves distinct account seeds', () => {
  const { f, identity, rpc } = setup(); rpc(owner, 'setup', { identity: identity(owner) });
  assert.throws(() => rpc(peer, 'takeover', { authorized: true, epoch: 1 })); f.now(1031);
  assert.throws(() => rpc(peer, 'takeover', { authorized: false, epoch: 1 }));
  const taken = rpc(peer, 'takeover', { authorized: true, epoch: 1 });
  assert.equal(taken.epoch, 2); assert.equal(taken.identity.settingsOwner, peer);
  assert.throws(() => rpc(owner, 'commit', { identity: identity(owner), epoch: 1 }));
  assert.throws(() => rpc(peer, 'takeover', { authorized: true, epoch: 1 }));
  const complete = rpc(peer, 'commit', { identity: identity(peer, { settingsOwner: peer }), epoch: 2 });
  assert.equal(complete.committed, true); assert.equal(complete.identity.localSeed, 2); assert.equal(complete.identity.partnerSeed, 1);
});
test('event 2 before event 1 retains its gap and its permanent death is delivered immediately', () => {
  const { f, commit, event, events } = setup(); commit();
  let state = events(owner, [event(owner, 2)], { [owner]: 2 });
  assert.deepEqual(state.cursors[owner], { contiguous: 0, sparse: [2] });
  assert.equal(state.deliveries[owner][owner], 0, 'offline local cursors cannot forge a durable server receipt');
  assert.equal(events(peer).events[0].id.sequence, 2);
  state = events(owner, [event(owner, 1)], { [owner]: 2 });
  assert.deepEqual(state.cursors[owner], { contiguous: 2, sparse: [] });
  assert.equal(events(peer).events.length, 2);
  assert.equal(f.stored.get('bound_events_v2:' + runID + '/' + owner + '/1').permissionWrite, 0);
});
test('immutable retries normalize UUID case and reject changed payloads and foreign origins or runs', () => {
  const { commit, event, events } = setup(); commit();
  const first = event(owner, 1); events(owner, [first]);
  assert.equal(events(owner, [{ ...first, run: runID, id: { origin: owner, sequence: 1 } }]).cursors[owner].contiguous, 1);
  assert.throws(() => events(owner, [{ ...first, payload: 'Y2hhbmdlZA==' }]));
  assert.throws(() => events(owner, [event(peer, 1)]));
  assert.throws(() => events(owner, [{ ...event(owner, 2), run: roomID }]));
  assert.throws(() => events(owner, [event(owner, 5000)]));
});
test('events survive a failed run-document CAS and retry without duplicate storage', () => {
  const { f, commit, event, events } = setup(); commit();
  const write = f.nk.storageWrite; let failed = false;
  f.nk.storageWrite = records => {
    if (!failed && records[0].key === runID) { failed = true; throw Error('injected concurrent change'); }
    return write(records);
  };
  assert.equal(events(owner, [event(owner, 1)]).cursors[owner].contiguous, 1);
  assert.equal(events(peer).events.length, 1);
  assert.equal([...f.stored.values()].filter(value => value.collection === 'bound_events_v2').length, 1);
});
test('offline backlogs upload in batches without starving partner events and older receivers replay acknowledged history', () => {
  const { commit, event, events } = setup(); commit();
  for (let start = 1; start <= 80; start += 16) events(owner, Array.from({ length: 16 }, (_, i) => event(owner, start + i)), { [owner]: 80 });
  events(peer, [event(peer, 1)]);
  const first = events(peer); assert.equal(first.events.filter(value => value.id.origin === owner).length, 16);
  assert.ok(first.events.some(value => value.id.origin === peer));
  const later = events(peer, [], { [owner]: 80, [peer]: 1 }); assert.equal(later.events.length, 0);
  assert.equal(later.deliveries[peer][owner], 80);
  assert.equal(events(peer, [], {}).events[0].id.sequence, 1);
});
test('players upload distinct checkpoints without a partner save or matching head', () => {
  const { rpc, commit, upload } = setup(); commit();
  const first = upload(owner, checkpoint(1)); const head = first.seal();
  assert.equal(head.saves[owner].receipt.checkpoint.toLowerCase(), checkpoint(1)); assert.equal(head.saves[peer], undefined);
  assert.equal(upload(peer, checkpoint(9)).seal().saves[peer].receipt.checkpoint.toLowerCase(), checkpoint(9));
  const second = upload(owner, checkpoint(2), checkpoint(1)); const next = second.seal();
  assert.equal(next.saves[owner].receipt.checkpoint.toLowerCase(), checkpoint(2)); assert.equal(next.saves[peer].receipt.checkpoint.toLowerCase(), checkpoint(9));
  assert.equal(second.seal().saves[owner].receipt.checkpoint.toLowerCase(), checkpoint(2));
  assert.deepEqual(Buffer.from(rpc(owner, 'saveDownload', { checkpoint: checkpoint(2), index: 0 }).data, 'base64'), second.bytes);
  assert.throws(() => rpc(peer, 'saveDownload', { checkpoint: checkpoint(2), index: 0 }));
});
test('stale upload heads and mismatched setup cannot replace a personal save', () => {
  const { commit, upload } = setup(); commit(); upload(owner, checkpoint(1)).seal();
  assert.throws(upload(owner, checkpoint(3)).seal);
  const changed = upload(owner, checkpoint(4), checkpoint(1), value => { value.manifest.identity.settingsOwner = peer; return value; });
  assert.throws(changed.seal);
  assert.equal(upload(owner, checkpoint(2), checkpoint(1)).seal().saves[owner].receipt.checkpoint.toLowerCase(), checkpoint(2));
});
test('v1 migration preserves authoritative tombstones without reserving conflicting client event IDs', () => {
  const { f, identity, rpc, event, events, legacySession } = setup();
  const bits = Buffer.alloc(864); bits[0] = 1; bits[577] = 2;
  legacySession(owner, bits); legacySession(peer, bits); const original = plain(f.stored.get(runID));
  assert.throws(() => rpc(owner, 'migrate', { identity: identity(owner, { settings: 'AA==' }) }));
  assert.throws(() => rpc(owner, 'migrate', { identity: identity(owner, { localSeed: 77 }) }));
  const migrated = rpc(owner, 'migrate', { identity: identity(owner) }); assert.equal(migrated.committed, true);
  assert.equal(migrated.legacyHistory[owner].bits, bits.toString('base64')); assert.equal(migrated.legacyHistory[peer].bits, bits.toString('base64'));
  assert.deepEqual(f.stored.get(runID), original);
  assert.equal(events(owner, [event(owner, 1)]).cursors[owner].contiguous, 1);
  assert.deepEqual(rpc(peer, 'migrate', { identity: identity(peer) }).legacyHistory, migrated.legacyHistory);
});
test('setup migrates an existing v1 run and cannot replace its recorded configuration', () => {
  const { identity, rpc, legacySession } = setup(); legacySession(owner, Buffer.alloc(864));
  assert.throws(() => rpc(owner, 'setup', { identity: identity(owner, { settingsOwner: peer }) }));
  assert.equal(rpc(owner, 'setup', { identity: identity(owner) }).committed, true);
});
test('migration retry imports later authoritative v1 deaths while preserving the original event sequence', () => {
  const { identity, rpc, legacySession } = setup();
  const before = Buffer.alloc(864); legacySession(owner, before);
  rpc(owner, 'migrate', { identity: identity(owner) });
  const after = Buffer.from(before); after[578] = 16;
  legacySession(owner, after, { history: 'c'.repeat(64) });
  const refreshed = rpc(owner, 'migrate', { identity: identity(owner) });
  assert.equal(refreshed.legacyHistory[owner].bits, after.toString('base64'));
  assert.deepEqual(refreshed.cursors, {});
});
