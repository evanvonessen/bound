import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(new URL('../Docs/site/password-reset.js', import.meta.url), 'utf8');
const { AUTH_ORIGIN, PUBLISHABLE_KEY, consumeRecoveryURL, createRecoveryController, passwordValidation, startBrowser } =
  await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const user = { id: '21436587-1234-1234-1234-123456789abc', role: 'authenticated', is_anonymous: false,
  email: 'player@example.com', email_confirmed_at: '2026-01-01T00:00:00Z' };
const token = 'synthetic.recovery.token';
const link = 'https://evanvonessen.github.io/bound/reset-password.html?tracking=removed#access_token=' + token +
  '&refresh_token=never-retained&type=recovery';
const json = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });

function fixture(options = {}) {
  const calls = [], states = [], clearedURLs = [], timers = new Map();
  let clearedPasswords = 0, counter = 0;
  const controller = createRecoveryController({
    location: { href: options.link ?? link },
    history: { replaceState(state, unused, path) { clearedURLs.push({ state, path }); } },
    view: { render(state) { states.push(state); }, clearPasswords() { clearedPasswords += 1; } },
    fetchImpl: async (url, request) => {
      assert.equal(clearedURLs.length, 1, 'credentials are cleared before the first request');
      calls.push({ url, request });
      if (options.fetch) return options.fetch(url, request, calls.length);
      if (request.method === 'GET') return json(options.user ?? user);
      return json({});
    },
    setTimeoutImpl(callback, delay) { const id = ++counter; timers.set(id, { callback, delay }); return id; },
    clearTimeoutImpl(id) { timers.delete(id); },
  });
  return { controller, calls, states, clearedURLs, timers,
    get state() { return states.at(-1); }, get clearedPasswords() { return clearedPasswords; } };
}

test('public config matches the native app and HTML restricts network to that origin', async () => {
  const configuration = JSON.parse(await readFile(new URL('../Delta/Bound/cloud-configuration.json', import.meta.url), 'utf8'));
  assert.equal(AUTH_ORIGIN, configuration.origin);
  assert.equal(PUBLISHABLE_KEY, configuration.publishableKey);
  assert.match(PUBLISHABLE_KEY, /^sb_publishable_/);
  const html = await readFile(new URL('../Docs/site/reset-password.html', import.meta.url), 'utf8');
  assert.match(html, /default-src 'none'/);
  assert.match(html, /connect-src https:\/\/qevnxhngdtlyihhmvnjv\.supabase\.co;/);
  assert.match(html, /form-action 'none'/);
  assert.match(html, /name="referrer" content="no-referrer"/);
  assert.doesNotMatch(html, /(?:src|href)="(?:https?:)?\/\//);
  assert.doesNotMatch(source, /localStorage|sessionStorage|indexedDB|document\.cookie|console\./);
});

test('consumes only one implicit recovery access token and clears the whole query and fragment', () => {
  let cleared;
  assert.equal(consumeRecoveryURL({ href: link }, { replaceState(...args) { cleared = args; } }), token);
  assert.deepEqual(cleared, [null, '', '/bound/reset-password.html']);
  for (const fragment of ['', 'access_token=x&type=signup', 'access_token=x', 'access_token=x&type=recovery&type=recovery',
    'access_token=x&access_token=y&type=recovery', 'access_token=x%0Ay&type=recovery', 'access_token=x&type=recovery&error=bad']) {
    const f = fixture({ link: 'https://evanvonessen.github.io/bound/reset-password.html?access_token=query-only#' + fragment });
    assert.equal(f.clearedURLs[0].path, '/bound/reset-password.html');
    f.controller.dispose();
  }
  assert.equal(consumeRecoveryURL({ href: link }, { replaceState() { throw new Error('blocked'); } }), null);
  assert.equal(consumeRecoveryURL({ href: link.replace('https:', 'http:') }, { replaceState() {} }), null);
});

test('invalid and non-recovery links never reach the network or enable password entry', async () => {
  for (const fragment of ['', 'access_token=x&type=signup', 'access_token=x', 'access_token=x&type=recovery&error=bad',
    'access_token=x&access_token=y&type=recovery']) {
    const f = fixture({ link: 'https://evanvonessen.github.io/bound/reset-password.html#' + fragment });
    await f.controller.initialize();
    await f.controller.submit('new-password', 'new-password');
    assert.equal(f.calls.length, 0);
    assert.equal(f.state.stage, 'invalid');
  }
});

test('validates the recovered identity before showing its read-only email or accepting a password', async () => {
  const f = fixture();
  await f.controller.submit('new-password', 'new-password');
  assert.equal(f.calls.length, 0);
  await f.controller.initialize();
  assert.equal(f.state.stage, 'ready');
  assert.equal(f.state.email, user.email);
  assert.equal(f.calls[0].url, AUTH_ORIGIN + '/auth/v1/user');
  assert.equal(f.calls[0].request.headers.Authorization, 'Bearer ' + token);
  assert.ok(f.states.every(state => !JSON.stringify(state).includes(token)));
  assert.ok(f.states.every(state => !JSON.stringify(state).includes('never-retained')));
});

test('rejects malformed, anonymous, unconfirmed, and expired recovered users', async () => {
  for (const replacement of [{ ...user, id: 'invalid' }, { ...user, role: 'anon' }, { ...user, is_anonymous: true },
    { ...user, email_confirmed_at: null }, { ...user, email: '<invalid>' }]) {
    const f = fixture({ user: replacement });
    await f.controller.initialize();
    await f.controller.submit('new-password', 'new-password');
    assert.equal(f.calls.length, 1);
    assert.equal(f.state.stage, 'invalid');
    assert.equal(f.state.email, '');
  }
  const expired = fixture({ fetch: () => json({ message: 'raw-private-error' }, 401) });
  await expired.controller.initialize();
  assert.equal(expired.state.stage, 'invalid');
  assert.doesNotMatch(expired.state.status, /raw-private-error/);
});

test('short passwords, confirmation mismatch, and oversized passwords do not send updates', async () => {
  const f = fixture();
  await f.controller.initialize();
  for (const values of [['short', 'short'], ['new-password', 'different'], ['x'.repeat(1025), 'x'.repeat(1025)]]) {
    assert.ok(passwordValidation(...values));
    await f.controller.submit(...values);
    assert.equal(f.calls.length, 1);
    assert.equal(f.state.stage, 'ready');
  }
});

test('updates only the password on the trusted origin and locally revokes the browser session', async () => {
  const f = fixture();
  await f.controller.initialize();
  await f.controller.submit('new-password', 'new-password');
  assert.deepEqual(f.calls.map(call => [call.url, call.request.method]), [
    [AUTH_ORIGIN + '/auth/v1/user', 'GET'],
    [AUTH_ORIGIN + '/auth/v1/user', 'PUT'],
    [AUTH_ORIGIN + '/auth/v1/logout?scope=local', 'POST'],
  ]);
  assert.deepEqual(JSON.parse(f.calls[1].request.body), { password: 'new-password' });
  for (const { url, request } of f.calls) {
    assert.equal(new URL(url).origin, AUTH_ORIGIN);
    assert.equal(request.redirect, 'error');
    assert.equal(request.credentials, 'omit');
    assert.equal(request.cache, 'no-store');
    assert.equal(request.referrerPolicy, 'no-referrer');
    assert.equal(request.headers.apikey, PUBLISHABLE_KEY);
    assert.ok(request.signal instanceof AbortSignal);
    assert.doesNotMatch(url, /synthetic|never-retained|new-password/);
  }
  assert.equal(f.state.stage, 'success');
  assert.equal(f.clearedPasswords, 1);
  assert.equal(f.timers.size, 0);
  await f.controller.submit('another-password', 'another-password');
  assert.equal(f.calls.length, 3);
});

test('duplicate submissions send only one update while it is pending', async () => {
  let release;
  const f = fixture({ fetch: (url, request) => request.method === 'PUT' ? new Promise(resolve => { release = resolve; }) : json(user) });
  await f.controller.initialize();
  const submission = f.controller.submit('new-password', 'new-password');
  await f.controller.submit('other-password', 'other-password');
  assert.equal(f.calls.filter(call => call.request.method === 'PUT').length, 1);
  release(json(user));
  await submission;
  assert.equal(f.state.stage, 'success');
});

test('server errors use safe messages and allow correction without exposing backend details', async () => {
  for (const [code, status, expected] of [['weak_password', 422, /stronger password/], ['same_password', 422, /different/],
    ['anything', 429, /Too many/], ['anything', 500, /Could not update/]]) {
    const f = fixture({ fetch: (url, request) => request.method === 'GET' ? json(user) : json({ code, message: 'RAW_PRIVATE_ERROR' }, status) });
    await f.controller.initialize();
    await f.controller.submit('new-password', 'new-password');
    assert.equal(f.state.stage, 'ready');
    assert.match(f.state.status, expected);
    assert.doesNotMatch(f.state.status, /RAW_PRIVATE_ERROR/);
  }
});

test('expired update credentials disable the form and cannot be retried', async () => {
  const f = fixture({ fetch: (url, request) => request.method === 'GET' ? json(user) : json({}, 401) });
  await f.controller.initialize();
  await f.controller.submit('new-password', 'new-password');
  await f.controller.submit('new-password', 'new-password');
  assert.equal(f.state.stage, 'invalid');
  assert.equal(f.calls.length, 2);
  assert.equal(f.clearedPasswords, 1);
});

test('logout failures preserve a successful reset', async () => {
  const f = fixture({ fetch: (url, request) => {
    if (url.includes('/logout')) throw new Error('offline');
    return json(request.method === 'GET' ? user : {});
  } });
  await f.controller.initialize();
  await f.controller.submit('new-password', 'new-password');
  assert.equal(f.state.stage, 'success');
  assert.equal(f.timers.size, 0);
});

test('oversized responses and redirects cannot enable the form', async () => {
  for (const fetch of [() => new Response('x'.repeat(65537)), () => ({ url: 'https://untrusted.example/user' })]) {
    const f = fixture({ fetch });
    await f.controller.initialize();
    assert.equal(f.state.stage, 'invalid');
    assert.equal(f.timers.size, 0);
  }
});

test('timeouts abort requests; disposing clears credentials, aborts work, and fences late results', async () => {
  let release;
  const f = fixture({ fetch: () => new Promise(resolve => { release = resolve; }) });
  const initialization = f.controller.initialize();
  const timer = [...f.timers.values()][0];
  assert.equal(timer.delay, 10000);
  timer.callback();
  assert.equal(f.calls[0].request.signal.aborted, true);
  f.controller.dispose();
  const count = f.states.length;
  release(json(user));
  await initialization;
  await f.controller.submit('new-password', 'new-password');
  assert.equal(f.states.length, count);
  assert.equal(f.calls.length, 1);
  assert.equal(f.clearedPasswords, 1);
  assert.equal(f.timers.size, 0);
});

test('browser wiring disables fields until validation and renders email as plain text', async () => {
  const nodes = Object.fromEntries(['reset-form', 'new-password', 'confirm-password', 'reset-submit', 'reset-status', 'reset-email'].map(id =>
    [id, { value: '', textContent: '', hidden: true, disabled: true, listeners: {},
      addEventListener(type, callback) { this.listeners[type] = callback; }, setAttribute() {} }]));
  const listeners = {};
  const document = { getElementById(id) { return nodes[id]; } };
  const window = { location: { href: link }, history: { replaceState() {} },
    addEventListener(type, callback) { listeners[type] = callback; }, fetch: async () => json(user) };
  const controller = startBrowser(window, document);
  assert.equal(nodes['new-password'].disabled, true);
  await new Promise(setImmediate);
  assert.equal(nodes['reset-form'].hidden, false);
  assert.equal(nodes['new-password'].disabled, false);
  assert.equal(nodes['confirm-password'].disabled, false);
  assert.equal(nodes['reset-email'].textContent, user.email);
  assert.equal(nodes['reset-email'].hidden, false);
  assert.equal(typeof nodes['reset-form'].listeners.submit, 'function');
  nodes['new-password'].value = 'not-persisted';
  nodes['confirm-password'].value = 'not-persisted';
  listeners.pagehide();
  assert.equal(nodes['new-password'].value, '');
  assert.equal(nodes['confirm-password'].value, '');
  controller.dispose();
});
