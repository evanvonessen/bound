-- Disposable local PostgreSQL fixture only. Never apply to Supabase.
\ir ../account-deletion/fixture.sql
\ir ../moderation/local-fixture.sql
-- Match the verified live cup050_private.rooms shape exactly (no created_at column).
ALTER TABLE cup050_private.rooms DROP COLUMN created_at;
CREATE SCHEMA bound_moderation_private;
REVOKE ALL ON SCHEMA bound_moderation_private FROM PUBLIC, anon, authenticated;
CREATE TABLE bound_moderation_private.blocks(owner uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, label text NOT NULL, PRIMARY KEY(owner,target));
CREATE TABLE bound_moderation_private.suspensions(owner uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE);
CREATE FUNCTION bound_moderation_private.clean_name(value text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT coalesce(char_length(btrim(value)) BETWEEN 1 AND 40 AND value !~ '[[:cntrl:]]'
   AND value !~* '(https?://|www\.|@|[[:<:]](fuck|shit|cunt|nigger|faggot)[[:>:]])'
   AND value !~ U&'[\200B-\200F\202A-\202E\2066-\2069\FEFF]',false)
$$;
CREATE FUNCTION bound_moderation_private.denied_pair(a uuid,b uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM bound_moderation_private.blocks WHERE (owner=a AND target=b) OR (owner=b AND target=a))
 OR EXISTS(SELECT 1 FROM bound_moderation_private.suspensions WHERE owner IN(a,b))
$$;
INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data) VALUES
 ('33333333-3333-4333-8333-333333333333','third@example.invalid',now(),'{"cupcake_username_v1":"Third Seed"}'),
 ('44444444-4444-4444-8444-444444444444','anonymous@example.invalid',now(),'{}'),
 ('55555555-5555-4555-8555-555555555555','deleted@example.invalid',now(),'{}'),
 ('66666666-6666-4666-8666-666666666666','unconfirmed@example.invalid',NULL,'{}'),
 ('77777777-7777-4777-8777-777777777777','room-seed@example.invalid',now(),'{}'),
 ('88888888-8888-4888-8888-888888888888','room-peer@example.invalid',now(),'{}');
UPDATE auth.users SET is_anonymous=true WHERE id='44444444-4444-4444-8444-444444444444';
UPDATE auth.users SET deleted_at=now() WHERE id='55555555-5555-4555-8555-555555555555';
INSERT INTO cup050_private.rooms(owner_a,owner_b,name_a,name_b) VALUES
 ('77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888888','Room Seed','Other Name');
CREATE FUNCTION public.cup050_friends(action text,payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid(); room_id uuid; pairing cup050_private.rooms%rowtype;
BEGIN
 IF action='list' THEN
   RETURN jsonb_build_object('ok',true,'rooms',coalesce((SELECT jsonb_agg(jsonb_build_object('roomID',r.id,'displayName',CASE WHEN actor=r.owner_a THEN r.name_b ELSE r.name_a END))
     FROM cup050_private.rooms r WHERE r.active AND actor IN(r.owner_a,r.owner_b)),'[]'::jsonb),'blocks','[]'::jsonb);
 ELSIF action='create' THEN
   INSERT INTO cup050_private.invites(digest,creator,display_name,expires_at)
     VALUES(extensions.digest('FIXTURECODE123456','sha256'),actor,payload->>'displayName',now()+interval '10 minutes')
     ON CONFLICT(digest) DO UPDATE SET creator=EXCLUDED.creator,display_name=EXCLUDED.display_name,expires_at=EXCLUDED.expires_at,consumed=false;
   RETURN jsonb_build_object('ok',true,'code','FIXTURECODE123456');
 ELSIF action='accept' THEN
   INSERT INTO cup050_private.rooms(owner_a,owner_b,name_a,name_b) VALUES('11111111-1111-4111-8111-111111111111',actor,'Old Alice',payload->>'displayName') RETURNING * INTO pairing;
   UPDATE cup050_private.invites SET consumed=true WHERE digest=extensions.digest('FIXTURECODE123456','sha256');
   RETURN jsonb_build_object('ok',true,'room',jsonb_build_object('roomID',pairing.id,'displayName',pairing.name_a));
 ELSIF action='room' OR action='remove' THEN
   SELECT * INTO pairing FROM cup050_private.rooms WHERE id=(payload->>'roomID')::uuid AND actor IN(owner_a,owner_b);
   IF NOT FOUND THEN RETURN '{"ok":false}'::jsonb; END IF;
   IF action='remove' THEN UPDATE cup050_private.rooms SET active=false WHERE id=pairing.id; RETURN '{"ok":true}'::jsonb; END IF;
   RETURN jsonb_build_object('ok',true,'room',jsonb_build_object('roomID',pairing.id,'channel','fixture'));
 ELSIF action IN('block','unblock','report') THEN RETURN jsonb_build_object('ok',true,'action',action);
 END IF;
 RETURN '{"ok":false}'::jsonb;
END $$;
GRANT EXECUTE ON FUNCTION public.cup050_friends(text,jsonb) TO authenticated;
