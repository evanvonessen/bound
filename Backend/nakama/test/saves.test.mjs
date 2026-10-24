import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, createHash } from 'node:crypto';
import { fixture, owner, peer, third, roomID, secret, plain } from './fixture.mjs';
const uuid = n => `bbbbbbbb-bbbb-4bbb-8bbb-${String(n).padStart(12, '0')}`;
const hash = input => createHash('sha256').update(input).digest('hex');
const settings = () => { const bytes = Buffer.alloc(32); bytes[0] = 4; bytes[12] = 187; bytes.fill(255, 13, 20); return bytes.toString('base64'); };
const gameOverSettings = (debug = false, keep = false) => {
  const bytes = Buffer.from(settings(), 'base64'); bytes[0] = 5; bytes[20] = Number(debug); bytes[21] = Number(keep);
  return bytes.toString('base64');
};
function setup() {
  const f = fixture(); let serial = 100, now = 1000;
  f.nk.uuidv4 = () => uuid(++serial);
  const ticket = (who, creation = false, override = {}) => {
    const claims = { version: 1, protocol: 'bound-saves-v1', ownerID: who, issuedAt: now, expiresAt: now + 90,
      ...(creation ? { partnerID: peer, roomID } : {}), ...override };
    const text = Buffer.from(JSON.stringify(claims)).toString('base64url');
    return text + '.' + createHmac('sha256', secret).update(text).digest('hex');
  };
  const rpc = (who, action, fields = {}) => JSON.parse(f.independent.rpc({ ...f.ctx, userId: f.presence(who).userId }, f.logger, f.nk,
    JSON.stringify({ saveTicket: ticket(who, action === 'create'), action, ...fields })));
  const create = (fields = {}) => rpc(owner, 'create', { request_id: uuid(1), partnerID: peer, gameID: 'multi_red', romSHA256: 'a'.repeat(64), settings: settings(), profile: { name: 'RED', gender: 0 }, ...fields });
  const list = who => rpc(who, 'list', { gameID: 'multi_red' });
  const get = (who, run) => rpc(who, 'get', { save_id: run.save_id });
  const upload = (who, run, checkpoint, predecessor = null) => {
    const current = get(who, run);
    const payload = { version: 2, manifest: { identity: current.identity, deviceOwner: who }, checkpoint, predecessor,
      sharedEventDigest: 'c'.repeat(64), files: { 'game.sav': { data: 'AA==', sha256: hash(Buffer.from([0])) }, 'checkpoint.state': { data: 'AA==', sha256: hash(Buffer.from([0])) } } };
    const bytes = Buffer.from(JSON.stringify(payload)), encoded = bytes.toString('base64');
    const fields = { save_id: run.save_id, checkpoint, expectedHead: predecessor, receipt: { run: run.save_id, checkpoint, owner: who,
      payloadSHA256: hash(bytes), sharedEventDigest: payload.sharedEventDigest }, bytes: bytes.length, count: Math.ceil(encoded.length / 12000) };
    rpc(who, 'save', fields);
    for (let index = 0; index < fields.count; index++) rpc(who, 'saveChunk', { ...fields, index, data: encoded.slice(index * 12000, (index + 1) * 12000) });
    return { fields, bytes, seal: () => rpc(who, 'saveSeal', fields) };
  };
  const remove = (who, run, fields = {}) => rpc(who, 'delete', { save_id: run.save_id, expectedRevision: get(who, run).revision, confirmSharedDeletion: true, ...fields });
  return { f, ticket, rpc, create, list, get, upload, remove, time: value => { now = value; f.now(value); } };
}

test('save tickets authenticate accounts without a room and never authorize live room entry', () => {
  const { f, ticket } = setup();
  const request = { account: { id: 'bound:' + owner, vars: { bound_ticket: ticket(owner), forged: true } } };
  assert.deepEqual(plain(f.api.authenticate(f.ctx, f.logger, f.nk, request).account.vars), { bound_owner_id: owner });
  assert.throws(() => f.api.verifyTicket(f.ctx, f.nk, ticket(owner)));
  assert.throws(() => f.api.authorizeSave({ ...f.ctx, userId: f.presence(peer).userId }, f.nk, ticket(owner)));
  assert.throws(() => f.api.verifySaveTicket(f.ctx, f.nk, ticket(owner, false, { expiresAt: 1091 })));
  assert.throws(() => f.api.verifySaveTicket(f.ctx, f.nk, ticket(owner, false, { partnerID: peer })));
  assert.throws(() => f.api.verifySaveTicket(f.ctx, f.nk, ticket(owner, true, { partnerID: owner })));
});
test('one server UUID is listed immediately for an offline friend with caller-oriented independent identities', () => {
  const { create, list, get, rpc, ticket } = setup();
  const run = create();
  assert.notEqual(run.save_id, uuid(1)); assert.equal(run.identity.run, run.save_id);
  assert.equal(run.committed, true); assert.equal(run.identity.owner, owner);
  assert.equal(list(owner).runs[0].save_id, run.save_id); assert.equal(list(peer).runs[0].save_id, run.save_id);
  const partner = get(peer, run); assert.equal(partner.identity.owner, peer); assert.equal(partner.identity.partner, owner);
  assert.equal(partner.identity.localSeed, run.identity.partnerSeed); assert.notEqual(partner.identity.localSeed, run.identity.localSeed);
  assert.deepEqual(partner.profiles[owner], { name: 'RED', gender: 0 });
  assert.equal(list(third).runs.length, 0); assert.throws(() => get(third, run));
  assert.throws(() => create({ request_id: uuid(2), saveTicket: ticket(owner) }));
  assert.throws(() => create({ request_id: uuid(2), partnerID: third }));
  assert.throws(() => rpc(owner, 'get', { save_id: run.save_id, runID: uuid(99) }));
});
test('lost creation responses and concurrent idempotency writes allocate exactly one permanent run', () => {
  const { f, create, list } = setup();
  const first = create(); assert.equal(create().save_id, first.save_id); assert.equal(list(owner).runs.length, 1);
  assert.throws(() => create({ gameID: 'changed' }));
  const write = f.nk.storageWrite; let injected = false;
  f.nk.storageWrite = records => {
    if (!injected && records.length === 2 && records[1].collection === 'bound_save_requests_v1') {
      injected = true;
      const winner = plain(records); winner[0].key = uuid(999); winner[0].value.save_id = uuid(999); winner[0].value.identity.run = uuid(999);
      winner[1].value.save_id = uuid(999); write(winner);
    }
    return write(records);
  };
  assert.equal(create({ request_id: uuid(2) }).save_id, uuid(999));
  assert.equal(list(owner).runs.length, 2, 'atomic batch leaves no losing candidate root');
});
test('creation stores both trainer profiles for the offline partner and retries preserve them', () => {
  const { create, get, rpc } = setup();
  const partnerProfile = { name: 'LEAF', gender: 1 };
  const run = create({ partnerProfile });
  assert.deepEqual(run.profiles[owner], { name: 'RED', gender: 0 });
  assert.deepEqual(run.profiles[peer], partnerProfile);
  assert.deepEqual(get(peer, run).profiles[peer], partnerProfile);
  assert.equal(create({ partnerProfile }).save_id, run.save_id);
  assert.throws(() => create({ partnerProfile: { name: 'OTHER', gender: 1 } }));
  assert.throws(() => create({ partnerProfile: { name: 'LEAF', gender: 0 } }));
  assert.throws(() => create());
  rpc(owner, 'profile', { save_id: run.save_id, profile: { name: 'ASH', gender: 0 } });
  assert.deepEqual(get(peer, run).profiles[peer], partnerProfile);
});
test('legacy creation retry fingerprints remain unchanged when no partner profile was supplied', () => {
  const { f, create } = setup();
  const run = create();
  const record = f.stored.get('bound_save_requests_v1:' + owner + '/' + uuid(1));
  assert.equal(record.value.configuration, hash(JSON.stringify([peer, 'multi_red', 'a'.repeat(64), settings(), ['RED', 0]])));
  assert.equal(create().save_id, run.save_id);
  assert.equal(run.profiles[peer], undefined);
});
test('invalid partner trainer profiles cannot create a save', () => {
  for (const partnerProfile of [null, {}, [], { name: '', gender: 0 }, { name: 'TOOLONG8', gender: 0 },
    { name: 'LEAF', gender: 2 }, { name: 'LEAF', gender: 1, ownerID: third }, { name: 'A B', gender: 0 }]) {
    const { create, list } = setup();
    assert.throws(() => create({ partnerProfile }));
    assert.equal(list(owner).runs.length, 0);
  }
});
test('each player seals independent snapshots with same-player CAS and incomplete uploads retain the prior valid head', () => {
  const { create, rpc, get, upload } = setup(); const run = create();
  rpc(peer, 'profile', { save_id: run.save_id, profile: { name: 'LEAF', gender: 1 } });
  upload(owner, run, uuid(10)).seal(); upload(peer, run, uuid(11)).seal();
  const stale = upload(owner, run, uuid(12), uuid(10)); const newer = upload(owner, run, uuid(13), uuid(10)); newer.seal();
  assert.throws(stale.seal); assert.equal(get(owner, run).saves[owner].receipt.checkpoint, uuid(13));
  assert.equal(get(peer, run).saves[peer].receipt.checkpoint, uuid(11));
  assert.equal(newer.seal().saves[owner].receipt.checkpoint, uuid(13), 'lost seal response retry');
  assert.deepEqual(Buffer.from(rpc(owner, 'saveDownload', { save_id: run.save_id, checkpoint: uuid(13), index: 0 }).data, 'base64'), newer.bytes);
  assert.throws(() => rpc(peer, 'saveDownload', { save_id: run.save_id, checkpoint: uuid(13), index: 0 }));
  assert.throws(() => rpc(owner, 'profile', { save_id: run.save_id, profile: { name: 'OTHER', gender: 0 } }));
  assert.equal(rpc(owner, 'profile', { save_id: run.save_id, profile: { name: 'RED', gender: 0 } }).profiles[owner].name, 'RED');
});
test('persistence does not expire with admission, rooms or account friendship and refresh uses latest state', () => {
  const { f, create, upload, time, ticket, list, get } = setup(); const run = create(); upload(owner, run, uuid(10)).seal();
  const expired = ticket(owner); f.active.clear(); time(1000 + 365 * 24 * 60 * 60);
  assert.throws(() => f.api.authorizeSave(f.ctx, f.nk, expired));
  assert.equal(list(peer).runs[0].save_id, run.save_id); assert.equal(get(owner, run).saves[owner].receipt.checkpoint, uuid(10));
  assert.equal([...f.stored.values()].filter(row => row.key.startsWith(run.save_id + '/save/')).length, 2);
});
test('shared deletion requires confirmation and a fresh revision, removes both players and blocks replay resurrection', () => {
  const { f, create, upload, get, remove, rpc, list } = setup(); const run = create();
  upload(owner, run, uuid(10)).seal(); upload(peer, run, uuid(11)).seal();
  assert.throws(() => remove(third, run)); assert.throws(() => remove(owner, run, { confirmSharedDeletion: false }));
  assert.throws(() => remove(owner, run, { expectedRevision: run.revision }));
  assert.equal(remove(peer, run).deleted, true); assert.equal(list(owner).runs.length, 0); assert.equal(list(peer).runs.length, 0);
  assert.throws(() => get(owner, run)); assert.throws(() => create());
  assert.equal([...f.stored.values()].filter(row => row.key.startsWith(run.save_id + '/')).length, 0);
  assert.deepEqual(Object.keys(f.stored.get('bound_independent_v2:' + run.save_id).value).sort(), ['deleted', 'members', 'revision', 'save_id', 'version']);
  assert.equal(rpc(owner, 'delete', { save_id: run.save_id, confirmSharedDeletion: true }).deleted, true);
});
test('deletion racing an in-flight chunk prevents new bytes, and interrupted cleanup retries safely', () => {
  const { f, create, get, rpc, remove, upload } = setup(); const run = create(); const saved = upload(owner, run, uuid(10)); saved.seal();
  const write = f.nk.storageWrite; let raced = false;
  f.nk.storageWrite = rows => {
    if (!raced && rows.length === 2 && rows[1].key.includes('/save/')) { raced = true; remove(peer, run); }
    return write(rows);
  };
  assert.throws(() => upload(owner, run, uuid(11), uuid(10))); assert.throws(() => get(peer, run));
  assert.equal([...f.stored.values()].filter(row => row.key.startsWith(run.save_id + '/')).length, 0);
  f.nk.storageWrite = write;
  const other = create({ request_id: uuid(2) }); upload(owner, other, uuid(20)).seal();
  const exec = f.nk.sqlExec; f.nk.sqlExec = () => { throw Error('interrupted database cleanup'); };
  assert.throws(() => remove(owner, other)); assert.throws(() => get(owner, other));
  f.nk.sqlExec = exec; assert.equal(rpc(owner, 'delete', { save_id: other.save_id, confirmSharedDeletion: true }).deleted, true);
  assert.equal([...f.stored.values()].filter(row => row.key.startsWith(other.save_id + '/')).length, 0);
});
test('managed runs reuse gap-aware event acknowledgements, immutable retries and ordered recovery', () => {
  const { create, rpc, get, remove, f } = setup(); const run = create();
  const event = sequence => ({ run: run.save_id, id: { origin: owner, sequence }, kind: 'soul', payload: Buffer.from(JSON.stringify({ version: 1, run: run.save_id, kind: 'death', slot: 'area:' + sequence })).toString('base64') });
  const events = (who, values = [], after = {}) => rpc(who, 'events', { save_id: run.save_id, events: values, after });
  assert.deepEqual(events(owner, [event(2)]).cursors[owner], { contiguous: 0, sparse: [2] });
  assert.equal(events(peer).events[0].id.sequence, 2);
  assert.equal(events(owner, [event(1)]).cursors[owner].contiguous, 2);
  assert.equal(events(owner, [event(1)]).cursors[owner].contiguous, 2);
  assert.throws(() => events(owner, [{ ...event(1), payload: 'YQ==' }]));
  assert.deepEqual(events(peer).events.map(value => value.id.sequence), [1, 2]);
  assert.equal(events(peer, [], { [owner]: 1 }).events[0].id.sequence, 2);
  remove(owner, get(owner, run)); assert.equal([...f.stored.values()].filter(row => row.collection === 'bound_events_v2').length, 0);
});

test('library pages are bounded and include only matching authorized game roots', () => {
  const { create, rpc, list } = setup();
  for (let i = 1; i <= 103; i++) create({ request_id: uuid(i), gameID: i === 103 ? 'another_game' : 'multi_red' });
  const first = list(peer); assert.equal(first.runs.length, 100); assert.ok(first.cursor);
  const second = rpc(peer, 'list', { gameID: 'multi_red', cursor: first.cursor });
  assert.equal(second.runs.length, 2); assert.equal(second.cursor, null);
  assert.equal(new Set([...first.runs, ...second.runs].map(run => run.save_id)).size, 102);
  assert.throws(() => rpc(owner, 'list', { gameID: 'multi_red', cursor: "' OR TRUE" }));
});
test('nonempty libraries read decoded storage records in SQL key order', () => {
  const { f, create, list } = setup();
  const runs = [create(), create({ request_id: uuid(2) })];
  const read = f.nk.storageRead;
  f.nk.storageRead = requests => read(requests).reverse();
  const page = list(peer);
  assert.deepEqual(page.runs.map(run => run.save_id), runs.map(run => run.save_id).sort());
  assert.ok(page.runs.every(run => run.identity.owner === peer));
});
test('library pagination survives deletion between the key query and storage read', () => {
  const { f, create, rpc, list } = setup();
  for (let i = 1; i <= 102; i++) create({ request_id: uuid(i) });
  const query = f.nk.sqlQuery;
  let lastKey;
  f.nk.sqlQuery = (sql, args) => {
    const rows = query(sql, args);
    lastKey = rows[99].key;
    const firstKey = rows[0].key;
    f.stored.delete('bound_independent_v2:' + lastKey);
    const record = f.stored.get('bound_independent_v2:' + firstKey);
    record.value = { ...record.value, deleted: true };
    return rows;
  };
  const first = list(owner);
  assert.equal(first.runs.length, 98);
  assert.equal(first.cursor, lastKey);
  f.nk.sqlQuery = query;
  const second = rpc(owner, 'list', { gameID: 'multi_red', cursor: first.cursor });
  assert.equal(second.runs.length, 2);
  assert.equal(second.cursor, null);
});
test('save limits and supported event validation reject malformed inputs before persisting', () => {
  const { f, create, rpc } = setup(); const run = create();
  const fields = { save_id: run.save_id, checkpoint: uuid(10), bytes: 16 * 1024 * 1024 + 1, count: 1,
    receipt: { owner, run: run.save_id, checkpoint: uuid(10), payloadSHA256: 'a'.repeat(64), sharedEventDigest: 'b'.repeat(64) } };
  assert.throws(() => rpc(owner, 'save', fields));
  assert.throws(() => rpc(owner, 'save', { ...fields, bytes: 1, count: 2 }));
  assert.throws(() => rpc(peer, 'profile', { save_id: run.save_id, profile: { name: 'TOOLONG8', gender: 1 } }));
  assert.throws(() => rpc(peer, 'profile', { save_id: run.save_id, profile: { name: 'LEAF', gender: 2 } }));
  const event = { run: run.save_id, id: { origin: owner, sequence: 1 }, kind: 'soul', payload: 'e30=' };
  for (const value of [event, { ...event, kind: 'arbitrary' }, { ...event, payload: 'no base64!' }]) {
    assert.throws(() => rpc(owner, 'events', { save_id: run.save_id, events: [value], after: {} }));
  }
  const world = { group: 1, number: 2, checkpoints: Buffer.alloc(800).toString('base64'), boulders: '' };
  const events = Array.from({ length: 16 }, (_, i) => ({ ...event, kind: 'world', id: { origin: owner, sequence: i + 1 }, payload: Buffer.from(JSON.stringify(world)).toString('base64') }));
  assert.ok(JSON.stringify(events).length > 20000, 'valid batch must fit the RPC size limit');
  assert.equal(rpc(owner, 'events', { save_id: run.save_id, events, after: {} }).cursors[owner].contiguous, 16);
  assert.throws(() => rpc(owner, 'events', { save_id: run.save_id, events: [...events, events[0]], after: {} }));
  assert.equal([...f.stored.values()].filter(row => row.collection === 'bound_events_v2').length, 16);
});
test('two simultaneous sessions for one owner cannot replace the winning snapshot or event sequence', () => {
  const { f, create, upload, get, rpc } = setup(); const run = create(); upload(owner, run, uuid(10)).seal();
  const left = upload(owner, run, uuid(11), uuid(10)), right = upload(owner, run, uuid(12), uuid(10));
  const write = f.nk.storageWrite; let raced = false;
  f.nk.storageWrite = rows => {
    if (!raced && rows.length === 1 && rows[0].key === run.save_id) { raced = true; right.seal(); }
    return write(rows);
  };
  assert.throws(left.seal); assert.equal(get(owner, run).saves[owner].receipt.checkpoint, uuid(12));
  f.nk.storageWrite = write;
  const event = kind => ({ run: run.save_id, id: { origin: owner, sequence: 1 }, kind: 'soul',
    payload: Buffer.from(JSON.stringify({ version: 1, run: run.save_id, kind, slot: 'area:1' })).toString('base64') });
  const publish = kind => rpc(owner, 'events', { save_id: run.save_id, events: [event(kind)], after: {} });
  raced = false;
  f.nk.storageWrite = rows => {
    if (!raced && rows.length === 2 && rows[1].collection === 'bound_events_v2') { raced = true; publish('death'); }
    return write(rows);
  };
  assert.throws(() => publish('acquired'));
  assert.equal(rpc(peer, 'events', { save_id: run.save_id, events: [], after: {} }).events[0].payload, event('death').payload);
  assert.equal(get(owner, run).cursors[owner].contiguous, 1);
});

test('idle event polling and identical save acknowledgements do not churn revision or save timestamps', () => {
  const { create, rpc, upload, get } = setup(); const run = create();
  const poll = () => rpc(owner, 'events', { save_id: run.save_id, events: [], after: {} });
  const first = poll(), second = poll(); assert.equal(second.revision, first.revision); assert.equal(second.updated_at, run.updated_at);
  const pending = upload(owner, run, uuid(10)); const sealed = pending.seal(); const retry = pending.seal();
  assert.equal(sealed.revision, retry.revision); assert.equal(sealed.updated_at, retry.updated_at);
  assert.equal(poll().revision, get(owner, run).revision);
});

test('v5 game-over override is shared, debug-only and immutable', () => {
  const { create, get, rpc } = setup();
  const disabled = create({ settings: gameOverSettings(true, true) });
  assert.equal(get(peer, disabled).identity.settings, gameOverSettings(true, true));
  assert.throws(() => rpc(owner, 'gameOver', { save_id: disabled.save_id, eventID: uuid(800) }));
  assert.equal(get(owner, disabled).gameOver, null);
  assert.throws(() => create({ request_id: uuid(2), settings: gameOverSettings(false, true) }));
  const malformed = Buffer.from(gameOverSettings(true, true), 'base64'); malformed[21] = 2;
  assert.throws(() => create({ request_id: uuid(3), settings: malformed.toString('base64') }));
  malformed[21] = 1; malformed[22] = 1;
  assert.throws(() => create({ request_id: uuid(4), settings: malformed.toString('base64') }));
  malformed[22] = 0; malformed[0] = 4;
  assert.throws(() => create({ request_id: uuid(5), settings: malformed.toString('base64') }));
  for (const [index, encoded] of [gameOverSettings(), gameOverSettings(true, false)].entries()) {
    const run = create({ request_id: uuid(10 + index), settings: encoded });
    assert.equal(rpc(owner, 'gameOver', { save_id: run.save_id, eventID: uuid(810 + index) }).deleted, false);
  }
});

test('game over deletes only its exact save after both authenticated clients acknowledge the menu', () => {
  const { f, create, rpc, get, list, upload } = setup();
  const run = create(), other = create({ request_id: uuid(2) });
  upload(owner, run, uuid(10)).seal(); upload(peer, run, uuid(11)).seal(); upload(owner, other, uuid(12)).seal();
  const eventID = uuid(800), fields = { save_id: run.save_id, eventID };
  const start = rpc(owner, 'gameOver', fields);
  assert.deepEqual(start, { id: eventID, returnRequested: false, returned: [], deleted: false });
  const revision = get(owner, run).revision;
  assert.deepEqual(rpc(peer, 'gameOver', { ...fields, eventID: uuid(801) }), start);
  assert.equal(get(owner, run).revision, revision);
  assert.deepEqual(get(peer, run).gameOver, start);
  assert.deepEqual(list(owner).runs.find(value => value.save_id === run.save_id).gameOver, start);
  assert.throws(() => rpc(owner, 'gameOverMenu', fields));
  assert.throws(() => rpc(owner, 'delete', { save_id: run.save_id, expectedRevision: revision, confirmSharedDeletion: true }));
  assert.equal(rpc(peer, 'gameOverReturn', fields).returnRequested, true);
  assert.deepEqual(rpc(owner, 'gameOverMenu', fields).returned, [owner]);
  assert.deepEqual(rpc(owner, 'gameOverMenu', fields).returned, [owner]);
  assert.equal(Object.keys(get(peer, run).saves).length, 2);
  assert.ok([...f.stored.values()].some(row => row.key.startsWith(run.save_id + '/')));
  const complete = rpc(peer, 'gameOverMenu', fields);
  assert.deepEqual(complete, { id: eventID, returnRequested: true, returned: [owner, peer], deleted: true });
  assert.deepEqual(rpc(owner, 'gameOverStatus', fields), complete);
  assert.deepEqual(rpc(owner, 'gameOverMenu', fields), complete);
  assert.equal([...f.stored.values()].filter(row => row.key.startsWith(run.save_id + '/')).length, 0);
  assert.deepEqual(Object.keys(f.stored.get('bound_independent_v2:' + run.save_id).value).sort(), ['deleted', 'gameOver', 'members', 'revision', 'save_id', 'version']);
  assert.equal(get(owner, other).saves[owner].receipt.checkpoint, uuid(12));
  assert.deepEqual(list(peer).runs.map(value => value.save_id), [other.save_id]);
});

test('game-over lifecycle rejects outsiders, conflicting saves, stale IDs and ordinary deletion tombstones', () => {
  const { create, rpc, remove } = setup(); const run = create();
  const fields = { save_id: run.save_id, eventID: uuid(800) };
  assert.throws(() => rpc(owner, 'gameOverStatus', { save_id: run.save_id }));
  assert.throws(() => rpc(owner, 'gameOver', { save_id: run.save_id }));
  assert.throws(() => rpc(owner, 'gameOver', { ...fields, runID: uuid(999) }));
  rpc(owner, 'gameOver', fields);
  for (const action of ['gameOver', 'gameOverReturn', 'gameOverMenu', 'gameOverStatus']) {
    assert.throws(() => rpc(third, action, fields));
    assert.throws(() => rpc(owner, action, { ...fields, eventID: 'invalid' }));
  }
  for (const action of ['gameOverReturn', 'gameOverMenu', 'gameOverStatus']) assert.throws(() => rpc(peer, action, { ...fields, eventID: uuid(801) }));
  rpc(owner, 'gameOverReturn', fields); rpc(owner, 'gameOverMenu', fields); rpc(peer, 'gameOverMenu', fields);
  assert.throws(() => rpc(third, 'gameOverStatus', fields));
  assert.throws(() => rpc(owner, 'gameOverStatus', { ...fields, eventID: uuid(801) }));
  const other = create({ request_id: uuid(2) }); remove(owner, other);
  assert.throws(() => rpc(owner, 'gameOverStatus', { save_id: other.save_id }));
});

test('concurrent game-over starts and menu acknowledgements retain one event and both receipts', () => {
  const { f, create, rpc, get } = setup(); const run = create();
  const original = f.nk.storageWrite; let injected = false;
  f.nk.storageWrite = rows => {
    if (!injected && rows.length === 1 && rows[0].key === run.save_id && rows[0].value.gameOver) {
      injected = true; rpc(peer, 'gameOver', { save_id: run.save_id, eventID: uuid(801) });
    }
    return original(rows);
  };
  assert.equal(rpc(owner, 'gameOver', { save_id: run.save_id, eventID: uuid(800) }).id, uuid(801));
  assert.equal(get(owner, run).gameOver.id, uuid(801));
  const fields = { save_id: run.save_id, eventID: uuid(801) };
  rpc(owner, 'gameOverReturn', fields); injected = false;
  f.nk.storageWrite = rows => {
    if (!injected && rows.length === 1 && rows[0].key === run.save_id && rows[0].value.gameOver.returned.includes(owner)) {
      injected = true; rpc(peer, 'gameOverMenu', fields);
    }
    return original(rows);
  };
  assert.deepEqual(rpc(owner, 'gameOverMenu', fields).returned, [owner, peer]);
  assert.equal(rpc(peer, 'gameOverStatus', fields).deleted, true);
});

test('game-over absorption fences delayed uploads and new events while allowing final reads', () => {
  const { create, rpc, get, upload } = setup(); const run = create();
  const saved = upload(owner, run, uuid(10)); saved.seal();
  const pending = upload(owner, run, uuid(11), uuid(10));
  const event = { run: run.save_id, id: { origin: owner, sequence: 1 }, kind: 'soul', payload: Buffer.from(JSON.stringify({ version: 1, run: run.save_id, kind: 'death', slot: 'area:1' })).toString('base64') };
  rpc(owner, 'events', { save_id: run.save_id, events: [event], after: {} });
  rpc(peer, 'gameOver', { save_id: run.save_id, eventID: uuid(800) });
  assert.throws(pending.seal);
  assert.throws(() => rpc(owner, 'save', pending.fields));
  assert.throws(() => rpc(owner, 'saveChunk', { ...pending.fields, index: 0, data: pending.bytes.toString('base64') }));
  assert.throws(() => rpc(owner, 'events', { save_id: run.save_id, events: [event], after: {} }));
  assert.throws(() => rpc(peer, 'profile', { save_id: run.save_id, profile: { name: 'LEAF', gender: 1 } }));
  assert.equal(get(owner, run).saves[owner].receipt.checkpoint, uuid(10));
  assert.equal(rpc(peer, 'events', { save_id: run.save_id, events: [], after: {} }).events.length, 1);
  assert.deepEqual(Buffer.from(rpc(owner, 'saveDownload', { save_id: run.save_id, checkpoint: uuid(10), index: 0 }).data, 'base64'), saved.bytes);
});

test('game-over CAS racing a child write prevents any new upload after absorption', () => {
  const { f, create, rpc, upload } = setup(); const run = create();
  const original = f.nk.storageWrite; let injected = false;
  f.nk.storageWrite = rows => {
    if (!injected && rows.length === 2 && rows[1].key.includes('/save/')) {
      injected = true; rpc(peer, 'gameOver', { save_id: run.save_id, eventID: uuid(800) });
    }
    return original(rows);
  };
  assert.throws(() => upload(owner, run, uuid(10)));
  assert.equal([...f.stored.values()].filter(row => row.key.startsWith(run.save_id + '/save/')).length, 0);
  assert.equal(rpc(owner, 'gameOverStatus', { save_id: run.save_id }).deleted, false);
});

test('lost final game-over cleanup retries from its tombstone without resurrecting data', () => {
  const { f, create, rpc, upload } = setup(); const run = create(); upload(owner, run, uuid(10)).seal();
  const fields = { save_id: run.save_id, eventID: uuid(800) };
  rpc(owner, 'gameOver', fields); rpc(owner, 'gameOverReturn', fields); rpc(owner, 'gameOverMenu', fields);
  const exec = f.nk.sqlExec; f.nk.sqlExec = () => { throw Error('interrupted cleanup'); };
  assert.throws(() => rpc(peer, 'gameOverMenu', fields));
  assert.equal(f.stored.get('bound_independent_v2:' + run.save_id).value.deleted, true);
  assert.ok([...f.stored.values()].some(row => row.key.startsWith(run.save_id + '/')));
  f.nk.sqlExec = exec;
  assert.equal(rpc(owner, 'gameOverStatus', fields).deleted, true);
  assert.equal([...f.stored.values()].filter(row => row.key.startsWith(run.save_id + '/')).length, 0);
});
