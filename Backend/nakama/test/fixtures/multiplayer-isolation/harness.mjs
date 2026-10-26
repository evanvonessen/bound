// Local in-memory adapter around the compiled production Nakama handlers.
// No network, real account, emulator, filesystem save, or service is involved.
import { createHash, createHmac } from 'node:crypto';
import { fixture, owner, peer, third, roomID, secret, plain } from '../../fixture.mjs';

export { owner, peer, third, roomID, plain };
export const runID = 'bbbbbbbb-bbbb-4bbb-8bbb-000000000101';
export const legacyRunID = 'cccccccc-cccc-4ccc-8ccc-000000000101';
export const checkpoint = n => `dddddddd-dddd-4ddd-8ddd-${String(n).padStart(12, '0')}`;
export const device = who => who === owner ? 'eeeeeeee-eeee-4eee-8eee-000000000001' : 'eeeeeeee-eeee-4eee-8eee-000000000002';
export const romSHA256 = '8bf5b9675e0e34e785b0a40eb2d8120a1d2d6874890c4f6d2f43b5d1d3ab90fb';
export const digest = data => createHash('sha256').update(data).digest('hex');
export const blob = data => ({ data: Buffer.from(data).toString('base64'), sha256: digest(data) });
export const settings = () => {
  const bytes = Buffer.alloc(32); bytes[0] = 5; bytes[12] = 187; bytes.fill(255, 13, 20);
  return bytes.toString('base64');
};

export function harness(records = []) {
  const f = fixture();
  let serial = 100;
  f.nk.uuidv4 = () => `bbbbbbbb-bbbb-4bbb-8bbb-${String(++serial).padStart(12, '0')}`;
  // Provider CAS tokens are opaque and are deliberately assigned afresh when
  // loading persisted logical records into this disposable storage adapter.
  if (records.length) f.nk.storageWrite(records.map(record => ({ ...plain(record), version: '*' })));
  const ticket = (who, creation = false) => {
    const claims = { version: 1, protocol: 'bound-saves-v1', ownerID: who, issuedAt: 1000, expiresAt: 1090,
      ...(creation ? { partnerID: peer, roomID } : {}) };
    const encoded = Buffer.from(JSON.stringify(claims)).toString('base64url');
    return encoded + '.' + createHmac('sha256', secret).update(encoded).digest('hex');
  };
  const rpc = (who, action, fields = {}) => JSON.parse(f.independent.rpc(
    { ...f.ctx, userId: f.presence(who).userId }, f.logger, f.nk,
    JSON.stringify({ saveTicket: ticket(who, action === 'create'), save_id: runID, action, ...fields })));
  const legacy = (who, action, fields = {}) => JSON.parse(f.runs.rpc(
    { ...f.ctx, userId: f.presence(who).userId }, f.logger, f.nk,
    JSON.stringify({ ticket: f.ticket(who), runID: legacyRunID, action, ...fields })));
  const stage = (who, bytes, expectedHead = null) => {
    const payload = JSON.parse(bytes), encoded = Buffer.from(bytes).toString('base64');
    const fields = { checkpoint: payload.checkpoint, expectedHead,
      receipt: { run: runID, checkpoint: payload.checkpoint, owner: who,
        payloadSHA256: digest(bytes), sharedEventDigest: payload.sharedEventDigest },
      bytes: Buffer.byteLength(bytes), count: Math.ceil(encoded.length / 12000) };
    return { fields,
      begin: () => rpc(who, 'save', fields),
      chunk: index => rpc(who, 'saveChunk', { ...fields, index, data: encoded.slice(index * 12000, (index + 1) * 12000) }),
      seal: () => rpc(who, 'saveSeal', fields),
      upload: () => { rpc(who, 'save', fields); for (let i = 0; i < fields.count; i++) rpc(who, 'saveChunk', { ...fields, index: i, data: encoded.slice(i * 12000, (i + 1) * 12000) }); },
    };
  };
  const download = (who, id) => {
    const count = rpc(who, 'get').saves[who].count;
    return Buffer.from(Array.from({ length: count }, (_, index) => rpc(who, 'saveDownload', { checkpoint: id, index }).data).join(''), 'base64');
  };
  return { f, rpc, legacy, stage, download, ticket };
}

export function soul(sequence, kind = 'death', who = owner) {
  return { run: runID, id: { origin: who, sequence }, kind: 'soul',
    payload: Buffer.from(JSON.stringify({ version: 1, run: runID, kind, slot: 'area:1' })).toString('base64'),
    idempotencyKey: `${kind}:area:1` };
}

export function payload(identity, id, predecessor, journal, recovery = 'battle') {
  const state = Buffer.from('SYNTHETIC PROTOCOL BYTES; NOT AN EMULATOR STATE: ' + identity.owner);
  const nativeRecovery = Buffer.from(JSON.stringify({ fixtureOnly: true, kind: recovery,
    gameID: identity.gameID, run: identity.run, state: 'fixture.state', sha256: digest(state) }));
  return { version: 2,
    manifest: { identity, deviceOwner: device(identity.owner), releasedForTransfer: false },
    checkpoint: id, predecessor, sharedEventDigest: digest(Buffer.from('synthetic shared boundary 1')),
    files: {
      'game.sav': blob(Buffer.from('SYNTHETIC PROTOCOL BYTES; NOT A BATTERY SAVE: ' + identity.owner)),
      'checkpoint.state': blob(state),
      'shared-events.json': blob(Buffer.from(JSON.stringify(journal))),
      'recovery/fixture.json': blob(nativeRecovery),
      'recovery/fixture.state': blob(state),
    },
  };
}

export function snapshot(f) {
  return [...f.stored.values()].map(({ version, ...record }) => plain(record))
    .sort((a, b) => (a.collection + '/' + a.key).localeCompare(b.collection + '/' + b.key));
}
