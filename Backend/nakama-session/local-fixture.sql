-- Disposable local PostgreSQL fixture only. Never apply to Supabase.
DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role','authenticator'] LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('CREATE ROLE %I',r); END IF;
END LOOP; END $$;
CREATE SCHEMA auth;
CREATE SCHEMA storage;
CREATE SCHEMA cup050_private;
CREATE SCHEMA cup117_private;
CREATE SCHEMA bound_moderation_private;
REVOKE ALL ON SCHEMA cup050_private,cup117_private,bound_moderation_private FROM PUBLIC,anon,authenticated;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb
$$;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT (auth.jwt()->>'sub')::uuid $$;
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT EXECUTE ON FUNCTION auth.jwt(),auth.uid() TO authenticated;
CREATE TABLE auth.users(id uuid PRIMARY KEY,deleted_at timestamptz,is_anonymous boolean DEFAULT false,
  email_confirmed_at timestamptz DEFAULT now());
CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,not_after timestamptz);
CREATE TABLE auth.mfa_factors(user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,status text);
CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY);
CREATE TABLE cup050_private.rooms(id uuid PRIMARY KEY,owner_a uuid REFERENCES auth.users(id),
  owner_b uuid REFERENCES auth.users(id),name_a text,name_b text,active boolean DEFAULT true);
CREATE TABLE bound_moderation_private.blocks(owner uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  target uuid REFERENCES auth.users(id) ON DELETE CASCADE,PRIMARY KEY(owner,target));
CREATE TABLE bound_moderation_private.suspensions(owner uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE);
ALTER TABLE bound_moderation_private.blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE bound_moderation_private.suspensions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA auth,cup050_private,cup117_private,bound_moderation_private FROM PUBLIC,anon,authenticated;
-- Exact existing moderation predicate; it reads only private, ungranted tables.
CREATE FUNCTION bound_moderation_private.denied_pair(a uuid,b uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
  SELECT EXISTS(SELECT 1 FROM bound_moderation_private.blocks WHERE (owner=a AND target=b) OR (owner=b AND target=a))
  OR EXISTS(SELECT 1 FROM bound_moderation_private.suspensions WHERE owner IN(a,b))
$$;
REVOKE ALL ON FUNCTION bound_moderation_private.denied_pair(uuid,uuid) FROM PUBLIC,anon,authenticated;
-- Existing catalogue/storage shapes remain available for preservation checks.
CREATE TABLE storage.objects(owner uuid,name text);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.cup040_catalogue(owner uuid);
CREATE TABLE public.bound_note_revisions(owner uuid);
CREATE TABLE public.bound_autosave_revisions(owner uuid);
CREATE TABLE public.bound_roms(owner uuid);
ALTER TABLE public.cup040_catalogue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bound_note_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bound_autosave_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bound_roms ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION public.cup050_friends(action text,payload jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT '{"fixture":"unchanged-friends"}'::jsonb $$;
