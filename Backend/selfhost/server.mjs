import http from 'node:http';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { configuration } from './config.mjs';
import { createNakamaClient } from './nakama.mjs';
import { createAuth } from './auth.mjs';
import { createServices } from './services.mjs';
import { createFileService } from './files.mjs';
import { createDeletion } from './deletion.mjs';
import { migrate } from './migrate.mjs';

const json = (status, error) => new Response(JSON.stringify({ error }), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
const privatePeer = value => /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(value.replace(/^::ffff:/, '')) || value === '::1';

export function httpHandler({ config, handle }) {
  const requests = new Map();
  return async (incoming, outgoing) => {
    try {
      const url = new URL(incoming.url, config.PUBLIC_URL);
      if (url.origin !== new URL(config.PUBLIC_URL).origin) { outgoing.writeHead(400); outgoing.end(); return; }
      const upload = incoming.method === 'PUT' && url.pathname.startsWith('/files/');
      const limit = upload ? Number(config.FILE_MAX_BYTES ?? 67108864) : 65536;
      if (Number(incoming.headers['content-length'] ?? 0) > limit) { outgoing.writeHead(413); outgoing.end(); return; }
      const headers = new Headers();
      for (const [key, value] of Object.entries(incoming.headers)) if (value !== undefined && !['host', 'connection', 'transfer-encoding', 'x-bound-client-ip', 'x-forwarded-for', 'forwarded'].includes(key)) headers.set(key, Array.isArray(value) ? value.join(',') : value);
      const peer = incoming.socket.remoteAddress || 'unknown';
      const forwarded = incoming.headers['x-bound-client-ip'];
      const clientIP = config.TRUST_PROXY && privatePeer(peer) && typeof forwarded === 'string' ? forwarded : peer;
      headers.set('x-bound-client-ip', clientIP);
      if (url.pathname !== '/healthz') {
        const time = Date.now(), key = clientIP + (url.pathname.endsWith('/bound_username_available') ? ':username' : ':general');
        if (requests.size >= 4096) for (const [key, value] of requests) if (value.until <= time) requests.delete(key);
        let bucket = requests.get(key);
        if (!bucket || bucket.until <= time) {
          if (requests.size >= 4096) { outgoing.writeHead(429, { 'Retry-After': '60' }); outgoing.end(); return; }
          bucket = { count: 0, until: time + 60000 }; requests.set(key, bucket);
        }
        if (++bucket.count > (key.endsWith(':username') ? 30 : 120)) { outgoing.writeHead(429, { 'Retry-After': '60' }); outgoing.end(); return; }
      }
      let size = 0;
      const bounded = new Transform({ transform(chunk, _encoding, callback) {
        size += chunk.length;
        callback(size > limit ? Error('request_too_large') : null, chunk);
      }});
      const hasBody = !['GET', 'HEAD'].includes(incoming.method);
      if (hasBody) {
        incoming.once('aborted', () => bounded.destroy(Error('request_aborted')));
        incoming.once('error', error => bounded.destroy(error));
        incoming.pipe(bounded);
      }
      const request = new Request(url, { method: incoming.method, headers, ...(hasBody ? { body: Readable.toWeb(bounded), duplex: 'half' } : {}) });
      const response = await handle(request);
      outgoing.writeHead(response.status, Object.fromEntries(response.headers));
      if (response.body && incoming.method !== 'HEAD') await pipeline(Readable.fromWeb(response.body), outgoing);
      else outgoing.end();
      if (!incoming.complete) incoming.resume();
    } catch {
      if (!outgoing.headersSent) outgoing.writeHead(503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      outgoing.end('{"error":"unavailable"}');
    }
  };
}

export async function start(env = process.env) {
  const config = configuration(env);
  const pool = new pg.Pool({ connectionString: config.DATABASE_URL, max: 8, connectionTimeoutMillis: 5000, idleTimeoutMillis: 30000 });
  pool.on('error', () => console.error('Database connection unavailable'));
  await migrate(pool);
  const nakama = createNakamaClient(config);
  const auth = createAuth({ nakama, config });
  const services = createServices({ pool, authenticate: auth.authenticate, config });
  const files = createFileService({ pool, authenticate: auth.authenticate, rpc: services.rpc, config });
  const deletion = createDeletion({ pool, auth, files });
  const handle = async request => {
    if (new URL(request.url).pathname === '/healthz' && request.method === 'GET') {
      try { await pool.query('SELECT 1'); return new Response('{"status":"ok"}', { headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } }); }
      catch { return json(503, 'unavailable'); }
    }
    return await deletion.handle(request) ?? await auth.handle(request) ?? await services.handle(request) ?? await files.handle(request) ?? json(404, 'not_found');
  };
  const server = http.createServer({ maxHeaderSize: 16384, requestTimeout: 60000, headersTimeout: 15000 }, httpHandler({ config, handle }));
  server.maxConnections = 256;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(config.PORT, config.HOST ?? '0.0.0.0', resolve); });
  const cleanup = setInterval(() => files.cleanup().catch(() => console.error('File cleanup failed')), 60000);
  cleanup.unref();
  console.log('Bound gateway ready');
  return async () => { clearInterval(cleanup); await new Promise(resolve => server.close(resolve)); await services.close(); await pool.end(); };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  start().then(stop => { for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => void stop().then(() => process.exit(0))); })
    .catch(() => { console.error('Bound gateway startup failed; check private configuration and database migrations.'); process.exitCode = 1; });
}
