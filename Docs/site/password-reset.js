// Public client configuration shared with Delta/Bound/cloud-configuration.json.
// Recovery credentials stay inside this page's controller and are never persisted.
export const AUTH_ORIGIN = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
export const PUBLISHABLE_KEY = 'sb_publishable_iPQ3Ti3fwN6e16zhFZw5zQ_aKoj8WGr';
const MAX_RESPONSE_BYTES = 65536;
const REQUEST_TIMEOUT_MS = 10000;
const INVALID_LINK = 'This reset link is invalid or has expired. Request a new link from Forgot password in Bound.';

export function consumeRecoveryURL(location, history) {
  let url;
  try { url = new URL(location.href); }
  catch { return null; }
  const fragment = url.hash.slice(1);
  // Remove both fragments and query strings before validation, rendering, or requests.
  // If history cannot be cleared, do not continue with credentials in the address bar.
  try { history.replaceState(null, '', url.pathname); }
  catch { return null; }
  if (url.protocol !== 'https:' || fragment.length > 32768) return null;
  const parameters = new URLSearchParams(fragment);
  const tokens = parameters.getAll('access_token');
  if (parameters.getAll('type').length !== 1 || parameters.get('type') !== 'recovery' ||
      tokens.length !== 1 || !tokens[0] || tokens[0].length > 16384 || /[\s\u0000-\u001f\u007f]/u.test(tokens[0]) ||
      parameters.has('error') || parameters.has('error_code')) return null;
  return tokens[0];
}

export function passwordValidation(password, confirmation) {
  if (typeof password !== 'string' || password.length < 8) return 'Use at least 8 characters for your new password.';
  if (password.length > 1024) return 'Use a password with no more than 1024 characters.';
  if (password !== confirmation) return 'The passwords do not match. Enter them again.';
  return null;
}

function validUser(user) {
  return user && typeof user.id === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(user.id) &&
    user.role === 'authenticated' && user.is_anonymous === false &&
    typeof user.email_confirmed_at === 'string' && user.email_confirmed_at.length > 0 &&
    typeof user.email === 'string' && user.email.length <= 254 && /^[^\s@]+@[^\s@]+$/.test(user.email);
}

export function createRecoveryController({ location, history, view, fetchImpl = globalThis.fetch,
  setTimeoutImpl = globalThis.setTimeout, clearTimeoutImpl = globalThis.clearTimeout }) {
  let accessToken = consumeRecoveryURL(location, history);
  let disposed = false;
  let started = false;
  let busy = false;
  let ready = false;
  const requests = new Set();
  let state = { stage: 'checking', email: '', status: 'Checking your reset link…' };
  const render = (next) => {
    state = { ...state, ...next };
    if (!disposed) view.render({ ...state });
  };
  render({});

  async function request(path, method = 'GET', body) {
    if (!accessToken || disposed) throw new Error('Recovery unavailable');
    const controller = new AbortController();
    requests.add(controller);
    const timeout = setTimeoutImpl(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const url = AUTH_ORIGIN + '/auth/v1' + path;
      const response = await fetchImpl(url, {
        method, headers: { apikey: PUBLISHABLE_KEY, Authorization: 'Bearer ' + accessToken,
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        credentials: 'omit', cache: 'no-store', redirect: 'error', referrerPolicy: 'no-referrer',
        mode: 'cors', signal: controller.signal,
      });
      if (controller.signal.aborted || disposed) throw new Error('Recovery unavailable');
      if (response.url && response.url !== url) throw new Error('Unexpected response');
      let length = 0;
      const chunks = [];
      if (response.body) {
        const reader = response.body.getReader();
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (controller.signal.aborted || disposed) throw new Error('Recovery unavailable');
            if (done) break;
            length += value.byteLength;
            if (length > MAX_RESPONSE_BYTES) {
              await reader.cancel();
              throw new Error('Response too large');
            }
            chunks.push(value);
          }
        } finally { reader.releaseLock(); }
      }
      const bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      let data = null;
      if (length && response.headers.get('content-type')?.includes('application/json')) {
        try { data = JSON.parse(new TextDecoder().decode(bytes)); }
        catch { /* Never display raw response content. */ }
      }
      return { status: response.status, data };
    } finally {
      clearTimeoutImpl(timeout);
      requests.delete(controller);
    }
  }

  async function initialize() {
    if (started || disposed) return;
    started = true;
    if (!accessToken) { render({ stage: 'invalid', status: INVALID_LINK }); return; }
    try {
      const response = await request('/user');
      if (disposed) return;
      if (response.status !== 200 || !validUser(response.data)) {
        accessToken = null;
        render({ stage: 'invalid', status: INVALID_LINK });
        return;
      }
      ready = true;
      render({ stage: 'ready', email: response.data.email, status: 'Choose a new password for your Bound account.' });
    } catch {
      if (disposed) return;
      accessToken = null;
      render({ stage: 'invalid', status: 'Could not check your reset link. Open the link from your email again, or request a new link in Bound.' });
    }
  }

  async function submit(password, confirmation) {
    if (disposed || !ready || busy || !accessToken) return;
    const validation = passwordValidation(password, confirmation);
    if (validation) { render({ status: validation }); return; }
    busy = true;
    render({ stage: 'submitting', status: 'Saving your new password…' });
    try {
      const response = await request('/user', 'PUT', { password });
      if (disposed) return;
      if (response.status === 200) {
        ready = false;
        view.clearPasswords();
        render({ stage: 'success', status: 'Your password has been updated. Return to Bound and sign in with your email and new password.' });
        // The browser recovery session is separate from any device's Bound login.
        try { await request('/logout?scope=local', 'POST'); } catch { /* Best effort only. */ }
        accessToken = null;
        return;
      }
      const code = response.data?.code ?? response.data?.error_code;
      if (response.status === 401 || response.status === 403) {
        ready = false; accessToken = null; view.clearPasswords();
        render({ stage: 'invalid', status: INVALID_LINK });
      } else if (code === 'weak_password') {
        render({ stage: 'ready', status: 'Choose a stronger password with a mix of letters, numbers, and symbols.' });
      } else if (code === 'same_password') {
        render({ stage: 'ready', status: 'Choose a password different from your previous password.' });
      } else {
        render({ stage: 'ready', status: response.status === 429 ? 'Too many attempts. Wait a moment, then try again.' : 'Could not update your password. Check your connection and try again.' });
      }
    } catch {
      if (!disposed) render({ stage: 'ready', status: 'Could not confirm the password update. Try again, or return to Bound and try signing in with your new password.' });
    } finally { busy = false; }
  }

  function dispose() {
    disposed = true; ready = false; accessToken = null;
    for (const request of requests) request.abort();
    requests.clear();
    view.clearPasswords();
  }
  return { initialize, submit, dispose };
}

export function startBrowser(window, document) {
  const form = document.getElementById('reset-form');
  const password = document.getElementById('new-password');
  const confirmation = document.getElementById('confirm-password');
  const button = document.getElementById('reset-submit');
  const status = document.getElementById('reset-status');
  const email = document.getElementById('reset-email');
  const controller = createRecoveryController({ location: window.location, history: window.history,
    fetchImpl: window.fetch.bind(window), view: {
      clearPasswords() { password.value = ''; confirmation.value = ''; },
      render(state) {
        status.textContent = state.status;
        email.textContent = state.email;
        email.hidden = !state.email;
        form.hidden = state.stage !== 'ready' && state.stage !== 'submitting';
        password.disabled = confirmation.disabled = button.disabled = state.stage !== 'ready';
        form.setAttribute('aria-busy', state.stage === 'submitting' ? 'true' : 'false');
        button.textContent = state.stage === 'submitting' ? 'Saving…' : 'Save new password';
      },
    },
  });
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    void controller.submit(password.value, confirmation.value);
  });
  window.addEventListener('pagehide', () => controller.dispose(), { once: true });
  // A page restored from the back/forward cache must not restore a usable form.
  window.addEventListener('pageshow', (event) => { if (event.persisted) window.location.reload(); });
  void controller.initialize();
  return controller;
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') startBrowser(window, document);
