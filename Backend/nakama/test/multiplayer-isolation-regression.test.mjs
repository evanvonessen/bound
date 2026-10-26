import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { harness, owner, peer, third, runID, legacyRunID, checkpoint, soul, digest,
  snapshot, plain, blob } from './fixtures/multiplayer-isolation/harness.mjs';

const directory = new URL('./fixtures/multiplayer-isolation/', import.meta.url);
const bytes = name => fs.readFileSync(new URL(name, directory));
const json = name => JSON.parse(bytes(name));
const restored = () => harness(json('storage-v2.json'));
const rootKey = 'bound_independent_v2:' + runID;
const eventKey = sequence => 'bound_events_v2:' + runID + '/' + owner + '/' + sequence;
const encode = value => Buffer.from(JSON.stringify(value) + '\n');

test('frozen fixture bytes and embedded blob checksums remain the reviewed synthetic baseline', () => {
  const provenance = json('provenance.json');
  assert.equal(provenance.synthetic, true);
  assert.equal(provenance.nativeGameplayFixture, false);
  assert.equal(provenance.playerData, false);
  for (const file of provenance.files) {
    assert.equal(bytes(file.file).length, file.bytes, file.file);
    assert.equal(digest(bytes(file.file)), file.sha256, file.file);
  }
  for (const name of ['owner-payload-v1.json', 'owner-payload-v2.json', 'peer-payload-v2.json']) {
    for (const [file, value] of Object.entries(json(name).files)) {
      assert.equal(digest(Buffer.from(value.data, 'base64')), value.sha256, name + ':' + file);
    }
  }
});

test('persisted v2 records reopen with distinct owner heads and byte-identical packages and recovery blobs', () => {
  const h = restored();
  const before = snapshot(h.f);
  for (const [who, id, file] of [[owner, checkpoint(10), 'owner-payload-v2.json'], [peer, checkpoint(20), 'peer-payload-v2.json']]) {
    const state = h.rpc(who, 'get');
    assert.equal(state.identity.owner, who);
    assert.equal(state.identity.partner, who === owner ? peer : owner);
    assert.equal(state.saves[who].receipt.checkpoint, id);
    assert.deepEqual(h.download(who, id), bytes(file));
    assert.equal(h.rpc(who, 'list', { gameID: 'multi_red' }).runs[0].save_id, runID);
    assert.throws(() => h.rpc(who === owner ? peer : owner, 'saveDownload', { checkpoint: id, index: 0 }));
  }
  assert.throws(() => h.rpc(third, 'get'));
  assert.deepEqual(snapshot(h.f), before, 'read/open/list must not rewrite stored packages or origins');
  const a = h.rpc(owner, 'get').identity, b = h.rpc(peer, 'get').identity;
  assert.notEqual(a.localSeed, b.localSeed);
  assert.equal(a.localSeed, b.partnerSeed);
  assert.notEqual(json('owner-payload-v2.json').manifest.deviceOwner, json('peer-payload-v2.json').manifest.deviceOwner);
});

test('a durable sparse receipt never certifies a missing event or mutates client application acknowledgements', () => {
  let h = restored();
  assert.deepEqual(h.rpc(peer, 'get').cursors[owner], { contiguous: 1, sparse: [3] });
  const ack = h.rpc(peer, 'events', { events: [], after: { [owner]: 3 } });
  assert.equal(ack.deliveries[peer][owner], 1, 'server receipt is capped at its actual contiguous history');
  const peerBytes = h.download(peer, checkpoint(20));
  const journal = JSON.parse(Buffer.from(JSON.parse(peerBytes).files['shared-events.json'].data, 'base64'));
  assert.deepEqual(journal.received.origins[owner], { contiguous: 1, sparse: [3] });
  assert.deepEqual(journal.applied.origins[owner], { contiguous: 1, sparse: [] });
  assert.deepEqual(peerBytes, bytes('peer-payload-v2.json'), 'delivery acknowledgements cannot certify a new native checkpoint');
  h = harness(snapshot(h.f));
  assert.deepEqual(h.rpc(peer, 'events', { events: [], after: { [owner]: 1 } }).events.map(event => event.id.sequence), [3]);
  const gap = { ...soul(2), idempotencyKey: 'death:area:2',
    payload: Buffer.from(JSON.stringify({ version: 1, run: runID, kind: 'death', slot: 'area:2' })).toString('base64') };
  const filled = h.rpc(owner, 'events', { events: [gap], after: {} });
  assert.deepEqual(filled.cursors[owner], { contiguous: 3, sparse: [] });
  const replay = h.rpc(peer, 'events', { events: [], after: { [owner]: 1 } }).events;
  assert.deepEqual(replay.map(event => event.id.sequence), [2, 3]);
  assert.deepEqual(replay[1], soul(3));
});

test('loading an older player checkpoint does not roll back permanent loss records or reset event origins', () => {
  const h = restored();
  const death = plain(h.f.stored.get(eventKey(3)));
  const old = json('owner-payload-v2.json');
  old.checkpoint = checkpoint(11); old.predecessor = checkpoint(10);
  const staged = h.stage(owner, encode(old), checkpoint(10)); staged.upload(); staged.seal();
  assert.equal(h.rpc(owner, 'get').saves[owner].receipt.checkpoint, checkpoint(11));
  assert.equal(h.rpc(peer, 'get').saves[peer].receipt.checkpoint, checkpoint(20));
  assert.deepEqual(h.f.stored.get(eventKey(3)), death);
  assert.deepEqual(h.rpc(peer, 'events', { events: [], after: { [owner]: 1 } }).events, [soul(3)]);
  assert.throws(() => h.rpc(owner, 'events', { events: [{ ...soul(3), payload: soul(1, 'acquired').payload }], after: {} }));
  assert.deepEqual(h.f.stored.get(eventKey(3)), death);
});

test('a restart during a multi-chunk upload retains the old head and resumes the exact pending bytes', () => {
  let h = restored();
  const payload = json('owner-payload-v2.json'); payload.checkpoint = checkpoint(11); payload.predecessor = checkpoint(10);
  payload.files['memory-files.json'] = blob(encode({ syntheticPadding: 'fixture-only-'.repeat(1800) }));
  const pendingBytes = encode(payload);
  let pending = h.stage(owner, pendingBytes, checkpoint(10));
  assert.ok(pending.fields.count > 2);
  pending.begin(); pending.chunk(0);
  h = harness(snapshot(h.f)); pending = h.stage(owner, pendingBytes, checkpoint(10));
  assert.throws(pending.seal);
  assert.deepEqual(h.download(owner, checkpoint(10)), bytes('owner-payload-v2.json'));
  for (let index = 1; index < pending.fields.count; index++) pending.chunk(index);
  pending.seal();
  h = harness(snapshot(h.f));
  assert.deepEqual(h.download(owner, checkpoint(11)), pendingBytes);
  assert.equal(h.stage(owner, pendingBytes, checkpoint(10)).seal().saves[owner].receipt.checkpoint, checkpoint(11));
  assert.deepEqual(h.download(peer, checkpoint(20)), bytes('peer-payload-v2.json'));
});

test('competing device snapshots use owner-head CAS; the losing upload cannot replace either participant', () => {
  const h = restored();
  const first = json('owner-payload-v2.json'); first.checkpoint = checkpoint(11); first.predecessor = checkpoint(10);
  const second = plain(first); second.checkpoint = checkpoint(12);
  second.manifest.deviceOwner = 'eeeeeeee-eeee-4eee-8eee-000000000099';
  const losing = h.stage(owner, encode(first), checkpoint(10)); losing.upload();
  const winningBytes = encode(second), winning = h.stage(owner, winningBytes, checkpoint(10)); winning.upload(); winning.seal();
  assert.throws(losing.seal);
  assert.deepEqual(h.download(owner, checkpoint(12)), winningBytes);
  assert.deepEqual(h.download(peer, checkpoint(20)), bytes('peer-payload-v2.json'));
  assert.ok(h.f.stored.has('bound_independent_v2:' + runID + '/save/' + owner + '/' + checkpoint(11)), 'retain immutable losing upload for explicit recovery');
  // deviceOwner is opaque server metadata here. Host lease/transfer checks are
  // covered separately; this test does not claim a device token is authorized.
});

test('valid outer checksums cannot bypass wrong-ROM, foreign-owner, or changed-settings package rejection', () => {
  for (const mutate of [
    value => { value.manifest.identity.romSHA256 = '0'.repeat(64); },
    value => { value.manifest.identity.owner = peer; },
    value => { value.manifest.identity.settings = 'AA=='; },
  ]) {
    const h = restored(); const original = plain(h.f.stored.get(rootKey).value.saves);
    const payload = json('owner-payload-v2.json'); payload.checkpoint = checkpoint(11); payload.predecessor = checkpoint(10); mutate(payload);
    const staged = h.stage(owner, encode(payload), checkpoint(10)); staged.upload();
    assert.throws(staged.seal);
    assert.deepEqual(h.f.stored.get(rootKey).value.saves, original);
    assert.deepEqual(h.download(owner, checkpoint(10)), bytes('owner-payload-v2.json'));
  }
});

test('checkpoint acquisition and the personal head stay atomic across failed CAS and fresh-runtime retry', () => {
  let h = restored();
  const payload = json('owner-payload-v2.json'); payload.checkpoint = checkpoint(11); payload.predecessor = checkpoint(10);
  const journal = JSON.parse(Buffer.from(payload.files['shared-events.json'].data, 'base64'));
  journal.nextSequence = 3; journal.events.push(soul(2, 'acquired'));
  journal.received.origins[owner].contiguous = journal.applied.origins[owner].contiguous = 2;
  payload.files['shared-events.json'] = blob(encode(journal));
  const pendingBytes = encode(payload), staged = h.stage(owner, pendingBytes, checkpoint(10)); staged.upload();
  const write = h.f.nk.storageWrite;
  h.f.nk.storageWrite = rows => {
    if (rows.some(row => row.collection === 'bound_events_v2')) throw Error('synthetic atomic-storage outage');
    return write(rows);
  };
  assert.throws(staged.seal);
  assert.equal(h.f.stored.has(eventKey(2)), false);
  assert.equal(h.rpc(owner, 'get').saves[owner].receipt.checkpoint, checkpoint(10));
  h = harness(snapshot(h.f));
  h.stage(owner, pendingBytes, checkpoint(10)).seal();
  assert.equal(h.rpc(owner, 'get').saves[owner].receipt.checkpoint, checkpoint(11));
  assert.deepEqual(h.rpc(owner, 'get').cursors[owner], { contiguous: 3, sparse: [] });
  assert.deepEqual(h.f.stored.get(eventKey(2)).value, soul(2, 'acquired'));
});

test('legacy partial paired checkpoint reloads without conversion and completes only after the other owner seals', () => {
  const h = harness(json('storage-v1-partial.json'));
  const record = h.f.stored.get(legacyRunID).value;
  assert.equal(record.version, 1); assert.equal(record.head, null);
  assert.deepEqual(Object.keys(record.pending.uploads), [owner]);
  const payload = json('owner-payload-v1.json');
  payload.manifest.identity = plain(record.participants[peer].identity);
  payload.manifest.deviceOwner = 'eeeeeeee-eeee-4eee-8eee-000000000002';
  const peerBytes = encode(payload), encoded = peerBytes.toString('base64');
  const fields = { checkpoint: record.pending.id, bytes: peerBytes.length, count: Math.ceil(encoded.length / 12000),
    receipt: { run: legacyRunID, checkpoint: record.pending.id, owner: peer, payloadSHA256: digest(peerBytes), sharedEventDigest: record.pending.history } };
  h.legacy(peer, 'prepare', { checkpoint: record.pending.id, history: record.pending.history });
  h.legacy(peer, 'upload', fields);
  assert.throws(() => h.legacy(peer, 'seal', fields));
  h.legacy(peer, 'chunk', { ...fields, index: 0, data: encoded });
  const complete = h.legacy(peer, 'seal', fields);
  assert.equal(complete.pending, null); assert.equal(complete.head.id, record.pending.id);
  assert.deepEqual(Buffer.from(h.legacy(owner, 'download', { checkpoint: complete.head.id, index: 0 }).data, 'base64'), bytes('owner-payload-v1.json'));
  assert.deepEqual(h.f.stored.get(legacyRunID).value.participants, record.participants, 'legacy permanent-loss bits and seeds stay unchanged');
  assert.equal(h.f.stored.get(legacyRunID).value.version, 1);
});
