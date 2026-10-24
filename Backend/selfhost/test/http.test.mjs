import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { httpHandler } from '../server.mjs';

async function server(t, handle) {
  const instance = http.createServer(httpHandler({ config: { PUBLIC_URL: 'https://bound.example', TRUST_PROXY: false }, handle }));
  await new Promise(resolve => instance.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { instance.closeAllConnections(); instance.close(resolve); }));
  return 'http://127.0.0.1:' + instance.address().port;
}
test('caller cannot spoof the trusted client address used for throttling', async t => {
  let actual;
  const origin = await server(t, async request => { actual = request.headers.get('x-bound-client-ip'); return new Response('ok'); });
  const response = await fetch(origin + '/auth/v1/user', { headers: { 'x-bound-client-ip': '1.2.3.4', 'x-forwarded-for': '1.2.3.4' } });
  assert.equal(response.status, 200);
  assert.equal(actual, '127.0.0.1');
});
test('oversized account requests are rejected before dispatch', async t => {
  let dispatched = false;
  const origin = await server(t, async () => { dispatched = true; return new Response('ok'); });
  const response = await fetch(origin + '/auth/v1/signup', { method: 'POST', body: 'x'.repeat(65537) });
  assert.equal(response.status, 413);
  assert.equal(dispatched, false);
});
test('save backup PUT accepts file-sized bodies while provider requests keep the JSON limit', async t => {
  let received = 0;
  const origin = await server(t, async request => { received = (await request.arrayBuffer()).byteLength; return new Response('ok'); });
  assert.equal((await fetch(origin + '/backups/v1/saves/game', { method: 'PUT', body: 'x'.repeat(70000) })).status, 200);
  assert.equal(received, 70000);
  assert.equal((await fetch(origin + '/backups/v1/provider', { method: 'PUT', body: 'x'.repeat(70000) })).status, 413);
});
test('anonymous username queries have a bounded per-client rate', async t => {
  const origin = await server(t, async () => new Response('ok'));
  const statuses = [];
  for (let i = 0; i < 31; i++) statuses.push((await fetch(origin + '/rest/v1/rpc/bound_username_available', { method: 'POST', body: '{}' })).status);
  assert.equal(statuses[29], 200);
  assert.equal(statuses[30], 429);
});
test('disconnecting a request rejects its body reader promptly', async t => {
  let entered;
  const started = new Promise(resolve => { entered = resolve; });
  let ended;
  const finished = new Promise(resolve => { ended = resolve; });
  const origin = await server(t, async request => {
    entered();
    try { await request.text(); ended(false); }
    catch { ended(true); }
    return new Response('done');
  });
  const upload = http.request(origin + '/auth/v1/signup', { method: 'POST', headers: { 'content-length': 100 } });
  upload.on('error', () => {});
  upload.write('partial');
  await started;
  upload.destroy();
  const timeout = setTimeout(() => ended(false), 2000);
  try { assert.equal(await finished, true); } finally { clearTimeout(timeout); }
});
