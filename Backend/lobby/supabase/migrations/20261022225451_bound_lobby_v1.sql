-- Four stable social slots; run/checkpoint authority stays in bound_run_lease_v1.
CREATE SCHEMA bound_lobby_private;
REVOKE ALL ON SCHEMA bound_lobby_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA bound_lobby_private TO authenticated;
CREATE TABLE bound_lobby_private.lobbies (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 creator uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 original_creator uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 request_id uuid NOT NULL,
 state text NOT NULL DEFAULT 'waiting' CHECK(state IN ('waiting','started')),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(original_creator,request_id)
);
CREATE TABLE bound_lobby_private.members (
 lobby uuid NOT NULL REFERENCES bound_lobby_private.lobbies(id) ON DELETE CASCADE,
 owner uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 uid smallint NOT NULL CHECK(uid BETWEEN 1 AND 4),
 inviter uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 friend_room uuid REFERENCES cup050_private.rooms(id) ON DELETE SET NULL,
 state text NOT NULL CHECK(state IN ('invited','joined','left','declined')),
 ready boolean NOT NULL DEFAULT false,
 mode text NOT NULL DEFAULT 'solo' CHECK(mode IN ('solo','soulLink')),
 run_id uuid,
 partner uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 member_token uuid NOT NULL DEFAULT gen_random_uuid(),
 session_id uuid,
 generation bigint NOT NULL DEFAULT 1 CHECK(generation>0),
 incarnation uuid NOT NULL DEFAULT gen_random_uuid(),
 expires_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(lobby,owner), UNIQUE(lobby,uid),
 CHECK(partner IS NULL OR partner<>owner)
);
CREATE INDEX ON bound_lobby_private.members(owner,lobby);
ALTER TABLE bound_lobby_private.lobbies ENABLE ROW LEVEL SECURITY;
ALTER TABLE bound_lobby_private.members ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA bound_lobby_private FROM PUBLIC, anon, authenticated;

-- All helpers remain private and uncallable by client roles. The dispatcher
-- checks the live Auth session before using its narrowly scoped privileges.
CREATE FUNCTION bound_lobby_private.eligible(a uuid,b uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM cup117_private.assert_active(a); PERFORM cup117_private.assert_active(b);
 RETURN a IS NOT NULL AND b IS NOT NULL AND a<>b
 AND EXISTS(SELECT 1 FROM auth.users WHERE id=a AND deleted_at IS NULL AND is_anonymous IS FALSE AND email_confirmed_at IS NOT NULL)
 AND EXISTS(SELECT 1 FROM auth.users WHERE id=b AND deleted_at IS NULL AND is_anonymous IS FALSE AND email_confirmed_at IS NOT NULL)
 AND NOT bound_moderation_private.denied_pair(a,b);
EXCEPTION WHEN insufficient_privilege THEN RETURN false;
END $$;
CREATE FUNCTION bound_lobby_private.friend(actor uuid,room uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE WHEN r.owner_a=actor THEN r.owner_b ELSE r.owner_a END
 FROM cup050_private.rooms r WHERE r.id=room AND r.active AND actor IN(r.owner_a,r.owner_b)
 AND bound_lobby_private.eligible(r.owner_a,r.owner_b)
$$;
CREATE FUNCTION bound_lobby_private.allowed(lobby_id uuid,actor uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM bound_lobby_private.members m
 WHERE m.lobby=lobby_id AND m.owner=actor
 AND (m.inviter IS NULL AND m.uid=1 OR bound_lobby_private.friend(actor,m.friend_room)=m.inviter))
 AND NOT EXISTS(SELECT 1 FROM bound_lobby_private.members m WHERE m.lobby=lobby_id AND m.owner<>actor
 AND m.state IN('joined','invited') AND NOT bound_lobby_private.eligible(actor,m.owner))
$$;
CREATE FUNCTION bound_lobby_private.snapshot(lobby_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('lobbyID',l.id,'creatorID',l.creator,'state',l.state,'revision',l.revision::text,
 'members',coalesce((SELECT jsonb_agg(jsonb_build_object('ownerID',m.owner,'displayName',coalesce(p.username,'Player'),
 'uid',m.uid,'state',m.state,'ready',m.ready,'mode',m.mode,'runID',m.run_id,'partnerOwnerID',m.partner,
 'generation',m.generation::text,'sessionID',m.incarnation,'online',m.state='joined' AND m.expires_at>clock_timestamp()) ORDER BY m.uid)
 FROM bound_lobby_private.members m LEFT JOIN bound_social_private.profiles p ON p.owner=m.owner WHERE m.lobby=l.id),'[]'::jsonb))
 FROM bound_lobby_private.lobbies l WHERE l.id=lobby_id
$$;

CREATE FUNCTION bound_lobby_private.dispatch(action text,payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 actor uuid:=auth.uid(); claims jsonb:=auth.jwt(); sid uuid; lid uuid; rid uuid; partner_id uuid; target uuid; token uuid;
 stamp timestamptz; row_l bound_lobby_private.lobbies%rowtype; row_m bound_lobby_private.members%rowtype;
 room_value jsonb; requested_mode text; requested_run uuid; rows_json jsonb; chosen_uid integer; changed boolean:=false;
 pattern constant text:='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
BEGIN
 IF actor IS NULL OR claims->>'role' IS DISTINCT FROM 'authenticated' OR coalesce(claims->>'session_id','') !~ pattern
 THEN RETURN '{"ok":false,"error":"unauthorized"}'; END IF;
 sid:=(claims->>'session_id')::uuid;
 PERFORM cup117_private.assert_active(actor);
 IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=actor AND deleted_at IS NULL AND is_anonymous IS FALSE AND email_confirmed_at IS NOT NULL)
 THEN RETURN '{"ok":false,"error":"unauthorized"}'; END IF;
 IF action IS NULL OR action NOT IN('create','list','get','invite','accept','decline','rejoin','configure','ready','start','leave','heartbeat','room')
 OR jsonb_typeof(payload) IS DISTINCT FROM 'object' OR octet_length(payload::text)>2048
 THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
 -- The session lock closes revocation races while requests wait for a lobby lock.
 PERFORM 1 FROM auth.sessions WHERE id=sid AND user_id=actor AND (not_after IS NULL OR not_after>clock_timestamp()) FOR KEY SHARE;
 IF NOT FOUND THEN RETURN '{"ok":false,"error":"unauthorized"}'; END IF;
 IF action='list' THEN
   IF payload<>'{}'::jsonb THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
   SELECT coalesce(jsonb_agg(bound_lobby_private.snapshot(l.id) ORDER BY l.updated_at DESC),'[]'::jsonb) INTO rows_json
   FROM (SELECT original.* FROM bound_lobby_private.lobbies original JOIN bound_lobby_private.members m ON m.lobby=original.id AND m.owner=actor
     WHERE m.state<>'declined' AND bound_lobby_private.allowed(original.id,actor) ORDER BY original.updated_at DESC LIMIT 32) l;
   RETURN jsonb_build_object('ok',true,'lobbies',rows_json);
 END IF;
 IF action IN('create','accept','rejoin','configure') THEN
   IF jsonb_typeof(payload->'mode') IS DISTINCT FROM 'string' OR payload->>'mode' NOT IN('solo','soulLink')
   OR NOT(payload ? 'runID') OR (payload->'runID'<>'null'::jsonb AND (jsonb_typeof(payload->'runID') IS DISTINCT FROM 'string' OR coalesce(payload->>'runID','') !~ pattern))
   OR NOT(payload ? 'partnerRoomID') OR (payload->'partnerRoomID'<>'null'::jsonb AND (jsonb_typeof(payload->'partnerRoomID') IS DISTINCT FROM 'string' OR coalesce(payload->>'partnerRoomID','') !~ pattern))
   THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
   requested_mode:=payload->>'mode'; requested_run:=(payload->>'runID')::uuid;
   partner_id:=bound_lobby_private.friend(actor,(payload->>'partnerRoomID')::uuid);
   IF (requested_mode='solo' AND payload->'partnerRoomID'<>'null'::jsonb)
   OR (requested_mode='soulLink' AND partner_id IS NULL) THEN RETURN '{"ok":false,"error":"invalid_partner"}'; END IF;
 END IF;
 IF action='create' THEN
   IF payload-'requestID'-'runID'-'mode'-'partnerRoomID'-'roomIDs'<>'{}'::jsonb OR coalesce(payload->>'requestID','') !~ pattern
   OR jsonb_typeof(payload->'roomIDs') IS DISTINCT FROM 'array' OR jsonb_array_length(payload->'roomIDs')>3
   THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
   -- Owner lock makes idempotency and the bounded account lobby count atomic.
   PERFORM pg_advisory_xact_lock(hashtextextended('bound-lobby:'||actor::text,0));
   SELECT * INTO row_l FROM bound_lobby_private.lobbies WHERE original_creator=actor AND request_id=(payload->>'requestID')::uuid FOR UPDATE;
   IF NOT FOUND THEN
     IF (SELECT count(*) FROM bound_lobby_private.lobbies WHERE original_creator=actor)>=64
     THEN RETURN '{"ok":false,"error":"lobby_limit"}'; END IF;
     -- Validate all invites before creating anything; failed requests are atomic.
     FOR room_value IN SELECT value FROM jsonb_array_elements(payload->'roomIDs') LOOP
       IF jsonb_typeof(room_value)<>'string' OR (room_value#>>'{}') !~ pattern OR bound_lobby_private.friend(actor,(room_value#>>'{}')::uuid) IS NULL
       THEN RETURN '{"ok":false,"error":"invalid_friend"}'; END IF;
     END LOOP;
     IF EXISTS(SELECT 1 FROM jsonb_array_elements(payload->'roomIDs') a CROSS JOIN jsonb_array_elements(payload->'roomIDs') b
       WHERE a.value<>b.value AND bound_lobby_private.friend(actor,(a.value#>>'{}')::uuid)<>bound_lobby_private.friend(actor,(b.value#>>'{}')::uuid)
       AND NOT bound_lobby_private.eligible(bound_lobby_private.friend(actor,(a.value#>>'{}')::uuid),bound_lobby_private.friend(actor,(b.value#>>'{}')::uuid)))
     THEN RETURN '{"ok":false,"error":"invalid_friend"}'; END IF;
     INSERT INTO bound_lobby_private.lobbies(creator,original_creator,request_id) VALUES(actor,actor,(payload->>'requestID')::uuid) RETURNING * INTO row_l;
     INSERT INTO bound_lobby_private.members(lobby,owner,uid,state,mode,run_id,partner,session_id,expires_at)
     VALUES(row_l.id,actor,1,'joined',requested_mode,requested_run,partner_id,sid,clock_timestamp()+interval '90 seconds');
     chosen_uid:=1;
     FOR room_value IN SELECT value FROM jsonb_array_elements(payload->'roomIDs') LOOP
       rid:=(room_value#>>'{}')::uuid; target:=bound_lobby_private.friend(actor,rid);
       IF NOT EXISTS(SELECT 1 FROM bound_lobby_private.members WHERE lobby=row_l.id AND owner=target) THEN
         chosen_uid:=chosen_uid+1;
         INSERT INTO bound_lobby_private.members(lobby,owner,uid,inviter,friend_room,state) VALUES(row_l.id,target,chosen_uid,actor,rid,'invited');
       END IF;
     END LOOP;
   END IF;
   lid:=row_l.id;
 ELSE
   IF jsonb_typeof(payload->'lobbyID') IS DISTINCT FROM 'string' OR coalesce(payload->>'lobbyID','') !~ pattern
   THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
   lid:=(payload->>'lobbyID')::uuid;
   SELECT * INTO row_l FROM bound_lobby_private.lobbies WHERE id=lid FOR UPDATE;
   IF NOT FOUND THEN RETURN '{"ok":false,"error":"forbidden"}'; END IF;
 END IF;
 stamp:=clock_timestamp();
 -- Re-check expiry after waiting for either serialization lock.
 IF NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=sid AND user_id=actor AND (not_after IS NULL OR not_after>stamp))
 THEN RETURN '{"ok":false,"error":"unauthorized"}'; END IF;
 IF NOT EXISTS(SELECT 1 FROM bound_lobby_private.members WHERE lobby=lid AND owner=actor) OR NOT bound_lobby_private.allowed(lid,actor)
 THEN RETURN '{"ok":false,"error":"forbidden"}'; END IF;
 -- Expired presence is a departure, never a pause for unrelated players.
 UPDATE bound_lobby_private.members SET state='left',ready=false WHERE lobby=lid AND state='joined' AND expires_at<=stamp;
 IF FOUND THEN
   UPDATE bound_lobby_private.lobbies SET revision=revision+1,updated_at=stamp WHERE id=lid;
   IF NOT EXISTS(SELECT 1 FROM bound_lobby_private.members WHERE lobby=lid AND owner=row_l.creator AND state='joined') THEN
     UPDATE bound_lobby_private.lobbies SET creator=(SELECT owner FROM bound_lobby_private.members WHERE lobby=lid AND state='joined' ORDER BY uid LIMIT 1) WHERE id=lid;
   END IF;
   SELECT * INTO row_l FROM bound_lobby_private.lobbies WHERE id=lid;
 END IF;
 SELECT * INTO row_m FROM bound_lobby_private.members WHERE lobby=lid AND owner=actor;
 IF NOT FOUND OR NOT bound_lobby_private.allowed(lid,actor) THEN RETURN '{"ok":false,"error":"forbidden"}'; END IF;
 IF action IN('get','decline') AND payload-'lobbyID'<>'{}'::jsonb
 THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
 IF action IN('accept','rejoin') AND payload-'lobbyID'-'runID'-'mode'-'partnerRoomID'<>'{}'::jsonb
 THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
 IF action IN('invite','configure','ready','start','leave','heartbeat','room') THEN
   IF coalesce(payload->>'memberToken','') !~ pattern THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
   IF row_m.member_token<>(payload->>'memberToken')::uuid OR row_m.session_id IS DISTINCT FROM sid
   THEN RETURN '{"ok":false,"error":"fenced"}'; END IF;
   IF action<>'leave' AND (row_m.state<>'joined' OR row_m.expires_at<=stamp)
   THEN RETURN '{"ok":false,"error":"membership_expired"}'; END IF;
   IF action IN('start','leave','heartbeat','room') AND payload-'lobbyID'-'memberToken'<>'{}'::jsonb
   OR action='ready' AND (payload-'lobbyID'-'memberToken'-'ready'<>'{}'::jsonb OR jsonb_typeof(payload->'ready') IS DISTINCT FROM 'boolean')
   OR action='invite' AND (payload-'lobbyID'-'memberToken'-'roomID'<>'{}'::jsonb OR coalesce(payload->>'roomID','') !~ pattern)
   OR action='configure' AND payload-'lobbyID'-'memberToken'-'runID'-'mode'-'partnerRoomID'<>'{}'::jsonb
   THEN RETURN '{"ok":false,"error":"invalid_request"}'; END IF;
 END IF;
 IF action IN('accept','rejoin','configure') THEN
   IF row_m.run_id IS NOT NULL AND (row_m.run_id IS DISTINCT FROM requested_run OR row_m.mode<>requested_mode OR row_m.partner IS DISTINCT FROM partner_id)
   THEN RETURN '{"ok":false,"error":"run_mismatch"}'; END IF;
   IF action='configure' THEN
     UPDATE bound_lobby_private.members SET mode=requested_mode,run_id=requested_run,partner=partner_id WHERE lobby=lid AND owner=actor;
     changed:=row_m.mode<>requested_mode OR row_m.run_id IS DISTINCT FROM requested_run OR row_m.partner IS DISTINCT FROM partner_id;
   ELSE
     IF row_m.state='declined' THEN RETURN '{"ok":false,"error":"invitation_declined"}'; END IF;
     IF row_m.state='joined' AND row_m.expires_at>stamp AND row_m.session_id IS DISTINCT FROM sid THEN RETURN '{"ok":false,"error":"member_held"}'; END IF;
     IF row_m.state<>'joined' OR row_m.expires_at<=stamp OR row_m.session_id IS DISTINCT FROM sid THEN
       UPDATE bound_lobby_private.members SET state='joined',ready=false,mode=requested_mode,run_id=requested_run,partner=partner_id,
       member_token=gen_random_uuid(),incarnation=gen_random_uuid(),generation=generation+1,session_id=sid,expires_at=stamp+interval '90 seconds' WHERE lobby=lid AND owner=actor;
       changed:=true;
     END IF;
   END IF;
 ELSIF action='decline' THEN
   IF row_m.state NOT IN('invited','declined') THEN RETURN '{"ok":false,"error":"invalid_state"}'; END IF;
   UPDATE bound_lobby_private.members SET state='declined',ready=false WHERE lobby=lid AND owner=actor;
   changed:=row_m.state<>'declined';
 ELSIF action='invite' THEN
   rid:=(payload->>'roomID')::uuid; target:=bound_lobby_private.friend(actor,rid);
   IF target IS NULL OR EXISTS(SELECT 1 FROM bound_lobby_private.members WHERE lobby=lid AND owner<>target AND NOT bound_lobby_private.eligible(target,owner))
   THEN RETURN '{"ok":false,"error":"invalid_friend"}'; END IF;
   IF NOT EXISTS(SELECT 1 FROM bound_lobby_private.members WHERE lobby=lid AND owner=target) THEN
     SELECT coalesce(max(uid),0)+1 INTO chosen_uid FROM bound_lobby_private.members WHERE lobby=lid;
     IF chosen_uid>4 THEN RETURN '{"ok":false,"error":"lobby_full"}'; END IF;
     INSERT INTO bound_lobby_private.members(lobby,owner,uid,inviter,friend_room,state) VALUES(lid,target,chosen_uid,actor,rid,'invited');
     changed:=true;
   ELSE
     -- Decline is explicit; a sender cannot silently re-add a declining player.
     IF EXISTS(SELECT 1 FROM bound_lobby_private.members WHERE lobby=lid AND owner=target AND state='declined')
     THEN RETURN '{"ok":false,"error":"invitation_declined"}'; END IF;
   END IF;
 ELSIF action='ready' THEN
   UPDATE bound_lobby_private.members SET ready=(payload->>'ready')::boolean WHERE lobby=lid AND owner=actor;
   changed:=row_m.ready IS DISTINCT FROM (payload->>'ready')::boolean;
 ELSIF action='start' THEN
   IF row_l.state<>'started' THEN
     IF row_l.creator IS DISTINCT FROM actor THEN RETURN '{"ok":false,"error":"not_creator"}'; END IF;
     IF (SELECT count(*) FROM bound_lobby_private.members WHERE lobby=lid AND state='joined')<2
     OR EXISTS(SELECT 1 FROM bound_lobby_private.members WHERE lobby=lid AND state='joined' AND (NOT ready OR expires_at<=stamp))
     THEN RETURN '{"ok":false,"error":"not_ready"}'; END IF;
     UPDATE bound_lobby_private.lobbies SET state='started' WHERE id=lid; changed:=true;
   END IF;
 ELSIF action='leave' THEN
   UPDATE bound_lobby_private.members SET state='left',ready=false,expires_at=stamp WHERE lobby=lid AND owner=actor;
   changed:=row_m.state<>'left';
   IF row_l.creator=actor THEN
     UPDATE bound_lobby_private.lobbies SET creator=(SELECT owner FROM bound_lobby_private.members WHERE lobby=lid AND state='joined' AND owner<>actor ORDER BY uid LIMIT 1) WHERE id=lid;
   END IF;
 END IF;
 IF action IN('create','accept','rejoin','configure','ready','start','invite','heartbeat') THEN
   UPDATE bound_lobby_private.members SET expires_at=stamp+interval '90 seconds' WHERE lobby=lid AND owner=actor AND state='joined';
   IF row_l.creator IS NULL THEN UPDATE bound_lobby_private.lobbies SET creator=actor WHERE id=lid; changed:=true; END IF;
 END IF;
 IF changed THEN UPDATE bound_lobby_private.lobbies SET revision=revision+1,updated_at=stamp WHERE id=lid; END IF;
 SELECT * INTO row_m FROM bound_lobby_private.members WHERE lobby=lid AND owner=actor;
 SELECT * INTO row_l FROM bound_lobby_private.lobbies WHERE id=lid;
 IF action='room' THEN
   SELECT jsonb_agg(jsonb_build_object('ownerID',m.owner,'uid',m.uid,'generation',m.generation::text,'sessionID',m.incarnation) ORDER BY m.uid) INTO rows_json
   FROM bound_lobby_private.members m WHERE m.lobby=lid AND m.state='joined' AND m.expires_at>stamp AND bound_lobby_private.allowed(lid,m.owner);
   RETURN jsonb_build_object('ok',true,'room',jsonb_build_object('lobbyID',lid,'channel','bound_lobby_'||replace(lid::text,'-',''),
   'uid',row_m.uid,'membershipRevision',row_l.revision::text,'members',rows_json,'partnerOwnerID',row_m.partner,
   'serverTime',extract(epoch FROM stamp),'expiresAt',extract(epoch FROM row_m.expires_at)));
 END IF;
 RETURN jsonb_build_object('ok',true,'lobby',bound_lobby_private.snapshot(lid),
 'memberToken',CASE WHEN action IN('create','accept','rejoin','configure','ready','start','invite','heartbeat') AND row_m.session_id=sid AND row_m.state='joined' THEN row_m.member_token ELSE NULL END,
 'serverTime',extract(epoch FROM stamp),'expiresAt',extract(epoch FROM row_m.expires_at));
EXCEPTION WHEN insufficient_privilege THEN RETURN '{"ok":false,"error":"unauthorized"}';
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA bound_lobby_private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION bound_lobby_private.dispatch(text,jsonb) TO authenticated;
CREATE FUNCTION public.bound_lobby_v1(action text,payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT bound_lobby_private.dispatch(action,payload) $$;
REVOKE ALL ON FUNCTION public.bound_lobby_v1(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bound_lobby_v1(text,jsonb) TO authenticated;
