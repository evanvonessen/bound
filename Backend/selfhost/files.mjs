import { createHash, randomUUID } from 'node:crypto';
import { mkdir, unlink, rename, stat, readdir } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { resolve, join } from 'node:path';
import { readJSON, reply, uuid } from './services.mjs';

const number = (value, fallback) => {
  const result = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(result) || result < 1) throw Error('Invalid file-service limit');
  return result;
};
// A transfer is temporary. It is never an account system or a durable save store.
export function createFileService({ pool, authenticate, rpc, config = process.env }) {
  const directory = resolve(config.FILE_DIRECTORY ?? '/var/lib/bound/files');
  const maxFile = number(config.FILE_MAX_BYTES, 64 * 1024 * 1024);
  const maxOwner = number(config.FILE_OWNER_BYTES, 128 * 1024 * 1024);
  const maxTotal = number(config.FILE_TOTAL_BYTES, 512 * 1024 * 1024);
  const ttl = number(config.FILE_TTL_SECONDS, 3600);
  const initialized = mkdir(directory, { recursive: true, mode: 0o700 });
  const uploads = new Map();
  const removeFile = async name => {
    try { await unlink(join(directory, name)); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  };
  const ownerOf = identity => identity?.ownerID ?? identity?.id;
  async function authorized(identity, transfer) {
    if (!transfer || new Date(transfer.expires_at).getTime() <= Date.now()) return false;
    const owner = ownerOf(identity);
    if (!uuid.test(owner ?? '')) return false;
    if (!transfer.shared) return transfer.owner === owner;
    if (!transfer.room) return false;
    const room = await rpc(identity, 'bound_nakama_room_v1', { payload: { roomID: transfer.room } });
    return room?.ownerID === owner && room.members?.includes(owner) && room.members.includes(transfer.owner);
  }
  async function cleanup() {
    await initialized;
    const expired = await pool.query(`SELECT id FROM bound_files_private.transfers t
      WHERE expires_at<=now() OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=t.owner AND u.deleted_at IS NULL)
      `);
    for (const row of expired.rows) {
      if (!uuid.test(row.id)) continue;
      await removeFile(row.id); await removeFile(row.id + '.part');
      await pool.query('DELETE FROM bound_files_private.transfers WHERE id=$1', [row.id]);
    }
    // Recover crash leftovers without walking paths supplied by clients.
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (!entry.isFile() || !/^[a-f0-9-]{36}(?:\.part)?$/.test(entry.name)) continue;
      const file = join(directory, entry.name);
      const details = await stat(file).catch(() => null);
      if (details && Date.now() - details.mtimeMs > (ttl + 300) * 1000) await unlink(file).catch(() => {});
    }
  }
  async function purgeOwner(owner) {
    if (!uuid.test(owner ?? '')) throw Error('invalid_owner');
    await initialized;
    const pending = [...uploads.values()].filter(upload => upload.owner === owner);
    for (const upload of pending) upload.controller.abort();
    await Promise.all(pending.map(upload => upload.finished));
    const result = await pool.query('SELECT id FROM bound_files_private.transfers WHERE owner=$1', [owner]);
    for (const row of result.rows) {
      if (!uuid.test(row.id)) throw Error('invalid_transfer');
      for (const name of [row.id, row.id + '.part']) await removeFile(name);
    }
    await pool.query('DELETE FROM bound_files_private.transfers WHERE owner=$1', [owner]);
  }

  async function handle(request) {
    const path = new URL(request.url).pathname;
    if (!path.startsWith('/files/v1/transfers')) return null;
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    let identity;
    try { identity = await authenticate(request); if (!uuid.test(ownerOf(identity) ?? '')) throw Error(); }
    catch { return reply(401, { error: 'unauthorized' }); }
    try { if (await rpc(identity, 'cup117_account_active', {}) !== true) return reply(403, { error: 'forbidden' }); }
    catch { return reply(403, { error: 'forbidden' }); }
    const owner = ownerOf(identity);
    await initialized;
    if (path === '/files/v1/transfers') {
      if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
      let body;
      try { body = await readJSON(request, 512); } catch { return reply(400, { error: 'invalid_request' }); }
      if (!body || Array.isArray(body) || Object.keys(body).some(key => !['size', 'roomID', 'sha256'].includes(key)) ||
        !Number.isSafeInteger(body.size) || body.size < 1 || body.size > maxFile ||
        (body.roomID !== undefined && !uuid.test(body.roomID)) ||
        (body.sha256 !== undefined && !/^[a-f0-9]{64}$/.test(body.sha256))) return reply(400, { error: 'invalid_request' });
      const id = randomUUID();
      const transfer = { id, owner, room: body.roomID ?? null, shared: !!body.roomID, expires_at: new Date(Date.now() + ttl * 1000) };
      if (!await authorized(identity, transfer)) return reply(403, { error: 'forbidden' });
      await cleanup();
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        await client.query('SELECT cup117_private.assert_active($1::uuid)', [owner]);
        await client.query('SELECT pg_advisory_xact_lock(81720261023)');
        const usage = await client.query(`SELECT coalesce(sum(size),0)::text AS total,
          coalesce(sum(size) FILTER (WHERE owner=$1),0)::text AS own,
          count(*)::integer AS total_count,count(*) FILTER (WHERE owner=$1)::integer AS own_count
          FROM bound_files_private.transfers`, [owner]);
        if (Number(usage.rows[0].total) + body.size > maxTotal || Number(usage.rows[0].own) + body.size > maxOwner ||
          usage.rows[0].total_count >= 256 || usage.rows[0].own_count >= 32) {
          await client.query('ROLLBACK'); return reply(429, { error: 'storage_limit' });
        }
        await client.query(`INSERT INTO bound_files_private.transfers(id,owner,room,shared,size,sha256,expires_at)
          VALUES($1,$2,$3,$4,$5,$6,$7)`, [id, owner, transfer.room, transfer.shared, body.size, body.sha256 ?? null, transfer.expires_at]);
        await client.query('COMMIT');
        return reply(201, { id, uploadPath: `/files/v1/transfers/${id}`, expiresAt: transfer.expires_at.toISOString() });
      } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
      finally { client.release(); }
    }
    const id = path.slice('/files/v1/transfers/'.length);
    if (!uuid.test(id) || path !== `/files/v1/transfers/${id}`) return reply(404, { error: 'not_found' });
    const transfer = (await pool.query('SELECT * FROM bound_files_private.transfers WHERE id=$1', [id])).rows[0];
    if (!await authorized(identity, transfer)) return reply(404, { error: 'not_found' });
    const file = join(directory, id);
    if (request.method === 'DELETE') {
      if (owner !== transfer.owner) return reply(403, { error: 'forbidden' });
      const pending = [...uploads.values()].filter(upload => upload.id === id);
      for (const upload of pending) upload.controller.abort();
      await Promise.all(pending.map(upload => upload.finished));
      await removeFile(id); await removeFile(id + '.part');
      await pool.query('DELETE FROM bound_files_private.transfers WHERE id=$1 AND owner=$2', [id, owner]);
      return reply(200, { ok: true });
    }
    if (request.method === 'GET') {
      if (transfer.state !== 'ready') return reply(409, { error: 'not_ready' });
      const details = await stat(file).catch(() => null);
      if (!details || details.size !== Number(transfer.size)) return reply(404, { error: 'not_found' });
      return new Response(Readable.toWeb(createReadStream(file)), { headers: {
        'content-type': 'application/octet-stream', 'content-length': String(transfer.size),
        'cache-control': 'no-store', 'content-disposition': 'attachment', 'x-content-type-options': 'nosniff',
        'x-content-sha256': transfer.sha256,
      } });
    }
    if (request.method !== 'PUT') return reply(405, { error: 'method_not_allowed' });
    if (owner !== transfer.owner) return reply(403, { error: 'forbidden' });
    if (!request.body || request.headers.get('content-type') !== 'application/octet-stream' ||
      (request.headers.has('content-length') && Number(request.headers.get('content-length')) !== Number(transfer.size))) return reply(400, { error: 'invalid_request' });
    let complete;
    const controller = new AbortController();
    const finished = new Promise(resolve => { complete = resolve; });
    const operation = { id, owner, controller, finished };
    // Register before claiming the row, so account deletion can drain writers.
    uploads.set(operation, operation);
    let size = 0; const hash = createHash('sha256'); let finalized = false;
    try {
      const claimed = await pool.query("UPDATE bound_files_private.transfers SET state='uploading' WHERE id=$1 AND state='reserved' RETURNING id", [id]);
      if (!claimed.rows.length) { finalized = true; return reply(409, { error: 'transfer_conflict' }); }
      identity = await authenticate(request);
      if (await rpc(identity, 'cup117_account_active', {}) !== true || controller.signal.aborted) throw Error('forbidden');
      const bounded = new Transform({ transform(chunk, _encoding, done) {
        size += chunk.length;
        if (size > Number(transfer.size) || size > maxFile) return done(Error('size_mismatch'));
        hash.update(chunk); done(null, chunk);
      } });
      await pipeline(Readable.fromWeb(request.body), bounded, createWriteStream(file + '.part', { flags: 'wx', mode: 0o600 }), { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(120000)]) });
      const digest = hash.digest('hex');
      if (size !== Number(transfer.size) || (transfer.sha256 && transfer.sha256 !== digest)) throw Error('size_mismatch');
      identity = await authenticate(request);
      if (ownerOf(identity) !== owner || !await authorized(identity, transfer)) throw Error('forbidden');
      await rename(file + '.part', file);
      const published = await pool.query("UPDATE bound_files_private.transfers SET state='ready',sha256=$2 WHERE id=$1 AND state='uploading' AND expires_at>now() RETURNING id", [id, digest]);
      if (!published.rows.length) throw Error('expired');
      finalized = true;
      return reply(200, { id, size, sha256: digest, expiresAt: new Date(transfer.expires_at).toISOString() });
    } catch { return reply(400, { error: 'transfer_failed' }); }
    finally {
      try {
        if (!finalized) {
          await removeFile(id); await removeFile(id + '.part');
          await pool.query('DELETE FROM bound_files_private.transfers WHERE id=$1', [id]);
        }
      } finally { uploads.delete(operation); complete(); }
    }
  }
  return { handle, cleanup, purgeOwner };
}
