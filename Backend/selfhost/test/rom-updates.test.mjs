import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, symlink, rename, rm, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createROMUpdates } from '../rom-updates.mjs';
import { httpHandler } from '../server.mjs';

const owner = '11111111-1111-4111-8111-111111111111';
const session = '22222222-2222-4222-8222-222222222222';
const content = Buffer.alloc(32 * 1024 * 1024, 0x51);
const sha256 = createHash('sha256').update(content).digest('hex');
const gameID = createHash('sha1').update(content).digest('hex');
const base = { schemaVersion: 1, buildNumber: 500, byteCount: content.length,
  sha256, gameID, gameCommit: 'a'.repeat(40), boundABIHeaderSHA256: 'b'.repeat(64), contract: { layoutVersion: 16 } };
const request = (path, options = {}) => new Request('https://bound.example/rom-updates/' + path, {
  headers: { authorization: 'Bearer synthetic-approved', ...options.headers }, ...options,
});

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'bound-rom-updates-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'generations'));
  async function publish(manifest = base, bytes = content) {
    const generation = `generations/${manifest.buildNumber}-${manifest.sha256.slice(0, 12)}`;
    await mkdir(join(root, generation), { recursive: true });
    await writeFile(join(root, generation, 'manifest.json'), JSON.stringify(manifest));
    await writeFile(join(root, generation, 'RRv4.1M.gba'), bytes);
    await symlink(generation, join(root, 'next')); await rename(join(root, 'next'), join(root, 'current'));
    return join(root, generation);
  }
  const generation = await publish();
  const state = { active: true, approved: true, checks: 0, beforeCheck: null };
  const pool = { async query(_sql, args) {
    assert.deepEqual(args, [owner, session]);
    state.checks++;
    await state.beforeCheck?.();
    return { rows: state.active ? [{ approved: state.approved }] : [] };
  } };
  const authenticate = async request => {
    if (request.headers.get('authorization') !== 'Bearer synthetic-approved') throw Error('unauthorized');
    return { ownerID: owner, sessionID: session };
  };
  const service = createROMUpdates({ pool, authenticate, config: { ROM_UPDATES_ROOT: root } });
  return { root, generation, publish, state, service };
}

test('authenticated approved refresh and complete HTTP download expose independent build and exact bytes', async t => {
  const { service, state } = await fixture(t);
  const server = http.createServer(httpHandler({ config: { PUBLIC_URL: 'https://bound.example' }, handle: service.handle }));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const origin = 'http://127.0.0.1:' + server.address().port;
  const headers = { authorization: 'Bearer synthetic-approved' };
  assert.deepEqual(await (await fetch(origin + '/rom-updates/access', { headers })).json(), { developerApproved: true });
  const latest = await fetch(origin + '/rom-updates/latest', { headers });
  assert.equal(latest.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await latest.json(), base);
  const download = await fetch(`${origin}/rom-updates/download?build=500&sha256=${sha256}`, { headers });
  assert.equal(download.status, 200);
  assert.equal(download.headers.get('x-rom-build-number'), '500');
  assert.equal(download.headers.get('content-length'), String(content.length));
  assert.equal(download.headers.get('cache-control'), 'private, no-store');
  assert.deepEqual(Buffer.from(await download.arrayBuffer()), content);
  assert.equal(state.checks, 5);
});

test('future/unapproved, anonymous and revoked sessions cannot inspect manifests or download', async t => {
  const { service, state } = await fixture(t);
  for (const path of ['access', 'latest', `download?build=500&sha256=${sha256}`]) {
    assert.equal((await service.handle(request(path, { headers: {} }))).status, 401);
  }
  state.approved = false;
  assert.deepEqual(await (await service.handle(request('access'))).json(), { developerApproved: false });
  assert.equal((await service.handle(request('latest'))).status, 403);
  assert.equal((await service.handle(request(`download?build=500&sha256=${sha256}`))).status, 403);
  state.active = false;
  assert.equal((await service.handle(request('access'))).status, 403);
});

test('revocation between refresh/download and during verification is checked from database', async t => {
  const { service, state } = await fixture(t);
  assert.equal((await service.handle(request('latest'))).status, 200);
  state.approved = false;
  assert.equal((await service.handle(request(`download?build=500&sha256=${sha256}`))).status, 403);
  state.approved = true; state.checks = 0;
  state.beforeCheck = () => { if (state.checks === 2) state.approved = false; };
  assert.equal((await service.handle(request(`download?build=500&sha256=${sha256}`))).status, 403);
});

test('a publication superseding the refreshed build returns conflict without another build bytes', async t => {
  const { service, publish } = await fixture(t);
  assert.equal((await service.handle(request('latest'))).status, 200);
  await publish({ ...base, buildNumber: 501 });
  assert.equal((await service.handle(request(`download?build=500&sha256=${sha256}`))).status, 409);
  assert.equal((await (await service.handle(request('latest'))).json()).buildNumber, 501);
});

test('an open download finishes old exact bytes after old generation is retired', async t => {
  const { service, generation, publish } = await fixture(t);
  const response = await service.handle(request(`download?build=500&sha256=${sha256}`));
  await publish({ ...base, buildNumber: 501 });
  await rm(generation, { recursive: true });
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), content);
});

test('corrupt ROM, mismatched gameID, malformed manifest and symlink files fail closed', async t => {
  const { service, generation } = await fixture(t);
  const manifest = join(generation, 'manifest.json');
  await writeFile(manifest, JSON.stringify({ ...base, gameID: '0'.repeat(40) }));
  assert.equal((await service.handle(request('latest'))).status, 503);
  await writeFile(manifest, JSON.stringify({ ...base, byteCount: 3 }));
  assert.equal((await service.handle(request('latest'))).status, 503);
  await writeFile(manifest, JSON.stringify(base));
  await writeFile(join(generation, 'RRv4.1M.gba'), Buffer.alloc(content.length, 0x52));
  assert.equal((await service.handle(request('latest'))).status, 503);
  await unlink(join(generation, 'RRv4.1M.gba'));
  await writeFile(join(generation, 'other'), content);
  await symlink('other', join(generation, 'RRv4.1M.gba'));
  assert.equal((await service.handle(request('latest'))).status, 503);
});

test('public paths, direct generation names, mutation and incomplete download identities are unavailable', async t => {
  const { service } = await fixture(t);
  for (const path of ['current/RRv4.1M.gba', 'generations/500-' + sha256.slice(0, 12) + '/RRv4.1M.gba']) {
    assert.equal((await service.handle(request(path))).status, 404);
  }
  assert.equal((await service.handle(request('latest', { method: 'POST' }))).status, 405);
  for (const path of ['download', 'download?build=500', 'download?sha256=' + sha256]) {
    assert.equal((await service.handle(request(path))).status, 409);
  }
});

test('current cannot escape the generations directory and approval database failures cannot expose files', async t => {
  const { service, root, generation, state } = await fixture(t);
  await unlink(join(root, 'current'));
  await symlink(generation + '/..', join(root, 'current'));
  assert.equal((await service.handle(request('latest'))).status, 503);
  state.beforeCheck = () => { throw Error('database unavailable'); };
  const response = await service.handle(request('latest'));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'rom_unavailable' });
});
