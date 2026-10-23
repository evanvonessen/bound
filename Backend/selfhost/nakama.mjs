import { randomUUID } from 'node:crypto';
// All privileged Nakama calls stay on the private Compose network.
export class NakamaError extends Error {
  constructor(status, code) { super('Nakama request failed'); this.status = status; this.code = code; }
}
export function createNakamaClient(config, fetchImpl = fetch) {
  const origin = new URL(config.NAKAMA_INTERNAL_URL || config.NAKAMA_HTTP_URL || 'http://nakama:7350');
  if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/') throw Error('Invalid private Nakama URL');
  for (const name of ['NAKAMA_SERVER_KEY', 'NAKAMA_HTTP_KEY', 'BOUND_GATEWAY_SECRET']) if (!config[name] || config[name].length < 32) throw Error(name + ' must have at least 32 characters');
  async function request(path, body, token) {
    const response = await fetchImpl(new URL(path, origin), { method: body === undefined ? 'GET' : 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: token ? 'Bearer ' + token : 'Basic ' + Buffer.from(config.NAKAMA_SERVER_KEY + ':').toString('base64') },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: 'error', signal: AbortSignal.timeout(10000) });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new NakamaError(response.status, data.code);
    return data;
  }
  async function rpc(action, body = {}) {
    const response = await request('/v2/rpc/bound_account_v1?http_key=' + encodeURIComponent(config.NAKAMA_HTTP_KEY), JSON.stringify({ ...body, action, gatewaySecret: config.BOUND_GATEWAY_SECRET }));
    return typeof response.payload === 'string' ? JSON.parse(response.payload) : response;
  }
  return {
    rpc,
    account: id => rpc('account', { id }),
    lookup: email => rpc('lookup', { email }),
    signup: (email, password, username) => rpc('signup', { email, password, username }),
    password: (email, password) => rpc('password', { email, password }),
    confirm: id => rpc('confirm', { id }),
    updatePassword: (id, password) => rpc('update_password', { id, password }),
    updateEmail: (id, email) => rpc('update_email', { id, email }),
    deleteAccount: id => rpc('delete', { id }),
    logout: (id, token, refreshToken) => rpc('logout', { id, token, refreshToken }),
    read: (id, collection, key) => rpc('storage_read', { id, collection, key }),
    write: (id, collection, key, value, version = '*') => rpc('storage_write', { id, collection, key, value, version }),
    remove: (id, collection, key, version) => rpc('storage_delete', { id, collection, key, version }),
    list: (id, collection) => rpc('storage_list', { id, collection }),
    session: (id, sessionID, aal) => request('/v2/account/authenticate/custom?create=false', { id: 'bound-selfhost:' + id, vars: { bound_gateway: config.BOUND_GATEWAY_SECRET, session_id: sessionID, session_nonce: randomUUID(), aal } }),
    refresh: (refreshToken, sessionID, aal, email) => request('/v2/account/session/refresh', { token: refreshToken, vars: { bound_gateway: config.BOUND_GATEWAY_SECRET, session_id: sessionID, session_nonce: randomUUID(), aal, email } }),
    validate: token => request('/v2/account', undefined, token),
  };
}
