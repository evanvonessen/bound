// Explicit, local-only fixture regeneration. Review fixture diffs; never call
// this from tests to regenerate the expected format under the code being tested.
import fs from 'node:fs';
import { harness, owner, peer, roomID, runID, legacyRunID, checkpoint, romSHA256,
  settings, soul, payload, snapshot, digest, blob } from './harness.mjs';

if (process.argv[2] !== '--write-reviewed-baseline') throw Error('Pass --write-reviewed-baseline to replace only these synthetic fixtures');
const out = new URL('./', import.meta.url);
const written = [];
function write(name, value) {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value, null, 2) + '\n');
  fs.writeFileSync(new URL(name, out), bytes); written.push({ file: name, bytes: bytes.length, sha256: digest(bytes) });
}

const h = harness();
h.rpc(owner, 'create', { request_id: 'bbbbbbbb-bbbb-4bbb-8bbb-000000000001', partnerID: peer,
  gameID: 'multi_red', romSHA256, settings: settings(), profile: { name: 'RED', gender: 0 }, partnerProfile: { name: 'LEAF', gender: 1 } });
const acquired = soul(1, 'acquired'), death = soul(3);
const journal = { version: 1, run: runID, owner, partner: peer, nextSequence: 2, events: [acquired],
  received: { origins: { [owner]: { contiguous: 1, sparse: [] } } },
  acknowledged: { origins: {} }, applied: { origins: { [owner]: { contiguous: 1, sparse: [] } } } };
const ownerBytes = Buffer.from(JSON.stringify(payload(h.rpc(owner, 'get').identity, checkpoint(10), null, journal)) + '\n');
const first = h.stage(owner, ownerBytes); first.upload(); first.seal();
h.rpc(owner, 'events', { events: [death], after: {} });
const peerJournal = { ...journal, owner: peer, partner: owner, nextSequence: 1, events: [acquired, death],
  received: { origins: { [owner]: { contiguous: 1, sparse: [3] } } },
  acknowledged: { origins: {} }, applied: { origins: { [owner]: { contiguous: 1, sparse: [] } } } };
const peerBytes = Buffer.from(JSON.stringify(payload(h.rpc(peer, 'get').identity, checkpoint(20), null, peerJournal, 'trade')) + '\n');
const second = h.stage(peer, peerBytes); second.upload(); second.seal();
h.rpc(peer, 'events', { events: [], after: { [owner]: 1 } });
const records = snapshot(h.f);
for (const record of records) if (record.value.created_at) {
  // Wall-clock metadata is normalized, never misrepresented as gameplay history.
  record.value.created_at = record.value.updated_at = '2000-01-01T00:00:00.000Z';
}
write('owner-payload-v2.json', ownerBytes); write('peer-payload-v2.json', peerBytes);
write('storage-v2.json', records);

const old = harness();
const bits = Buffer.alloc(864); bits[578] = 16;
const history = digest(bits);
const identity = who => ({ ...h.rpc(who, 'get').identity, run: legacyRunID });
for (const who of [owner, peer]) old.legacy(who, 'session', { identity: identity(who), history,
  bits: bits.toString('base64'), checkpoint: null, checkpointHistory: null });
const pending = old.legacy(owner, 'begin', { history, predecessor: null }).pending;
const v1Payload = { version: 1, manifest: { identity: identity(owner), deviceOwner: 'eeeeeeee-eeee-4eee-8eee-000000000001' },
  checkpoint: pending.id, predecessor: null, sharedEventDigest: history,
  files: { 'game.sav': blob(Buffer.from('SYNTHETIC LEGACY BATTERY PLACEHOLDER')),
    'checkpoint.state': blob(Buffer.from('SYNTHETIC LEGACY STATE PLACEHOLDER')) } };
const legacyBytes = Buffer.from(JSON.stringify(v1Payload) + '\n');
const encoded = legacyBytes.toString('base64');
const fields = { checkpoint: pending.id, receipt: { run: legacyRunID, checkpoint: pending.id, owner,
  payloadSHA256: digest(legacyBytes), sharedEventDigest: history }, bytes: legacyBytes.length, count: Math.ceil(encoded.length / 12000) };
old.legacy(owner, 'prepare', { checkpoint: pending.id, history }); old.legacy(owner, 'upload', fields);
old.legacy(owner, 'chunk', { ...fields, index: 0, data: encoded }); old.legacy(owner, 'seal', fields);
write('owner-payload-v1.json', legacyBytes); write('storage-v1-partial.json', snapshot(old.f));
write('provenance.json', { fixtureVersion: 1,
  sourceCommit: '00bb9324a28d473867d4d5be2c891bf7cefa298a',
  source: 'Compiled Backend/nakama runtime through existing in-memory fixture adapter',
  synthetic: true, nativeGameplayFixture: false, playerData: false,
  description: 'Static protocol/storage regression records, not playable saves or proof of progression. All blob content is invented marker text; native recovery is opaque at this server boundary.',
  normalizations: ['Provider CAS version tokens excluded', 'Managed run timestamps fixed to 2000-01-01T00:00:00.000Z'],
  compatibility: { romSHA256, abiMajor: 1, abiMinor: 0, wireVersion: 2, checkpointFormat: 1, batteryFormat: 1,
    stateLayout: 5, settingsVersion: 5, coreID: 'com.rileytestut.GBADeltaCore', nativeStateVersion: 10 },
  files: written,
});
console.log('Wrote reviewed synthetic protocol fixtures; no native state or player data was used.');
