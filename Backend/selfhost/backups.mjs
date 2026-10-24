import { createHash, randomUUID } from 'node:crypto';
import { constants, createWriteStream } from 'node:fs';
import { mkdir, open, rename, readdir, unlink, rmdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { readJSON, reply, uuid } from './services.mjs';

const validOwner = value => typeof value === 'string' && uuid.test(value) && value === value.toLowerCase();
const validGame = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value);
const number = (value, fallback) => {
  const parsed = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) throw Error('Invalid backup limit');
  return parsed;
};
const failure = (status, code) => Object.assign(Error(code), { status });
const ownerOf = identity => identity?.ownerID ?? identity?.id;
const sessionOf = identity => identity?.sessionID ?? identity?.session_id;
export const backupLockSQL = 'SELECT pg_advisory_lock(hashtextextended($1,196189))';
export const backupUnlockSQL = 'SELECT pg_advisory_unlock(hashtextextended($1,196189))';
export const backupDirectory = (config = process.env) => resolve(config.BACKUP_DIRECTORY ?? join(config.FILE_DIRECTORY ?? '/var/lib/bound/files', 'backups'));
const metadata = row => ({ gameID: row.game_id, name: row.name, version: row.version,
  sha256: row.sha256, size: Number(row.size), modifiedAt: new Date(row.modified_at).toISOString() });

export function createBackups({ pool, authenticate, rpc, config = process.env }) {
  const directory = backupDirectory(config);
  const maxFile = number(config.BACKUP_MAX_BYTES, 64 * 1024 * 1024);
  const maxOwner = number(config.BACKUP_OWNER_BYTES, 256 * 1024 * 1024);
  const maxTotal = number(config.BACKUP_TOTAL_BYTES, 2 * 1024 * 1024 * 1024);
  const maxVersions = number(config.BACKUP_VERSIONS, 3);
  const initialized = mkdir(directory, { recursive: true, mode: 0o700 });
  const operations = new Set();
  const pathFor = (owner, version) => {
    if (!validOwner(owner) || !validOwner(version)) throw Error('invalid_backup_path');
    return join(directory, owner, version);
  };
  const remove = async path => { try { await unlink(path); } catch (error) { if (error.code !== 'ENOENT') throw error; } };

  async function assertActive(client, identity) {
    const owner = ownerOf(identity), session = sessionOf(identity);
    if (!validOwner(owner) || !validOwner(session)) throw failure(401, 'unauthorized');
    const result = await client.query(`SELECT u.id FROM auth.users u JOIN auth.sessions s ON s.user_id=u.id
      WHERE u.id=$1 AND s.id=$2 AND u.deleted_at IS NULL AND u.email_confirmed_at IS NOT NULL
        AND s.not_after>now() AND NOT EXISTS(SELECT 1 FROM cup117_private.deletions WHERE owner=u.id)`, [owner, session]);
    if (!result.rows.length) throw failure(403, 'forbidden');
  }
  async function status(client, owner) {
    // A pending grant may be claimed only through an actually confirmed email.
    await client.query(`UPDATE bound_backups_private.approvals a SET owner=u.id
      FROM auth.users u WHERE u.id=$1 AND lower(u.email)=a.email AND u.email_confirmed_at IS NOT NULL
        AND u.deleted_at IS NULL AND a.owner IS NULL AND a.approved
        AND NOT EXISTS(SELECT 1 FROM bound_backups_private.approvals existing WHERE existing.owner=u.id)`, [owner]);
    await client.query('INSERT INTO bound_backups_private.preferences(owner) VALUES($1) ON CONFLICT DO NOTHING', [owner]);
    const result = await client.query(`SELECT p.provider,p.revision::text,a.approved,a.revision::text AS approval_revision
      FROM bound_backups_private.preferences p LEFT JOIN bound_backups_private.approvals a ON a.owner=p.owner
      WHERE p.owner=$1`, [owner]);
    const row = result.rows[0];
    if (!row) throw failure(403, 'forbidden');
    return { approved: row.approved === true, provider: row.provider, revision: `${row.revision}.${row.approval_revision ?? 'none'}` };
  }
  async function authorize(client, identity, provider) {
    await assertActive(client, identity);
    const value = await status(client, ownerOf(identity));
    if (provider && (value.provider !== provider || (provider === 'server' && !value.approved))) throw failure(403, 'backup_not_enabled');
    return value;
  }
  async function recheck(request, owner) {
    let identity;
    try { identity = await authenticate(request); }
    catch { throw failure(401, 'unauthorized'); }
    if (ownerOf(identity) !== owner) throw failure(403, 'forbidden');
    return identity;
  }
  async function begin(identity) {
    const owner = ownerOf(identity);
    if (!validOwner(owner)) throw failure(401, 'unauthorized');
    if (operations.size >= 4) throw failure(429, 'backup_busy');
    const controller = new AbortController();
    let finish;
    const finished = new Promise(resolve => { finish = resolve; });
    const operation = { owner, controller, finished };
    operations.add(operation);
    let client, locked = false, ended = false;
    const end = async () => {
      if (ended) return; ended = true;
      try { if (locked) await client.query(backupUnlockSQL, [owner]); }
      finally { client?.release(); operations.delete(operation); finish(); }
    };
    try {
      client = await pool.connect();
      await client.query(backupLockSQL, [owner]); locked = true;
      controller.signal.throwIfAborted();
      await authorize(client, identity);
      return { owner, client, controller, end };
    } catch (error) { await end(); throw error; }
  }
  async function withDropbox(identity, action, work) {
    if (action === 'unlink') return work();
    const operation = await begin(identity);
    try {
      await authorize(operation.client, identity, 'dropbox');
      const response = await work();
      await authorize(operation.client, identity, 'dropbox');
      return response;
    } catch (error) { return reply(error.status ?? 503, { error: error.status ? error.message : 'unavailable' }); }
    finally { await operation.end(); }
  }
  async function removeRows(client, rows) {
    for (const row of rows) {
      await remove(pathFor(row.owner, row.version));
      await remove(pathFor(row.owner, row.version) + '.part');
      await client.query('DELETE FROM bound_backups_private.objects WHERE version=$1', [row.version]);
    }
  }
  async function latest(client, owner, game) {
    return (await client.query(`SELECT * FROM bound_backups_private.objects
      WHERE owner=$1 AND game_id=$2 AND state='ready' ORDER BY modified_at DESC,version DESC LIMIT 1`, [owner, game])).rows[0];
  }
  async function drainOwner(owner) {
    if (!validOwner(owner)) throw Error('invalid_owner');
    const pending = [...operations].filter(operation => operation.owner === owner);
    for (const operation of pending) operation.controller.abort();
    await Promise.all(pending.map(operation => operation.finished));
  }
  async function prepareDeletion(owner) {
    await drainOwner(owner);
    const client = await pool.connect();
    try {
      await client.query(backupLockSQL, [owner]);
      // Run while the verified identity still exists. A user who never opened
      // backup settings may have an unclaimed pending grant for this mailbox.
      await client.query(`DELETE FROM bound_backups_private.approvals WHERE owner=$1 OR
        (owner IS NULL AND email IN(SELECT lower(email) FROM auth.users WHERE id=$1 AND email_confirmed_at IS NOT NULL))`, [owner]);
    } finally { await client.query(backupUnlockSQL, [owner]).catch(() => {}); client.release(); }
  }
  async function purgeOwner(owner) {
    await drainOwner(owner);
    const client = await pool.connect();
    try {
      await client.query(backupLockSQL, [owner]);
      await initialized;
      const rows = await client.query('SELECT * FROM bound_backups_private.objects WHERE owner=$1', [owner]);
      await removeRows(client, rows.rows);
      // All paths in an owner directory are server-generated UUIDs. Remove any
      // crash-orphaned file too, retaining unknown paths for operator inspection.
      for (const name of await readdir(join(directory, owner)).catch(error => { if (error.code === 'ENOENT') return []; throw error; })) {
        if (/^[0-9a-f-]{36}(\.part)?$/.test(name) && validOwner(name.replace(/\.part$/, ''))) await remove(join(directory, owner, name));
      }
      await rmdir(join(directory, owner)).catch(error => { if (!['ENOENT', 'ENOTEMPTY'].includes(error.code)) throw error; });
      await client.query('DELETE FROM bound_backups_private.approvals WHERE owner=$1', [owner]);
      await client.query('DELETE FROM bound_backups_private.preferences WHERE owner=$1', [owner]);
    } finally { await client.query(backupUnlockSQL, [owner]).catch(() => {}); client.release(); }
  }
  async function cleanup() {
    await initialized;
    // Native Nakama console/operator deletion bypasses the gateway route. Keep
    // durable receipts until this sweep can drain I/O and erase their bytes.
    const removedOwners = await pool.query(`SELECT DISTINCT o.owner FROM bound_backups_private.objects o
      WHERE NOT EXISTS(SELECT 1 FROM public.users u WHERE u.id=o.owner)`);
    for (const { owner } of removedOwners.rows) if (validOwner(owner)) await purgeOwner(owner);
    // Old incomplete uploads are recoverable receipts after a restart. Live
    // uploads keep their owner lock, so cleanup cannot race a current writer.
    const stale = await pool.query("SELECT DISTINCT owner FROM bound_backups_private.objects WHERE state='uploading' AND modified_at<now()-interval '10 minutes'");
    for (const { owner } of stale.rows) {
      if (!validOwner(owner)) continue;
      const client = await pool.connect();
      try {
        const lock = await client.query('SELECT pg_try_advisory_lock(hashtextextended($1,196189)) AS locked', [owner]);
        if (!lock.rows[0]?.locked) continue;
        const rows = await client.query("SELECT * FROM bound_backups_private.objects WHERE owner=$1 AND state='uploading' AND modified_at<now()-interval '10 minutes'", [owner]);
        await removeRows(client, rows.rows);
      } finally { await client.query(backupUnlockSQL, [owner]).catch(() => {}); client.release(); }
    }
  }
  async function upload(request, identity, operation, game) {
    const { client, owner, controller } = operation;
    if (request.headers.get('content-type')?.split(';')[0].trim() !== 'application/zip' || !request.body) throw failure(400, 'invalid_request');
    const sha = request.headers.get('x-content-sha256');
    const match = request.headers.get('if-match')?.replace(/^"(.*)"$/, '$1');
    if (!/^[0-9a-f]{64}$/.test(sha ?? '') || !match || (match !== '*' && !validOwner(match))) throw failure(400, 'invalid_request');
    let name;
    try { name = decodeURIComponent(request.headers.get('x-backup-name') ?? game); } catch { throw failure(400, 'invalid_request'); }
    if (!name || name.length > 256 || /[\x00-\x1f\x7f]/.test(name)) throw failure(400, 'invalid_request');
    const length = request.headers.get('content-length');
    const reservation = length === null ? maxFile : Number(length);
    if (!Number.isSafeInteger(reservation) || reservation < 1) throw failure(400, 'invalid_request');
    if (reservation > maxFile) throw failure(413, 'backup_too_large');
    const current = await latest(client, owner, game);
    if ((current?.version ?? '*') !== match) throw failure(409, 'backup_conflict');
    const version = randomUUID(), path = pathFor(owner, version);
    let reserved = false, published = false;
    try {
      await client.query('BEGIN');
      await client.query('SELECT pg_advisory_xact_lock(1961892026)');
      const usage = (await client.query(`SELECT coalesce(sum(size),0)::text AS total,
        coalesce(sum(size) FILTER(WHERE owner=$1),0)::text AS owned FROM bound_backups_private.objects`, [owner])).rows[0];
      if (Number(usage.total) + reservation > maxTotal || Number(usage.owned) + reservation > maxOwner) throw failure(413, 'backup_quota_exceeded');
      await client.query(`INSERT INTO bound_backups_private.objects(version,owner,game_id,name,size,sha256,state)
        VALUES($1,$2,$3,$4,$5,$6,'uploading')`, [version, owner, game, name, reservation, sha]);
      await client.query('COMMIT'); reserved = true;
      await initialized;
      await mkdir(join(directory, owner), { recursive: true, mode: 0o700 });
      let size = 0, prefix = Buffer.alloc(0); const hash = createHash('sha256');
      const bounded = new Transform({ transform(chunk, _encoding, callback) {
        size += chunk.length;
        if (size > reservation || size > maxFile) return callback(failure(413, 'backup_too_large'));
        if (prefix.length < 4) prefix = Buffer.concat([prefix, chunk]).subarray(0, 4);
        hash.update(chunk); callback(null, chunk);
      } });
      await pipeline(Readable.fromWeb(request.body), bounded, createWriteStream(path + '.part', { flags: 'wx', mode: 0o600 }),
        { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(120000)]) });
      if ((length !== null && size !== reservation) || size < 4 || !['504b0304', '504b0506'].includes(prefix.toString('hex')) || hash.digest('hex') !== sha) throw failure(400, 'invalid_backup');
      const file = await open(path + '.part', constants.O_RDONLY | constants.O_NOFOLLOW);
      try { await file.sync(); } finally { await file.close(); }
      // Recheck the exact bearer and owner after receiving untrusted bytes.
      const fresh = await recheck(request, owner);
      await authorize(client, fresh, 'server'); controller.signal.throwIfAborted();
      await rename(path + '.part', path);
      const ownerDirectory = await open(join(directory, owner), constants.O_RDONLY);
      try { await ownerDirectory.sync(); } finally { await ownerDirectory.close(); }
      // Provider/approval updates share this owner lock. Deletion independently
      // marks the account inactive, so recheck immediately before publication.
      await client.query('BEGIN');
      await client.query('SELECT pg_advisory_xact_lock_shared(11720260925)');
      await client.query('SELECT owner FROM bound_backups_private.approvals WHERE owner=$1 FOR SHARE', [owner]);
      await authorize(client, fresh, 'server'); controller.signal.throwIfAborted();
      const result = await client.query(`UPDATE bound_backups_private.objects SET state='ready',size=$2,modified_at=clock_timestamp()
        WHERE version=$1 AND state='uploading' RETURNING *`, [version, size]);
      if (!result.rows.length) throw failure(409, 'backup_conflict');
      await client.query('COMMIT'); published = true;
      const obsolete = await client.query(`SELECT * FROM bound_backups_private.objects
        WHERE owner=$1 AND game_id=$2 AND state='ready' ORDER BY modified_at DESC,version DESC OFFSET $3`, [owner, game, maxVersions]);
      await removeRows(client, obsolete.rows);
      return reply(200, metadata(result.rows[0]));
    } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
    finally {
      if (!published) {
        await remove(path + '.part'); await remove(path);
        if (reserved) await client.query('DELETE FROM bound_backups_private.objects WHERE version=$1', [version]);
      }
    }
  }
  async function download(request, identity, operation, game) {
    const { client, owner, controller } = operation;
    const row = await latest(client, owner, game);
    if (!row) throw failure(404, 'not_found');
    let file, streamed = false;
    try {
      await initialized;
      file = await open(pathFor(owner, row.version), constants.O_RDONLY | constants.O_NOFOLLOW);
      const details = await file.stat();
      if (!details.isFile() || details.size !== Number(row.size)) throw failure(404, 'not_found');
      const hash = createHash('sha256'), buffer = Buffer.alloc(65536); let position = 0;
      while (true) {
        controller.signal.throwIfAborted();
        const { bytesRead } = await file.read(buffer, 0, buffer.length, position);
        if (!bytesRead) break;
        position += bytesRead; hash.update(buffer.subarray(0, bytesRead));
      }
      if (hash.digest('hex') !== row.sha256) throw failure(503, 'backup_unavailable');
      const fresh = await recheck(request, owner);
      await authorize(client, fresh, 'server'); controller.signal.throwIfAborted();
      const stream = file.createReadStream({ start: 0, autoClose: true, signal: AbortSignal.any([controller.signal, AbortSignal.timeout(120000)]) });
      stream.once('close', () => { void operation.end(); }); streamed = true;
      return new Response(Readable.toWeb(stream), { headers: {
        'content-type': 'application/zip', 'content-length': String(row.size), 'cache-control': 'no-store',
        'content-disposition': 'attachment', 'x-content-type-options': 'nosniff',
        'x-backup-version': row.version, 'x-content-sha256': row.sha256,
      } });
    } finally { if (!streamed) await file?.close(); }
  }
  async function handle(request) {
    const url = new URL(request.url), path = url.pathname;
    if (!path.startsWith('/backups/v1/')) return null;
    if (request.headers.has('origin')) return reply(403, { error: 'forbidden' });
    if (url.search) return reply(400, { error: 'invalid_request' });
    let identity;
    try { identity = await authenticate(request); if (await rpc(identity, 'cup117_account_active', {}) !== true) throw Error(); }
    catch { return reply(401, { error: 'unauthorized' }); }
    let operation, streaming = false;
    try {
      operation = await begin(identity);
      const { client, owner } = operation;
      if (path === '/backups/v1/status' && request.method === 'GET') return reply(200, await authorize(client, identity));
      if (path === '/backups/v1/provider' && request.method === 'PUT') {
        const input = await readJSON(request, 512);
        if (!input || Object.keys(input).sort().join(',') !== 'expectedRevision,provider' || !['none', 'dropbox', 'server'].includes(input.provider) || typeof input.expectedRevision !== 'string') throw failure(400, 'invalid_request');
        const current = await authorize(client, identity);
        if (current.revision !== input.expectedRevision) throw failure(409, 'provider_conflict');
        if (input.provider === 'server' && !current.approved) throw failure(403, 'backup_not_approved');
        await client.query('UPDATE bound_backups_private.preferences SET provider=$2,revision=gen_random_uuid() WHERE owner=$1', [owner, input.provider]);
        return reply(200, await status(client, owner));
      }
      if (path === '/backups/v1/saves' && request.method === 'GET') {
        await authorize(client, identity, 'server');
        const rows = await client.query(`SELECT DISTINCT ON(game_id) * FROM bound_backups_private.objects
          WHERE owner=$1 AND state='ready' ORDER BY game_id,modified_at DESC,version DESC`, [owner]);
        return reply(200, { saves: rows.rows.map(metadata) });
      }
      const game = path.slice('/backups/v1/saves/'.length);
      if (!path.startsWith('/backups/v1/saves/') || !validGame(game)) throw failure(404, 'not_found');
      if (request.method === 'DELETE') {
        // Owners can erase their backups after approval is revoked or after
        // switching providers; reading and writing still require approval.
        const rows = await client.query('SELECT * FROM bound_backups_private.objects WHERE owner=$1 AND game_id=$2', [owner, game]);
        await removeRows(client, rows.rows); return reply(200, { ok: true });
      }
      await authorize(client, identity, 'server');
      if (request.method === 'PUT') return await upload(request, identity, operation, game);
      if (request.method === 'GET') { const response = await download(request, identity, operation, game); streaming = true; return response; }
      throw failure(405, 'method_not_allowed');
    } catch (error) { return reply(error.status ?? (error.message === 'invalid_request' ? 400 : 503), { error: error.status || error.message === 'invalid_request' ? error.message : 'unavailable' }); }
    finally { if (!streaming) await operation?.end(); }
  }
  return { handle, withDropbox, prepareDeletion, purgeOwner, cleanup };
}
