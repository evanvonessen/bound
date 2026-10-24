import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createGrantCipher } from '../dropbox-link/handler.mjs';
import { ArchiveImportError, archiveTables, deletedRowOwners, deletionDestinationTables, insertLegacyRow,
  legacyRowOwners, legacyRowPlan, legacyRowSelection, prepareArchiveImport } from './import-archive.mjs';

// Deliberately separate from startup/migrate.mjs. The source never receives DDL,
// writes, functions belonging to the application, or authentication requests.
const SYSTEM = '00000000-0000-0000-0000-000000000000';
export const tables = [
  'cup050_private.rooms', 'cup050_private.invites', 'cup050_private.limits',
  'bound_social_private.profiles', 'bound_social_private.username_changes',
  'bound_social_private.devices', 'bound_social_private.registration_fences', 'bound_social_private.jiggle_jobs',
  'bound_moderation_private.blocks', 'bound_moderation_private.reports', 'bound_moderation_private.suspensions',
  'bound_moderation_private.quotas', 'bound_moderation_private.review_audit',
  'bound_multiplayer_private.run_leases', 'bound_dropbox_private.links',
];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const quote = name => '"' + name.replaceAll('"', '""') + '"';
const relation = name => name.split('.').map(quote).join('.');
const tableListSQL = `SELECT n.nspname AS schema,c.relname AS name,c.relkind AS kind
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE c.relkind IN ('r','p','v') AND (n.nspname IN ('public','auth','storage',$1)
    OR n.nspname ~ '^(bound_|cup[0-9])')
    AND NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass
      AND d.objid=c.oid AND d.deptype='e') ORDER BY n.nspname,c.relname`;
const columnsSQL = `SELECT c.column_name AS name,c.udt_name AS type,c.udt_schema AS type_schema,
  pg_catalog.format_type(a.atttypid,a.atttypmod) AS sql_type,c.is_nullable AS nullable,
  c.column_default AS default,c.is_identity AS identity,c.is_generated AS generated
  FROM information_schema.columns c JOIN pg_namespace n ON n.nspname=c.table_schema
  JOIN pg_class t ON t.relnamespace=n.oid AND t.relname=c.table_name
  JOIN pg_attribute a ON a.attrelid=t.oid AND a.attname=c.column_name
  WHERE c.table_schema=$1 AND c.table_name=$2 ORDER BY c.ordinal_position`;
const fail = code => { throw new ImportError(code); };
export class ImportError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const rowCount = result => {
  const count = Number(result.rows[0]?.count);
  if (!Number.isSafeInteger(count) || count < 0) fail('invalid_count');
  return count;
};
const count = async (client, table, where = '') => rowCount(await client.query(`SELECT count(*)::text AS count FROM ${relation(table)}${where}`));
const catalog = async (client, authSchema = 'auth') => new Map((await client.query(tableListSQL, [authSchema])).rows.map(row => [row.schema + '.' + row.name, row.kind]));
const columns = async (client, table) => (await client.query(columnsSQL, table.split('.'))).rows;

export function compatibleColumns(source, destination) {
  const targets = new Map(destination.map(column => [column.name, column]));
  if (source.some(column => !targets.has(column.name) || targets.get(column.name).type !== column.type
      || targets.get(column.name).generated !== 'NEVER')) return false;
  const names = new Set(source.map(column => column.name));
  return destination.every(column => names.has(column.name) || column.nullable === 'YES'
    || column.default !== null || column.identity === 'YES' || column.generated !== 'NEVER');
}

// Nakama v3.41.0 AuthenticateEmail reads users.password BYTEA and calls Go's
// bcrypt.CompareHashAndPassword. Copy only recognized bcrypt strings unchanged.
export function projectUser(row, profileName) {
  if (!uuid.test(row.id || '') || row.id === SYSTEM || row.is_anonymous || row.is_sso_user || row.deleted_at
      || row.phone || (row.banned_until && new Date(row.banned_until).valueOf() > Date.now())) fail('unsupported_account');
  const hash = row.encrypted_password;
  if (typeof hash !== 'string' || !/^\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$/.test(hash)) fail('unsupported_password_hash');
  const email = typeof row.email === 'string' ? row.email.trim().toLowerCase() : '';
  if (Buffer.byteLength(email) < 10 || Buffer.byteLength(email) > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) fail('unsupported_email');
  const raw = row.raw_user_meta_data || {};
  const name = profileName ?? raw.bound_username_v1 ?? raw.cupcake_username_v1;
  if (name != null && (typeof name !== 'string' || name.length < 1 || name.length > 40)) fail('unsupported_profile_name');
  // Never promote user-editable source metadata into trusted Nakama account flags.
  const metadata = {};
  if (row.email_confirmed_at) metadata.bound_email_confirmed_at = row.email_confirmed_at;
  if (name != null) metadata.bound_username_v1 = name;
  if (typeof raw.cupcake_username_v1 === 'string') metadata.cupcake_username_v1 = raw.cupcake_username_v1;
  return {
    id: row.id, email, password: Buffer.from(hash, 'utf8'), username: row.id.replaceAll('-', ''),
    displayName: name ?? null, customID: 'bound-selfhost:' + row.id, metadata,
    createdAt: row.created_at, updatedAt: row.updated_at,
    // Retain original metadata privately, not in the publicly readable user object.
    legacy: { user_metadata: raw, app_metadata: row.raw_app_meta_data || {},
      email_confirmed_at: row.email_confirmed_at, last_sign_in_at: row.last_sign_in_at,
      banned_until: row.banned_until, imported_at: new Date().toISOString() },
  };
}

async function* rows(client, table, selected = '*') {
  // One server-side cursor keeps memory bounded and shares the repeatable-read snapshot.
  await client.query(`DECLARE bound_legacy_import NO SCROLL CURSOR FOR SELECT ${selected} FROM ${relation(table)}`);
  try {
    for (;;) {
      const batch = await client.query('FETCH FORWARD 100 FROM bound_legacy_import');
      if (!batch.rows.length) break;
      for (const row of batch.rows) yield row;
    }
  } finally { await client.query('CLOSE bound_legacy_import'); }
}

export async function importLegacy({ source, destination, apply = false, resetDropboxLinks = false, env = {} }) {
  const report = { mode: apply ? 'apply' : 'check', dropbox_links: resetDropboxLinks ? 'reset' : 'preserve',
    source: {}, destination: {}, blockers: [], imported: false };
  const block = (code, table, amount) => report.blockers.push({ code, ...(table ? { table } : {}), ...(amount !== undefined ? { count: amount } : {}) });
  const sourceAuthSchema = env.SOURCE_AUTH_SCHEMA ?? 'auth';
  if (!/^[a-z_][a-z0-9_]{0,62}$/.test(sourceAuthSchema) || ['public', 'storage'].includes(sourceAuthSchema)) fail('invalid_source_auth_schema');
  const exportedAuth = sourceAuthSchema !== 'auth', sourceUsers = sourceAuthSchema + '.users';
  let sourceOpen = false, destinationOpen = false, archive, commitStarted = false;
  try {
    await source.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'); sourceOpen = true;
    await source.query("SET LOCAL statement_timeout='60s'");
    await source.query("SET LOCAL row_security=off");
    await source.query("SET LOCAL DateStyle='ISO, YMD'");
    await source.query("SET LOCAL bytea_output='hex'");
    await source.query("SET LOCAL extra_float_digits=3");
    await source.query("SET LOCAL idle_in_transaction_session_timeout='10min'");
    const sourceSettings = await source.query('SHOW transaction_read_only');
    if (sourceSettings.rows[0]?.transaction_read_only !== 'on') fail('source_not_read_only');
    await destination.query(apply ? 'BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE' : 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'); destinationOpen = true;
    await destination.query("SET LOCAL lock_timeout='5s'");
    await destination.query("SET LOCAL statement_timeout='60s'");
    const src = await catalog(source, sourceAuthSchema), dst = await catalog(destination);
    if (!(exportedAuth ? src.get(sourceUsers) === 'v' : ['r', 'p'].includes(src.get(sourceUsers))) || dst.get('auth.users') !== 'v'
        || dst.get('public.users') !== 'r' || dst.get('public.storage') !== 'r') fail('expected_source_and_destination_schemas');
    if (exportedAuth && !['users', 'identities', 'mfa_factors'].every(name => src.get(sourceAuthSchema + '.' + name) === 'v')) fail('source_auth_export_incomplete');
    const nativeColumns = new Map((await columns(destination, 'public.users')).map(c => [c.name, c.type]));
    for (const [name, type] of [['id', 'uuid'], ['password', 'bytea'], ['metadata', 'jsonb'], ['custom_id', 'varchar']]) {
      if (nativeColumns.get(name) !== type) fail('unsupported_nakama_schema');
    }
    if (apply) {
      const locked = ['public.users', 'public.storage', ...[...tables, ...archiveTables, ...deletionDestinationTables].filter(table => dst.has(table))];
      await destination.query(`LOCK TABLE ${locked.map(relation).join(',')} IN ACCESS EXCLUSIVE MODE`);
    }
    report.destination.accounts = await count(destination, 'public.users', ` WHERE id<>'${SYSTEM}'`);
    report.destination.storage = await count(destination, 'public.storage');
    if (report.destination.accounts || report.destination.storage) block('destination_not_empty');
    for (const table of [...tables, ...archiveTables, ...deletionDestinationTables].filter(table => dst.has(table))) {
      const amount = await count(destination, table);
      report.destination[table] = amount;
      if (amount) block('destination_not_empty', table, amount);
    }
    report.source.accounts = await count(source, sourceUsers);
    // Column support is checked before accessing credentials. OAuth, MFA, passkeys,
    // pending account changes and unknown business rows cannot silently disappear.
    const sourceColumns = new Set((await columns(source, sourceUsers)).map(c => c.name));
    for (const name of ['id', 'email', 'encrypted_password', 'email_confirmed_at', 'raw_user_meta_data',
      'raw_app_meta_data', 'created_at', 'updated_at', 'deleted_at', 'is_anonymous', 'banned_until', 'last_sign_in_at']) {
      if (!sourceColumns.has(name)) fail('unsupported_source_auth_schema');
    }
    const unsupportedWhere = " WHERE deleted_at IS NOT NULL OR is_anonymous OR email IS NULL OR octet_length(btrim(email)) NOT BETWEEN 10 AND 254 OR email !~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$' OR encrypted_password IS NULL OR encrypted_password !~ '^\\$2[aby]\\$(0[4-9]|[12][0-9]|3[01])\\$[./A-Za-z0-9]{53}$' OR banned_until>now()"
      + (sourceColumns.has('is_sso_user') ? ' OR is_sso_user' : '') + (sourceColumns.has('phone') ? " OR coalesce(phone,'')<>''" : '');
    const unsupported = await count(source, sourceUsers, unsupportedWhere);
    if (unsupported) block('unsupported_accounts_or_password_hashes', 'auth.users', unsupported);
    const duplicates = rowCount(await source.query(`SELECT count(*)::text AS count FROM (SELECT lower(btrim(email)) FROM ${relation(sourceUsers)} GROUP BY lower(btrim(email)) HAVING count(*)>1) duplicates`));
    if (duplicates) block('duplicate_normalized_emails', 'auth.users', duplicates);
    if (sourceColumns.has('email_change')) {
      const pending = await count(source, sourceUsers, " WHERE coalesce(email_change,'')<>''");
      if (pending) block('pending_email_changes', 'auth.users', pending);
    }
    const securityTables = new Set(['mfa_factors', ...[...src.keys()]
      .filter(name => (name.startsWith('auth.') || name.startsWith(sourceAuthSchema + '.')) && /passkey|webauthn/i.test(name))
      .map(name => name.slice(name.indexOf('.') + 1))]);
    for (const name of securityTables) {
      const table = sourceAuthSchema + '.' + name;
      if (exportedAuth && src.get(table) !== 'v') { block('source_auth_export_incomplete', 'auth.' + name); continue; }
      if (!src.has(table)) continue;
      const amount = await count(source, table); report.source['auth.' + name] = amount;
      if (amount) block('security_credentials_require_reviewed_transfer', 'auth.' + name, amount);
    }
    if (src.has(sourceAuthSchema + '.identities')) {
      const amount = await count(source, sourceAuthSchema + '.identities', " WHERE provider<>'email'");
      report.source.external_identities = amount;
      if (amount) block('external_identities_not_supported', 'auth.identities', amount);
    }
    const copying = [], preserving = [];
    for (const [table, kind] of src) {
      if (exportedAuth && table.startsWith(sourceAuthSchema + '.')) continue;
      if (!['r', 'p'].includes(kind)) continue;
      const business = /^(bound_|cup[0-9])/.test(table) || table.startsWith('public.');
      if (!business && table !== 'storage.objects') continue;
      const amount = await count(source, table); report.source[table] = amount;
      if (Object.hasOwn(legacyRowOwners, table) || Object.hasOwn(deletedRowOwners, table)) {
        const required = Object.hasOwn(deletedRowOwners, table)
          ? ['bound_archive_private.catalog', 'bound_archive_private.deleted_records', 'cup117_private.deletions'] : archiveTables.slice(0, 2);
        if (!required.every(name => dst.has(name))) {
          if (amount) block('destination_archive_schema_missing', table, amount);
          continue;
        }
        try { preserving.push(await legacyRowPlan(source, table, await columns(source, table), amount, sourceUsers)); }
        catch (error) { block(error instanceof ArchiveImportError ? error.code : 'legacy_schema_check_failed', table, amount); }
        continue;
      }
      if (table === 'storage.objects') {
        if (amount) {
          if (!dst.has('bound_archive_private.objects')) block('destination_archive_schema_missing', table, amount);
          else {
            try { archive = await prepareArchiveImport({ source, manifestPath: env.LEGACY_ARCHIVE_MANIFEST, objectCount: amount, env, sourceUsers }); }
            catch (error) { block(error instanceof ArchiveImportError ? error.code : 'archive_verification_failed', table, amount); }
          }
        }
        continue;
      }
      if (!tables.includes(table)) {
        if (amount) block('unmapped_business_data', table, amount);
        continue;
      }
      if (!dst.has(table)) { if (amount) block('destination_table_missing', table, amount); continue; }
      const sourceFields = await columns(source, table), destinationFields = await columns(destination, table);
      if (!compatibleColumns(sourceFields, destinationFields)) { if (amount) block('table_shape_differs', table, amount); continue; }
      copying.push({ table, fields: sourceFields, count: amount });
    }
    const grants = copying.some(entry => entry.table === 'bound_dropbox_private.links')
      ? await count(source, 'bound_dropbox_private.links', ' WHERE ciphertext IS NOT NULL') : 0;
    report.source.dropbox_encrypted_grants = grants;
    report.archive = { rows: preserving.filter(entry => !entry.deleted).reduce((total, entry) => total + entry.count, 0),
      deleted_records: preserving.filter(entry => entry.deleted).reduce((total, entry) => total + entry.count, 0),
      objects: archive?.count ?? 0, bytes: archive?.bytes ?? 0 };
    let cipher;
    if (grants && !resetDropboxLinks) {
      try { cipher = createGrantCipher(env.DROPBOX_ENCRYPTION_KEY, env.DROPBOX_APP_KEY); }
      catch { block('original_dropbox_keys_required', 'bound_dropbox_private.links'); }
      if (!env.DROPBOX_APP_KEY) block('original_dropbox_app_key_required', 'bound_dropbox_private.links');
    }
    if (!apply || report.blockers.length) return report;

    // No sessions or reset capabilities are copied. Users sign in again to obtain
    // Nakama-issued credentials; old sessions keep working on the old backend.
    const accountFields = ['id', 'email', 'encrypted_password', 'email_confirmed_at', 'raw_user_meta_data',
      'raw_app_meta_data', 'created_at', 'updated_at', 'deleted_at', 'is_anonymous', 'banned_until', 'last_sign_in_at',
      ...['is_sso_user', 'phone'].filter(name => sourceColumns.has(name))].map(quote).join(',');
    const accountMetadata = [];
    for await (const row of rows(source, sourceUsers, accountFields)) {
      let name;
      if (src.has('bound_social_private.profiles')) {
        name = (await source.query('SELECT username FROM bound_social_private.profiles WHERE owner=$1', [row.id])).rows[0]?.username;
      }
      const user = projectUser(row, name);
      await destination.query(`INSERT INTO public.users(id,username,email,password,custom_id,display_name,metadata,create_time,update_time,verify_time)
        VALUES($1,$2,$3,$4,$5,$6,'{}'::jsonb,$7,$8,coalesce($9::timestamptz,to_timestamp(0)))`,
      [user.id, user.username, user.email, user.password, user.customID, user.displayName, user.createdAt, user.updatedAt, row.email_confirmed_at]);
      const legacy = JSON.stringify(user.legacy);
      await destination.query(`INSERT INTO public.storage(collection,key,user_id,value,version,read,write)
        VALUES('bound_legacy_accounts_v1','source',$1,$2::jsonb,$3,0,0)`, [user.id, legacy, createHash('md5').update(legacy).digest('hex')]);
      // Metadata updates run the signup trigger. Restore original profile rows
      // first so that trigger cannot fabricate a conflicting fresh profile.
      accountMetadata.push([JSON.stringify(user.metadata), user.id]);
    }
    copying.sort((a, b) => tables.indexOf(a.table) - tables.indexOf(b.table));
    for (const entry of copying) {
      const names = entry.fields.map(field => field.name);
      const resetGrants = resetDropboxLinks && entry.table === 'bound_dropbox_private.links';
      // Reset only the destination connection. Do not read old grant ciphertext,
      // revoke a provider token, or change the old backend's working connection.
      const selected = resetGrants
        ? names.map(name => name === 'ciphertext' ? 'NULL::text AS "ciphertext"' : quote(name)).join(',') : '*';
      for await (const row of rows(source, entry.table, selected)) {
        if (resetGrants) {
          row.ciphertext = null;
          row.revision = randomUUID();
        }
        if (entry.table === 'bound_dropbox_private.links' && row.ciphertext) {
          try { await cipher.open(row.owner, row.ciphertext); } catch { fail('dropbox_ciphertext_key_mismatch'); }
        }
        await destination.query(`INSERT INTO ${relation(entry.table)} (${names.map(quote).join(',')}) OVERRIDING SYSTEM VALUE
          VALUES(${names.map((_, index) => '$' + (index + 1)).join(',')})`, names.map(name => row[name]));
      }
      if (await count(destination, entry.table) !== entry.count) fail('import_count_mismatch');
      for (const field of entry.fields.filter(field => field.identity === 'YES')) {
        const result = await destination.query(`SELECT pg_get_serial_sequence($1,$2) AS sequence,
          (coalesce(max(${quote(field.name)}),0)+1)::text AS next FROM ${relation(entry.table)}`, [entry.table, field.name]);
        const { sequence, next } = result.rows[0];
        if (!/^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$/.test(sequence || '') || !/^[1-9][0-9]*$/.test(next)) fail('unsupported_identity_sequence');
        // ALTER ... RESTART is transactional; setval() would escape rollback.
        await destination.query(`ALTER SEQUENCE ${relation(sequence)} RESTART WITH ${next}`);
      }
    }
    for (const entry of preserving) {
      await destination.query(`INSERT INTO bound_archive_private.catalog(source_table,source_columns,source_primary_key)
        VALUES($1,$2::jsonb,$3::jsonb)`, [entry.table, JSON.stringify(entry.fields), JSON.stringify(entry.primaryKey)]);
      for await (const row of rows(source, entry.table, legacyRowSelection(entry))) {
        if (!uuid.test(row.owner ?? '') || typeof row.source_key !== 'string' || typeof row.source_row !== 'string') fail('invalid_legacy_row');
        await insertLegacyRow(destination, entry, row);
      }
      const target = entry.deleted ? 'bound_archive_private.deleted_records' : 'bound_archive_private.records';
      const copied = rowCount(await destination.query(`SELECT count(*)::text AS count FROM ${target} WHERE source_table=$1`, [entry.table]));
      if (copied !== entry.count) fail('legacy_import_count_mismatch');
      if (entry.deleted && entry.table === 'cup117_private.deletions'
          && await count(destination, 'cup117_private.deletions') !== entry.count) fail('legacy_tombstone_count_mismatch');
    }
    if (archive) await archive.apply(destination);
    for (const parameters of accountMetadata) {
      await destination.query('UPDATE public.users SET metadata=$1::jsonb WHERE id=$2', parameters);
    }
    if (await count(destination, 'public.users', ` WHERE id<>'${SYSTEM}'`) !== report.source.accounts) fail('account_count_mismatch');
    commitStarted = true;
    await destination.query('COMMIT'); destinationOpen = false; report.imported = true;
    return report;
  } finally {
    if (destinationOpen) await destination.query('ROLLBACK').catch(() => {});
    if (sourceOpen) await source.query('ROLLBACK').catch(() => {});
    // A lost COMMIT reply is ambiguous. Preserve imported files for inspection
    // instead of possibly deleting bytes whose manifest already committed.
    if (archive && !commitStarted) await archive.discard();
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help')) {
    process.stdout.write('node import-legacy.mjs [--check | --apply] [--reset-dropbox-links]\nRequired env: SOURCE_DATABASE_URL, DATABASE_URL. Optional: SOURCE_AUTH_SCHEMA, LEGACY_ARCHIVE_MANIFEST, FILE_DIRECTORY. Default: read-only count/check report.\n--reset-dropbox-links requires Dropbox reconnection on the destination and leaves source grants untouched.\n');
    return;
  }
  if (args.length !== new Set(args).size || args.some(arg => !['--check', '--apply', '--reset-dropbox-links'].includes(arg))
      || (args.includes('--check') && args.includes('--apply'))) fail('invalid_arguments');
  const sourceURL = process.env.SOURCE_DATABASE_URL, destinationURL = process.env.DATABASE_URL;
  if (!sourceURL || !destinationURL || sourceURL === destinationURL) fail('distinct_database_urls_required');
  // Credentials are environment-only and never copied to reports or export files.
  const { default: pg } = await import('pg');
  const types = { getTypeParser: (oid, format) => [1082, 1114, 1184].includes(oid) ? value => value : pg.types.getTypeParser(oid, format) };
  const parsedSource = new URL(sourceURL);
  if (!['postgres:', 'postgresql:'].includes(parsedSource.protocol)) fail('invalid_source_database_url');
  const localSource = ['localhost', '127.0.0.1', '[::1]'].includes(parsedSource.hostname);
  // Do not let URL SSL options silently disable certificate verification.
  for (const name of ['ssl', 'sslmode', 'sslcert', 'sslkey', 'sslrootcert', 'options']) parsedSource.searchParams.delete(name);
  const source = new pg.Client({ connectionString: parsedSource.toString(), ssl: localSource ? false : { rejectUnauthorized: true }, application_name: 'bound-legacy-readonly', types,
    options: '-c default_transaction_read_only=on', connectionTimeoutMillis: 10000 });
  const destination = new pg.Client({ connectionString: destinationURL, application_name: 'bound-legacy-import', types, connectionTimeoutMillis: 10000 });
  try {
    await source.connect(); await destination.connect();
    const report = await importLegacy({ source, destination, apply: args.includes('--apply'),
      resetDropboxLinks: args.includes('--reset-dropbox-links'), env: process.env });
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
    if (report.blockers.length) process.exitCode = 2;
  } finally { await source.end().catch(() => {}); await destination.end().catch(() => {}); }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { await main(); }
  catch (error) {
    // PostgreSQL detail strings can contain credentials, emails and row contents.
    process.stderr.write(JSON.stringify({ error: error instanceof ImportError ? error.code : 'import_failed_no_source_changes' }) + '\n');
    process.exitCode = 1;
  }
}
