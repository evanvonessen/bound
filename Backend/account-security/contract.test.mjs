import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const {PGlite}=await import(process.env.PGLITE_MODULE ?? '@electric-sql/pglite');
const owner='11111111-1111-4111-8111-111111111111';
const other='22222222-2222-4222-8222-222222222222';
const clientTables=['cup040_catalogue','bound_note_revisions','bound_autosave_revisions','bound_roms'];
const contract=await readFile(new URL('./contract.sql',import.meta.url),'utf8');
const rollback=await readFile(new URL('./rollback.sql',import.meta.url),'utf8');
async function seed(db) {
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE ROLE authenticator;
      CREATE SCHEMA auth; CREATE SCHEMA storage;
      CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT (auth.jwt()->>'sub')::uuid $$;
      CREATE TABLE auth.mfa_factors(user_id uuid,status text);
      CREATE TABLE storage.objects(owner uuid,name text);
      ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
      GRANT USAGE ON SCHEMA storage,auth TO authenticated;
      GRANT EXECUTE ON FUNCTION auth.jwt(),auth.uid() TO authenticated;
      GRANT SELECT,INSERT ON storage.objects TO authenticated;
      CREATE POLICY owner_access ON storage.objects TO authenticated USING(owner=auth.uid()) WITH CHECK(owner=auth.uid());
      INSERT INTO storage.objects VALUES('${owner}','own'),('${other}','other');
      CREATE FUNCTION public.legacy_build12_rpc(p_request text) RETURNS text LANGUAGE sql AS $$ SELECT p_request $$;`);
  for (const table of clientTables) {
    await db.exec(`CREATE TABLE public.${table}(owner uuid); ALTER TABLE public.${table} ENABLE ROW LEVEL SECURITY; GRANT SELECT ON public.${table} TO authenticated; CREATE POLICY existing_owner ON public.${table} TO authenticated USING(owner=auth.uid()); INSERT INTO public.${table} VALUES('${owner}');`);
  }
}
async function currentDatabase(db) {
  const name=(await db.query('SELECT current_database() name')).rows[0].name;
  return '"'+name.replaceAll('"','""')+'"';
}
async function hookSettings(db) {
  return (await db.query(`SELECT r.setrole, r.setdatabase, r.setconfig FROM pg_db_role_setting r
    WHERE EXISTS (SELECT 1 FROM unnest(r.setconfig) setting WHERE setting LIKE 'pgrst.db_pre_request=%')
    ORDER BY r.setrole,r.setdatabase`)).rows;
}
test('optional MFA preserves legacy accounts and enforces enrolled users on RPC, Storage and direct RLS',async()=>{
  const db=new PGlite();
  try {
    await seed(db);
    const before=(await db.query("SELECT md5(pg_get_functiondef('public.legacy_build12_rpc(text)'::regprocedure)) h")).rows[0].h;
    await db.exec(contract);
    const claims=async(role,sub=owner,aal)=>{
      await db.exec('RESET ROLE');
      await db.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({role,sub,...(aal?{aal}:{})})]);
      await db.exec(`SET ROLE ${role}`);
    };
    await claims('authenticated');
    assert.equal((await db.query('SELECT public.bound_account_mfa_allowed() ok')).rows[0].ok,true,'build12 JWT without aal still works');
    await db.query('SELECT public.bound_require_mfa()');
    assert.equal((await db.query("SELECT public.legacy_build12_rpc('unchanged') value")).rows[0].value,'unchanged');
    assert.deepEqual((await db.query('SELECT name FROM storage.objects')).rows,[{name:'own'}]);
    for (const table of clientTables) assert.equal((await db.query(`SELECT * FROM public.${table}`)).rows.length,1,'direct RLS preserves legacy AAL1 access');
    await db.exec('RESET ROLE');
    await db.query("INSERT INTO auth.mfa_factors VALUES($1,'unverified')",[owner]);
    await claims('authenticated');
    assert.equal((await db.query('SELECT public.bound_account_mfa_allowed() ok')).rows[0].ok,true);
    await db.exec('RESET ROLE');
    await db.exec("UPDATE auth.mfa_factors SET status='verified'");
    await claims('authenticated');
    assert.equal((await db.query('SELECT public.bound_account_mfa_allowed() ok')).rows[0].ok,false);
    await assert.rejects(db.query('SELECT public.bound_require_mfa()'),/second_factor_required/);
    assert.equal((await db.query('SELECT name FROM storage.objects')).rows.length,0);
    for (const table of clientTables) assert.equal((await db.query(`SELECT * FROM public.${table}`)).rows.length,0,'direct RLS/Realtime denies opted-in AAL1');
    await assert.rejects(db.query("INSERT INTO storage.objects VALUES($1,'denied')",[owner]),/row-level security/);
    await assert.rejects(db.query('SELECT * FROM auth.mfa_factors'),/permission denied/);
    await claims('authenticated',owner,'aal2');
    await db.query('SELECT public.bound_require_mfa()');
    assert.deepEqual((await db.query('SELECT name FROM storage.objects')).rows,[{name:'own'}]);
    for (const table of clientTables) assert.equal((await db.query(`SELECT * FROM public.${table}`)).rows.length,1,'direct RLS allows verified AAL2');
    await claims('authenticated',other);
    await db.query('SELECT public.bound_require_mfa()');
    assert.deepEqual((await db.query('SELECT name FROM storage.objects')).rows,[{name:'other'}],'MFA on one account does not block other build12 clients');
    await claims('anon'); await db.query('SELECT public.bound_require_mfa()');
    await claims('service_role'); await db.query('SELECT public.bound_require_mfa()');
    await db.exec('RESET ROLE');
    assert.equal((await db.query("SELECT md5(pg_get_functiondef('public.legacy_build12_rpc(text)'::regprocedure)) h")).rows[0].h,before);
    await db.exec(rollback);
    assert.equal((await db.query("SELECT count(*)::int n FROM auth.mfa_factors")).rows[0].n,1,'rollback preserves Auth factors');
    assert.equal((await db.query("SELECT count(*)::int n FROM pg_policy WHERE polname='bound_account_mfa_guard'")).rows[0].n,0,'rollback removes all five MFA policies');
  } finally {await db.close();}
});

const conflictingHooks=[
  ['role-wide hook', () => "ALTER ROLE authenticator SET pgrst.db_pre_request='public.existing_hook'"],
  ['database-specific role hook', database => `ALTER ROLE authenticator IN DATABASE ${database} SET pgrst.db_pre_request='public.existing_hook'`],
  ['database-wide hook', database => `ALTER DATABASE ${database} SET pgrst.db_pre_request='public.existing_hook'`],
  ['empty database-specific role override', database => `ALTER ROLE authenticator IN DATABASE ${database} SET pgrst.db_pre_request=''`],
  ['empty database-wide override', database => `ALTER DATABASE ${database} SET pgrst.db_pre_request=''`],
];

for(const [name,setting] of conflictingHooks) {
  test(`deployment rejects existing ${name} without changing prior configuration`,async()=>{
    const db=new PGlite();
    try {
      await seed(db);
      await db.exec(setting(await currentDatabase(db)));
      const before=await hookSettings(db);
      await assert.rejects(db.exec(contract),/Existing pre-request hook/);
      await db.exec('ROLLBACK');
      assert.deepEqual(await hookSettings(db),before,'existing hook remains unchanged');
      assert.equal((await db.query("SELECT to_regnamespace('bound_auth_private') value")).rows[0].value,null,'failed deployment rolls back its private schema');
      assert.equal((await db.query("SELECT to_regprocedure('public.bound_require_mfa()') value")).rows[0].value,null,'failed deployment leaves no guard function');
      assert.equal((await db.query("SELECT count(*)::int count FROM pg_policy WHERE polname='bound_account_mfa_guard'")).rows[0].count,0,'failed deployment leaves no MFA policies');
    } finally {await db.close();}
  });
}

for(const [name,setting] of conflictingHooks) {
  test(`rollback refuses changed ${name} and preserves enforcement objects`,async()=>{
    const db=new PGlite();
    try {
      await seed(db);
      await db.exec(contract);
      await db.exec(setting(await currentDatabase(db)));
      const before=await hookSettings(db);
      await assert.rejects(db.exec(rollback),/Pre-request configuration changed/);
      await db.exec('ROLLBACK');
      assert.deepEqual(await hookSettings(db),before,'failed rollback changes no hook settings');
      assert.notEqual((await db.query("SELECT to_regprocedure('public.bound_require_mfa()') value")).rows[0].value,null,'failed rollback retains the guard function');
      assert.equal((await db.query("SELECT count(*)::int count FROM pg_policy WHERE polname='bound_account_mfa_guard'")).rows[0].count,5,'failed rollback retains all MFA policies');
    } finally {await db.close();}
  });
}

test('unrelated role hooks survive deployment and rollback',async()=>{
  const db=new PGlite();
  try {
    await seed(db);
    await db.exec("CREATE ROLE unrelated_api; ALTER ROLE unrelated_api SET pgrst.db_pre_request='public.unrelated_hook'");
    const before=await hookSettings(db);
    await db.exec(contract);
    await db.exec(rollback);
    assert.deepEqual(await hookSettings(db),before);
  } finally {await db.close();}
});
