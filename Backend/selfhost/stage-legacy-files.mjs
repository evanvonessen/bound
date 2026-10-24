// Operator-only, read-only source export. Credentials stay outside deployment config.
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, open, rename, unlink } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import pg from 'pg';
import { validateArchiveEntry } from './archive.mjs';

const projectRef = process.env.SOURCE_PROJECT_REF;
const manifestPath = resolve(process.env.LEGACY_ARCHIVE_MANIFEST ?? '');
if (!/^[a-z0-9]{20}$/.test(projectRef ?? '') || !process.env.SOURCE_DATABASE_URL ||
    !process.env.SOURCE_STORAGE_KEY_FILE || !process.env.LEGACY_ARCHIVE_MANIFEST) {
  throw Error('missing_source_export_configuration');
}
const sourceURL = new URL(process.env.SOURCE_DATABASE_URL);
for (const key of ['ssl', 'sslmode', 'sslcert', 'sslkey', 'sslrootcert', 'options']) sourceURL.searchParams.delete(key);
const source = new pg.Client({ connectionString: sourceURL.toString(), ssl: { rejectUnauthorized: true },
  connectionTimeoutMillis: 15000, application_name: 'bound-storage-readonly' });
const sourceKey = (await readFile(process.env.SOURCE_STORAGE_KEY_FILE, 'utf8')).trim();
const directory = dirname(manifestPath), objectDirectory = join(directory, 'objects');
const inventory = async () => (await source.query('SELECT to_jsonb(o)::text AS original FROM storage.objects o ORDER BY id')).rows.map(row => row.original);
try {
  await source.connect();
  await source.query('SET default_transaction_read_only=on');
  await mkdir(objectDirectory, { recursive: true, mode: 0o700 });
  const before = await inventory(), objects = [];
  for (const sourceRowText of before) {
    const original = JSON.parse(sourceRowText), size = Number(original.metadata?.size);
    const owner = original.name?.split('/')[0];
    const entry = { id: randomUUID(), owner, projectRef, bucket: original.bucket_id, name: original.name,
      sourceId: original.id, sourceVersion: original.version ?? null, sourceUpdatedAt: original.updated_at ?? null,
      sourceRowText, size, sha256: '0'.repeat(64) };
    validateArchiveEntry(entry);
    if (size > 128 * 1024 * 1024) throw Error('source_object_exceeds_export_limit');
    const url = `https://${projectRef}.supabase.co/storage/v1/object/${encodeURIComponent(entry.bucket)}/${entry.name.split('/').map(encodeURIComponent).join('/')}`;
    const response = await fetch(url, { headers: { apikey: sourceKey }, redirect: 'error', signal: AbortSignal.timeout(120000) });
    if (!response.ok || !response.body) throw Error(`source_download_http_${response.status}`);
    const temporary = join(objectDirectory, entry.id + '.part');
    const file = await open(temporary, 'wx', 0o600), sha256 = createHash('sha256'), md5 = createHash('md5');
    let received = 0;
    try {
      for await (const chunk of response.body) {
        received += chunk.byteLength;
        if (received > size) throw Error('source_download_size_changed');
        sha256.update(chunk); md5.update(chunk); await file.writeFile(chunk);
      }
      if (received !== size) throw Error('source_download_incomplete');
      const etag = String(original.metadata?.eTag ?? '').replaceAll('"', '');
      const actualMD5 = md5.digest('hex');
      if (/^[a-f0-9]{32}$/i.test(etag) && etag.toLowerCase() !== actualMD5) throw Error('source_download_checksum_changed');
      entry.sha256 = sha256.digest('hex');
      await file.sync();
    } catch (error) { await file.close(); await unlink(temporary); throw error; }
    await file.close();
    await rename(temporary, join(objectDirectory, entry.id));
    validateArchiveEntry(entry); objects.push(entry);
  }
  if (JSON.stringify(before) !== JSON.stringify(await inventory())) throw Error('source_inventory_changed_repeat_export');
  await writeFile(manifestPath + '.part', JSON.stringify({ version: 1, projectRef, objects }), { mode: 0o600, flag: 'wx' });
  await rename(manifestPath + '.part', manifestPath);
  console.log(JSON.stringify({ stagedObjects: objects.length, stagedBytes: objects.reduce((sum, object) => sum + object.size, 0) }));
} catch (error) {
  const code = error?.message ?? '';
  console.error(JSON.stringify({ error: /^(source_|invalid_archive|archive_source)/.test(code) ? code : 'source_export_failed' }));
  process.exitCode = 1;
} finally { await source.end(); }
