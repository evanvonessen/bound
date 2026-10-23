-- Preserved Bound friend behavior from the recorded production definition.
-- Used only to initialize the new self-hosted database.
CREATE OR REPLACE FUNCTION public.cup050_friends(action text, payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
DECLARE actor uuid:=auth.uid(); peer uuid; pairing cup050_private.rooms%rowtype; answer jsonb; item jsonb; safe_rooms jsonb:='[]';
 denied constant jsonb:='{"ok":false}'::jsonb;
BEGIN
 PERFORM cup117_private.assert_active(actor);
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=actor AND NOT is_anonymous AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL) THEN RETURN denied; END IF;
 IF payload IS NULL OR jsonb_typeof(payload)<>'object' OR octet_length(payload::text)>512 THEN RETURN denied; END IF;
 IF action IN ('report','block','unblock') THEN RETURN bound_moderation_private.action(action,payload); END IF;
 IF action NOT IN ('create','accept','list','room','remove') THEN RETURN denied; END IF;
 PERFORM pg_advisory_xact_lock(505002026);
 IF EXISTS(SELECT 1 FROM bound_moderation_private.suspensions WHERE owner=actor) THEN RETURN denied; END IF;
 IF action IN ('create','accept') AND NOT bound_moderation_private.clean_name(payload->>'displayName') THEN RETURN jsonb_build_object('ok',false,'error','name_not_allowed'); END IF;
 IF action='accept' THEN
  SELECT creator INTO peer FROM cup050_private.invites WHERE digest=extensions.digest(upper(btrim(payload->>'code')),'sha256');
  IF peer IS NOT NULL AND bound_moderation_private.denied_pair(actor,peer) THEN RETURN denied; END IF;
 ELSIF action='room' THEN
  IF coalesce(payload->>'roomID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN denied; END IF;
  SELECT * INTO pairing FROM cup050_private.rooms WHERE id=(payload->>'roomID')::uuid AND active AND actor IN(owner_a,owner_b);
  IF NOT FOUND OR bound_moderation_private.denied_pair(pairing.owner_a,pairing.owner_b) THEN RETURN denied; END IF;
 END IF;
 answer:=cup050_private.bound_friend_service_v1(action,payload);
 IF answer->>'ok'<>'true' THEN RETURN answer; END IF;
 IF action='list' THEN
  -- Hide unsafe legacy labels without removing the ability to report or block.
  FOR item IN SELECT value FROM jsonb_array_elements(answer->'rooms') LOOP
   SELECT * INTO pairing FROM cup050_private.rooms WHERE id=(item->>'roomID')::uuid AND actor IN(owner_a,owner_b);
   IF FOUND AND NOT bound_moderation_private.denied_pair(pairing.owner_a,pairing.owner_b) THEN
    safe_rooms:=safe_rooms||jsonb_build_array(jsonb_build_object('roomID',item->>'roomID','displayName',bound_moderation_private.label(item->>'displayName')));
   END IF;
  END LOOP;
  answer:=jsonb_set(answer,'{rooms}',safe_rooms);
  answer:=answer||jsonb_build_object('blocks',bound_moderation_private.block_list(actor));
 ELSIF action='accept' THEN
  answer:=jsonb_set(answer,'{room,displayName}',to_jsonb(bound_moderation_private.label(answer->'room'->>'displayName')));
 END IF;
 RETURN answer;
END; $function$;


CREATE OR REPLACE FUNCTION cup050_private.bound_friend_service_v1(action text, payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
declare
  actor uuid := auth.uid(); stamp timestamptz := clock_timestamp();
  quota cup050_private.limits%rowtype; invitation cup050_private.invites%rowtype;
  pairing cup050_private.rooms%rowtype; nickname text; code text; selected uuid;
  result jsonb; denied constant jsonb := '{"ok":false}'::jsonb;
begin
  perform cup117_private.assert_active(actor);
  -- JWT identity alone is insufficient: consult the current account on each call.
  if actor is null or not exists (select 1 from auth.users u where u.id=actor
      and u.is_anonymous=false and u.email_confirmed_at is not null and u.deleted_at is null) then return denied; end if;
  if action is null or action not in ('create','accept','list','room','remove') or payload is null
      or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>512 then return denied; end if;
  -- A bounded waiting lock serializes this development feature; ordinary
  -- concurrent renewals wait rather than receiving a false authorization denial.
  -- It also prevents cross-owner room-count races without lock-order deadlocks.
  perform pg_advisory_xact_lock(505002026);
  insert into cup050_private.limits(owner,window_start) values(actor,stamp) on conflict do nothing;
  select * into quota from cup050_private.limits where owner=actor for update;
  if stamp-quota.window_start >= interval '1 hour' then
    update cup050_private.limits set window_start=stamp,requests=0,creates=0,guesses=0 where owner=actor;
    quota.requests:=0; quota.creates:=0; quota.guesses:=0;
  end if;
  if quota.requests>=240 then return denied; end if;
  update cup050_private.limits set requests=requests+1 where owner=actor;
  if action='create' then
    if jsonb_typeof(payload->'displayName') is distinct from 'string' or payload- 'displayName'<>'{}'::jsonb or quota.creates>=5 then return denied; end if;
    update cup050_private.limits set creates=creates+1 where owner=actor;
    nickname:=btrim(payload->>'displayName');
    if nickname is null or char_length(nickname) not between 1 and 40 or nickname ~ '[[:cntrl:]]' then return denied; end if;
    if (select count(*) from cup050_private.rooms where active and actor in (owner_a,owner_b))>=20 then return denied; end if;
    -- Only the newest code is outstanding. Never retain plaintext codes.
    update cup050_private.invites set consumed=true where creator=actor and not consumed;
    code:=upper(encode(extensions.gen_random_bytes(8),'hex'));
    insert into cup050_private.invites(digest,creator,display_name,expires_at)
      values(extensions.digest(code,'sha256'),actor,nickname,stamp+interval '10 minutes');
    return jsonb_build_object('ok',true,'code',code,'expiresAt',stamp+interval '10 minutes');
  elsif action='accept' then
    if jsonb_typeof(payload->'displayName') is distinct from 'string' or jsonb_typeof(payload->'code') is distinct from 'string' or payload- 'code'- 'displayName'<>'{}'::jsonb or quota.guesses>=10 then return denied; end if;
    -- Return denials rather than raising: invalid guesses commit their quota.
    update cup050_private.limits set guesses=guesses+1 where owner=actor;
    code:=upper(btrim(payload->>'code')); nickname:=btrim(payload->>'displayName');
    if code is null or code !~ '^[0-9A-F]{16}$' or nickname is null
       or char_length(nickname) not between 1 and 40 or nickname ~ '[[:cntrl:]]' then return denied; end if;
    select * into invitation from cup050_private.invites where digest=extensions.digest(code,'sha256') for update;
    if found then perform cup117_private.assert_active(invitation.creator); end if;
    if invitation.creator is null or invitation.consumed or invitation.expires_at<=stamp or invitation.creator=actor then return denied; end if;
    if not exists(select 1 from auth.users u where u.id=invitation.creator and u.is_anonymous=false and u.email_confirmed_at is not null and u.deleted_at is null) then return denied; end if;
    if exists(select 1 from cup050_private.rooms where active and ((owner_a=actor and owner_b=invitation.creator) or (owner_b=actor and owner_a=invitation.creator))) then return denied; end if;
    if (select count(*) from cup050_private.rooms where active and actor in (owner_a,owner_b))>=20
       or (select count(*) from cup050_private.rooms where active and invitation.creator in (owner_a,owner_b))>=20 then return denied; end if;
    insert into cup050_private.rooms(owner_a,owner_b,name_a,name_b) values(invitation.creator,actor,invitation.display_name,nickname) returning * into pairing;
    update cup050_private.invites set consumed=true where digest=invitation.digest;
    return jsonb_build_object('ok',true,'room',jsonb_build_object('roomID',pairing.id,'displayName',pairing.name_a));
  elsif action='list' then
    if payload<>'{}'::jsonb then return denied; end if;
    select coalesce(jsonb_agg(jsonb_build_object('roomID',r.id,'displayName',case when r.owner_a=actor then r.name_b else r.name_a end) order by r.id),'[]'::jsonb)
      into result from cup050_private.rooms r where r.active and actor in(r.owner_a,r.owner_b);
    return jsonb_build_object('ok',true,'rooms',result);
  else
    if jsonb_typeof(payload->'roomID') is distinct from 'string' or payload- 'roomID'<>'{}'::jsonb or coalesce(payload->>'roomID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return denied; end if;
    selected:=(payload->>'roomID')::uuid;
    select * into pairing from cup050_private.rooms where id=selected and active and actor in(owner_a,owner_b) for update;
    if not found then return denied; end if;
    perform cup117_private.assert_active(pairing.owner_a);
    perform cup117_private.assert_active(pairing.owner_b);
    if action='remove' then
      update cup050_private.rooms set active=false where id=selected;
      return jsonb_build_object('ok',true);
    end if;
    return jsonb_build_object('ok',true,'room',jsonb_build_object('roomID',pairing.id,
      'channel','cup050_'||replace(pairing.id::text,'-',''),
      'uid',case when pairing.owner_a=actor then 1 else 2 end,
      'remoteUID',case when pairing.owner_a=actor then 2 else 1 end));
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public.cup050_friends(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cup050_friends(text,jsonb) TO authenticated;
