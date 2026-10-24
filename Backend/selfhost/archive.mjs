import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { mkdir, open, unlink } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { Readable } from 'node:stream';
import { reply, uuid } from './services.mjs';

export const archiveBuckets = Object.freeze(['bound-roms', 'cup040-saves', 'cup071-covers']);
const canonicalUUID = value => typeof value === 'string' && uuid.test(value) && value === value.toLowerCase();
const nullable = value => value ?? null;

// Shared with the offline importer. Keep sourceRowText unchanged when inserting
// it into PostgreSQL: JS reserialization would round historical bigint values.
export function validateArchiveEntry(entry) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry) ||
    !canonicalUUID(entry.id) || !canonicalUUID(entry.owner) || !canonicalUUID(entry.sourceId) ||
    !/^[a-z0-9][a-z0-9_-]{0,127}$/.test(entry.projectRef ?? '') || !archiveBuckets.includes(entry.bucket) ||
    typeof entry.name !== 'string' || entry.name.includes('\0') || !entry.name.startsWith(entry.owner + '/') || entry.name.length <= 37 ||
    !Number.isSafeInteger(entry.size) || entry.size < 0 || !/^[a-f0-9]{64}$/.test(entry.sha256 ?? '') ||
    (entry.sourceVersion != null && typeof entry.sourceVersion !== 'string') ||
    (entry.sourceUpdatedAt != null && (typeof entry.sourceUpdatedAt !== 'string' || !Number.isFinite(Date.parse(entry.sourceUpdatedAt)))) ||
    typeof entry.sourceRowText !== 'string') throw Error('invalid_archive_entry');
  let original;
  try { original = JSON.parse(entry.sourceRowText); } catch { throw Error('invalid_archive_source_row'); }
  if (!original || typeof original !== 'object' || Array.isArray(original) ||
    original.id !== entry.sourceId || original.bucket_id !== entry.bucket || original.name !== entry.name ||
    [original.owner, original.owner_id].some(owner => owner != null && owner !== '' && owner !== entry.owner) ||
    nullable(original.version) !== nullable(entry.sourceVersion) ||
    (original.updated_at == null) !== (entry.sourceUpdatedAt == null) ||
    (original.updated_at != null && Date.parse(original.updated_at) !== Date.parse(entry.sourceUpdatedAt)) ||
    (original.metadata?.size != null && Number(original.metadata.size) !== entry.size)) throw Error('archive_source_mismatch');
  return entry;
}

export function archiveDirectory(config = process.env) {
  return join(resolve(config.FILE_DIRECTORY ?? '/var/lib/bound/files'), 'archive');
}

// The import command is the only writer. Public operations only list/download
// owned ready objects, authenticated by Nakama, and never accept a disk path.
export function createArchive({ pool, authenticate, rpc, config = process.env }) {
  const directory = archiveDirectory(config);
  const initialized = mkdir(directory, { recursive: true, mode: 0o700 });
  const reads = new Set();
  async function purgeOwner(owner) {
    if (!canonicalUUID(owner)) throw Error('invalid_owner');
    await initialized;
    const pending = [...reads].filter(read => read.owner === owner);
    for (const read of pending) read.controller.abort();
    await Promise.all(pending.map(read => read.finished));
    const result = await pool.query('SELECT id FROM bound_archive_private.objects WHERE owner=$1', [owner]);
    for (const row of result.rows) {
      if (!canonicalUUID(row.id)) throw Error('invalid_archive_id');
      for (const name of [row.id, row.id + '.part']) {
        try { await unlink(join(directory, name)); }
        catch (error) { if (error.code !== 'ENOENT') throw error; }
      }
    }
    await pool.query('DELETE FROM bound_archive_private.objects WHERE owner=$1', [owner]);
  }

  async function handle(request) {
    const url = new URL(request.url), path = url.pathname;
    if (path !== '/files/v1/archive' && !path.startsWith('/files/v1/archive/')) return null;
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    if (request.method !== 'GET') return reply(405, { error: 'method_not_allowed' });
    let identity;
    try { identity = await authenticate(request); }
    catch { return reply(401, { error: 'unauthorized' }); }
    const owner = identity?.ownerID ?? identity?.id;
    if (!canonicalUUID(owner)) return reply(401, { error: 'unauthorized' });
    try { if (await rpc(identity, 'cup117_account_active', {}) !== true) throw Error(); }
    catch { return reply(403, { error: 'forbidden' }); }
    if (path === '/files/v1/archive') {
      const cursor = url.searchParams.get('after');
      if ([...url.searchParams.keys()].some(key => key !== 'after') || url.searchParams.getAll('after').length > 1 ||
        (cursor !== null && !canonicalUUID(cursor))) return reply(400, { error: 'invalid_request' });
      const result = await pool.query(`SELECT id,bucket,name,size::text,sha256,imported_at FROM bound_archive_private.objects
        WHERE owner=$1 AND state='ready' AND ($2::uuid IS NULL OR id>$2::uuid) ORDER BY id LIMIT 101`, [owner, cursor]);
      const rows = result.rows.slice(0, 100);
      return reply(200, { objects: rows.map(row => ({ id: row.id, bucket: row.bucket, name: row.name,
        size: Number(row.size), sha256: row.sha256, importedAt: row.imported_at })),
      next: result.rows.length > 100 ? rows.at(-1).id : null });
    }
    const id = path.slice('/files/v1/archive/'.length);
    if (!canonicalUUID(id) || url.search) return reply(404, { error: 'not_found' });
    const result = await pool.query(`SELECT id,size::text,sha256 FROM bound_archive_private.objects
      WHERE id=$1 AND owner=$2 AND state='ready'`, [id, owner]);
    const object = result.rows[0];
    if (!object) return reply(404, { error: 'not_found' });
    await initialized;
    const controller = new AbortController();
    let finish, file, streamed = false;
    const finished = new Promise(resolve => { finish = resolve; });
    const operation = { owner, controller, finished };
    reads.add(operation);
    const done = () => { reads.delete(operation); finish(); };
    try {
      file = await open(join(directory, id), constants.O_RDONLY | constants.O_NOFOLLOW);
      const details = await file.stat();
      if (!details.isFile() || details.size !== Number(object.size)) throw Error('archive_unavailable');
      // Recheck after the open while registered with deletion's drain hook.
      identity = await authenticate(request);
      if ((identity.ownerID ?? identity.id) !== owner || await rpc(identity, 'cup117_account_active', {}) !== true) throw Error('forbidden');
      const hash = createHash('sha256'), buffer = Buffer.alloc(65536);
      let position = 0;
      while (true) {
        controller.signal.throwIfAborted();
        const { bytesRead } = await file.read(buffer, 0, buffer.length, position);
        if (!bytesRead) break;
        position += bytesRead;
        if (position > Number(object.size)) throw Error('archive_corrupt');
        hash.update(buffer.subarray(0, bytesRead));
      }
      if (position !== Number(object.size) || hash.digest('hex') !== object.sha256) throw Error('archive_corrupt');
      controller.signal.throwIfAborted();
      const stream = file.createReadStream({ start: 0, autoClose: true, signal: controller.signal });
      stream.once('close', done);
      streamed = true;
      return new Response(Readable.toWeb(stream), { headers: {
        'content-type': 'application/octet-stream', 'content-length': String(object.size),
        'content-disposition': 'attachment', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff',
        'x-content-sha256': object.sha256,
      } });
    } catch { return reply(404, { error: 'not_found' }); }
    finally { if (!streamed) { try { await file?.close(); } finally { done(); } } }
  }
  return { handle, purgeOwner };
}
