import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { open, realpath } from 'node:fs/promises';
import { resolve, dirname, basename, join } from 'node:path';
import { Readable } from 'node:stream';
import { reply, uuid } from './services.mjs';

const failure = (status, message) => Object.assign(Error(message), { status });
const validUUID = value => typeof value === 'string' && uuid.test(value) && value === value.toLowerCase();
const safeOpen = path => open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
const bytes = 32 * 1024 * 1024;

export function validateROMManifest(value) {
  if (!value || value.schemaVersion !== 1 || !Number.isSafeInteger(value.buildNumber) || value.buildNumber < 500 ||
      value.byteCount !== bytes || typeof value.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(value.sha256) ||
      typeof value.gameID !== 'string' || !/^[a-f0-9]{40}$/.test(value.gameID) ||
      typeof value.gameCommit !== 'string' || !/^[a-f0-9]{40}$/.test(value.gameCommit) ||
      typeof value.boundABIHeaderSHA256 !== 'string' || !/^[a-f0-9]{64}$/.test(value.boundABIHeaderSHA256) ||
      !value.contract || typeof value.contract !== 'object' || Array.isArray(value.contract)) throw failure(503, 'rom_unavailable');
  // Return only the wire contract. Local publication paths never leave Linode.
  return Object.fromEntries(['schemaVersion', 'buildNumber', 'sha256', 'gameID', 'byteCount',
    'gameCommit', 'boundABIHeaderSHA256', 'contract'].map(key => [key, value[key]]));
}

export function createROMUpdates({ pool, authenticate, config = process.env }) {
  const root = config.ROM_UPDATES_ROOT ? resolve(config.ROM_UPDATES_ROOT) : null;
  let readers = 0;
  async function access(identity) {
    const owner = identity?.ownerID ?? identity?.id;
    const session = identity?.sessionID ?? identity?.session_id;
    if (!validUUID(owner) || !validUUID(session)) throw failure(401, 'unauthorized');
    const result = await pool.query(`SELECT coalesce(a.approved,false) AS approved
      FROM auth.users u JOIN auth.sessions s ON s.user_id=u.id
      LEFT JOIN bound_developer_private.approvals a ON a.owner=u.id
      WHERE u.id=$1 AND s.id=$2 AND s.not_after>now() AND u.deleted_at IS NULL
        AND NOT EXISTS(SELECT 1 FROM cup117_private.deletions WHERE owner=u.id)`, [owner, session]);
    if (result.rows.length !== 1) throw failure(403, 'forbidden');
    return result.rows[0].approved === true;
  }
  async function publication() {
    if (!root) throw failure(503, 'rom_unavailable');
    const directory = await realpath(join(root, 'current'));
    const generations = await realpath(join(root, 'generations'));
    if (generations !== join(await realpath(root), 'generations') || dirname(directory) !== generations ||
        !/^[0-9]+-[a-f0-9]{12,64}$/.test(basename(directory))) throw failure(503, 'rom_unavailable');
    let manifestFile, rom;
    try {
      manifestFile = await safeOpen(join(directory, 'manifest.json'));
      if (!(await manifestFile.stat()).isFile() || (await manifestFile.stat()).size > 1024 * 1024) throw failure(503, 'rom_unavailable');
      const manifest = validateROMManifest(JSON.parse(await manifestFile.readFile('utf8')));
      await manifestFile.close(); manifestFile = null;
      if (basename(directory) !== `${manifest.buildNumber}-${manifest.sha256.slice(0, basename(directory).split('-')[1].length)}`) throw failure(503, 'rom_unavailable');
      rom = await safeOpen(join(directory, 'RRv4.1M.gba'));
      const initial = await rom.stat();
      if (!initial.isFile() || initial.size !== bytes) throw failure(503, 'rom_unavailable');
      const sha256 = createHash('sha256'), sha1 = createHash('sha1');
      for await (const chunk of rom.createReadStream({ autoClose: false, start: 0 })) { sha256.update(chunk); sha1.update(chunk); }
      const final = await rom.stat();
      if (sha256.digest('hex') !== manifest.sha256 || sha1.digest('hex') !== manifest.gameID ||
          initial.mtimeMs !== final.mtimeMs || initial.size !== final.size) throw failure(503, 'rom_unavailable');
      // Keep this inode open through the response. Atomic publication can remove
      // an old generation without mixing metadata with another ROM's bytes.
      return { manifest, rom };
    } catch (error) { await rom?.close(); throw error; }
    finally { await manifestFile?.close(); }
  }
  async function handle(request) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/rom-updates/')) return null;
    if (!['/rom-updates/access', '/rom-updates/latest', '/rom-updates/download'].includes(url.pathname)) return reply(404, { error: 'not_found' });
    if (request.method !== 'GET') return reply(405, { error: 'method_not_allowed' });
    let identity, value, counted = false;
    try {
      try { identity = await authenticate(request); } catch { throw failure(401, 'unauthorized'); }
      const approved = await access(identity);
      if (url.pathname === '/rom-updates/access') return reply(200, { developerApproved: approved });
      if (!approved) throw failure(403, 'developer_approval_required');
      if (readers >= 2) throw failure(429, 'rom_busy');
      readers++; counted = true;
      value = await publication();
      if (url.pathname === '/rom-updates/download' &&
          (url.searchParams.get('build') !== String(value.manifest.buildNumber) || url.searchParams.get('sha256') !== value.manifest.sha256)) throw failure(409, 'rom_changed');
      // Reauthenticate and recheck after IO so logout/revocation while hashing
      // cannot admit a new response with previously cached authorization.
      let fresh;
      try { fresh = await authenticate(request); } catch { throw failure(401, 'unauthorized'); }
      if ((fresh?.ownerID ?? fresh?.id) !== (identity?.ownerID ?? identity?.id) || !await access(fresh)) throw failure(403, 'developer_approval_required');
      if (url.pathname === '/rom-updates/latest') return reply(200, value.manifest);
      const stream = value.rom.createReadStream({ autoClose: true, start: 0 });
      stream.once('close', () => { readers--; });
      const response = new Response(Readable.toWeb(stream), { headers: {
        'content-type': 'application/octet-stream', 'content-length': String(bytes),
        'content-disposition': 'attachment; filename="RRv4.1M.gba"',
        'cache-control': 'private, no-store', 'x-content-sha256': value.manifest.sha256,
        'x-rom-build-number': String(value.manifest.buildNumber), 'x-content-type-options': 'nosniff',
      } });
      value = null; counted = false;
      return response;
    } catch (error) { return reply(error.status ?? 503, { error: error.status ? error.message : 'rom_unavailable' }); }
    finally { await value?.rom.close(); if (counted) readers--; }
  }
  return { handle };
}
