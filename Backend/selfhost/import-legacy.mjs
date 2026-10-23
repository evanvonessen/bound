import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createGrantCipher } from '../dropbox-link/handler.mjs';

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
  WHERE c.relkind IN ('r','p','v') AND (n.nspname IN ('public','auth','storage')
    OR n.nspname ~ '^(bound_|cup[0-9])')
    AND NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass
      AND d.objid=c.oid AND d.deptype='e') ORDER BY n.nspname,c.relname`;
const columnsSQL = `SELECT column_name AS name,udt_name AS type,is_nullable AS nullable,
  column_default AS default,is_identity AS identity,is_generated AS generated
  FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 ORDER BY ordinal_position`;
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
const catalog = async client => new Map((await client.query(tableListSQL)).rows.map(row => [row.schema + '.' + row.name, row.kind]));
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

export async function importLegacy({ source, destination, apply = false, env = {} }) {
  const report = { mode: apply ? 'apply' : 'check', source: {}, destination: {}, blockers: [], imported: false };
  const block = (code, table, amount) => report.blockers.push({ code, ...(table ? { table } : {}), ...(amount !== undefined ? { count: amount } : {}) });
  let sourceOpen = false, destinationOpen = false;
  try {
    await source.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'); sourceOpen = true;
    await source.query("SET LOCAL statement_timeout='60s'");
    await source.query("SET LOCAL row_security=off");
    await source.query("SET LOCAL idle_in_transaction_session_timeout='10min'");
    const sourceSettings = await source.query('SHOW transaction_read_only');
    if (sourceSettings.rows[0]?.transaction_read_only !== 'on') fail('source_not_read_only');
    await destination.query(apply ? 'BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE' : 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'); destinationOpen = true;
    await destination.query("SET LOCAL lock_timeout='5s'");
    await destination.query("SET LOCAL statement_timeout='60s'");
    const src = await catalog(source), dst = await catalog(destination);
    if (!['r', 'p'].includes(src.get('auth.users')) || dst.get('auth.users') !== 'v'
        || dst.get('public.users') !== 'r' || dst.get('public.storage') !== 'r') fail('expected_source_and_destination_schemas');
    const nativeColumns = new Map((await columns(destination, 'public.users')).map(c => [c.name, c.type]));
    for (const [name, type] of [['id', 'uuid'], ['password', 'bytea'], ['metadata', 'jsonb'], ['custom_id', 'varchar']]) {
      if (nativeColumns.get(name) !== type) fail('unsupported_nakama_schema');
    }
    if (apply) {
      const locked = ['public.users', 'public.storage', ...tables.filter(table => dst.has(table))];
      await destination.query(`LOCK TABLE ${locked.map(relation).join(',')} IN ACCESS EXCLUSIVE MODE`);
    }
    report.destination.accounts = await count(destination, 'public.users', ` WHERE id<>'${SYSTEM}'`);
    report.destination.storage = await count(destination, 'public.storage');
    if (report.destination.accounts || report.destination.storage) block('destination_not_empty');
    for (const table of tables.filter(table => dst.has(table))) {
      const amount = await count(destination, table);
      report.destination[table] = amount;
      if (amount) block('destination_not_empty', table, amount);
    }
    report.source.accounts = await count(source, 'auth.users');
    // Column support is checked before accessing credentials. OAuth, MFA, passkeys,
    // pending account changes and unknown business rows cannot silently disappear.
    const sourceColumns = new Set((await columns(source, 'auth.users')).map(c => c.name));
    for (const name of ['id', 'email', 'encrypted_password', 'email_confirmed_at', 'raw_user_meta_data',
      'raw_app_meta_data', 'created_at', 'updated_at', 'deleted_at', 'is_anonymous', 'banned_until', 'last_sign_in_at']) {
      if (!sourceColumns.has(name)) fail('unsupported_source_auth_schema');
    }
    const unsupportedWhere = " WHERE deleted_at IS NOT NULL OR is_anonymous OR email IS NULL OR octet_length(btrim(email)) NOT BETWEEN 10 AND 254 OR email !~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$' OR encrypted_password IS NULL OR encrypted_password !~ '^\\$2[aby]\\$(0[4-9]|[12][0-9]|3[01])\\$[./A-Za-z0-9]{53}$' OR banned_until>now()"
      + (sourceColumns.has('is_sso_user') ? ' OR is_sso_user' : '') + (sourceColumns.has('phone') ? " OR coalesce(phone,'')<>''" : '');
    const unsupported = await count(source, 'auth.users', unsupportedWhere);
    if (unsupported) block('unsupported_accounts_or_password_hashes', 'auth.users', unsupported);
    const duplicates = rowCount(await source.query("SELECT count(*)::text AS count FROM (SELECT lower(btrim(email)) FROM auth.users GROUP BY lower(btrim(email)) HAVING count(*)>1) duplicates"));
    if (duplicates) block('duplicate_normalized_emails', 'auth.users', duplicates);
    if (sourceColumns.has('email_change')) {
      const pending = await count(source, 'auth.users', " WHERE coalesce(email_change,'')<>''");
      if (pending) block('pending_email_changes', 'auth.users', pending);
    }
    for (const table of ['auth.mfa_factors', ...[...src.keys()].filter(name => name.startsWith('auth.') && /passkey|webauthn/i.test(name))]) {
      if (!src.has(table)) continue;
      const amount = await count(source, table); report.source[table] = amount;
      if (amount) block('security_credentials_require_reviewed_transfer', table, amount);
    }
    if (src.has('auth.identities')) {
      const amount = await count(source, 'auth.identities', " WHERE provider<>'email'");
      report.source.external_identities = amount;
      if (amount) block('external_identities_not_supported', 'auth.identities', amount);
    }
    const copying = [];
    for (const [table, kind] of src) {
      if (!['r', 'p'].includes(kind)) continue;
      const business = /^(bound_|cup[0-9])/.test(table) || table.startsWith('public.');
      if (!business && table !== 'storage.objects') continue;
      const amount = await count(source, table); report.source[table] = amount;
      if (!tables.includes(table)) {
        if (amount) block(table === 'storage.objects' ? 'storage_files_require_transfer' : 'unmapped_business_data', table, amount);
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
    let cipher;
    if (grants) {
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
    for await (const row of rows(source, 'auth.users', accountFields)) {
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
      // The signup trigger runs on INSERT only; original profile rows arrive below.
      await destination.query('UPDATE public.users SET metadata=$1::jsonb WHERE id=$2', [JSON.stringify(user.metadata), user.id]);
    }
    copying.sort((a, b) => tables.indexOf(a.table) - tables.indexOf(b.table));
    for (const entry of copying) {
      const names = entry.fields.map(field => field.name);
      for await (const row of rows(source, entry.table)) {
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
    if (await count(destination, 'public.users', ` WHERE id<>'${SYSTEM}'`) !== report.source.accounts) fail('account_count_mismatch');
    await destination.query('COMMIT'); destinationOpen = false; report.imported = true;
    return report;
  } finally {
    if (destinationOpen) await destination.query('ROLLBACK').catch(() => {});
    if (sourceOpen) await source.query('ROLLBACK').catch(() => {});
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help')) {
    process.stdout.write('node import-legacy.mjs [--check | --apply]\nRequired env: SOURCE_DATABASE_URL, DATABASE_URL. Default: read-only count/check report.\n');
    return;
  }
  if (args.length > 1 || args.some(arg => !['--check', '--apply'].includes(arg))) fail('invalid_arguments');
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
    const report = await importLegacy({ source, destination, apply: args[0] === '--apply', env: process.env });
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
