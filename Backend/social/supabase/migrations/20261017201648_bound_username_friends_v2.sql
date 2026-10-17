-- Additive case-insensitive usernames and friend-by-name support.
-- The Build 13 cup050_friends and bound_social_v1 definitions remain unchanged.
BEGIN;

CREATE SCHEMA bound_username_private;
REVOKE ALL ON SCHEMA bound_username_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA bound_username_private TO anon, authenticated;

-- Existing profiles remain as-is. This index is the authoritative race-safe
-- uniqueness rule for all newly claimed and lazily materialized names.
CREATE UNIQUE INDEX profiles_username_casefold_uidx
  ON bound_social_private.profiles (lower(btrim(username)));

-- Preserve legacy profile discovery while assigning a deterministic fallback
-- when an old metadata/room label is already claimed by a different account.
CREATE OR REPLACE FUNCTION bound_social_private.ensure_profile(actor uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE selected text; generated_base text; suffix integer:=0;
BEGIN
  IF actor IS NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(505002026);
  SELECT username INTO selected FROM bound_social_private.profiles WHERE owner=actor;
  IF FOUND THEN RETURN selected; END IF;
  SELECT CASE WHEN bound_moderation_private.clean_name(u.raw_user_meta_data->>'cupcake_username_v1')
    THEN btrim(u.raw_user_meta_data->>'cupcake_username_v1') END
    INTO selected FROM auth.users u WHERE u.id=actor AND u.deleted_at IS NULL;
  IF selected IS NULL THEN
    SELECT CASE WHEN bound_moderation_private.clean_name(candidate) THEN btrim(candidate) END
      INTO selected
      FROM (
        SELECT CASE WHEN owner_a=actor THEN name_a ELSE name_b END AS candidate
        FROM cup050_private.rooms
        WHERE actor IN(owner_a,owner_b)
        ORDER BY id
      ) names
      WHERE bound_moderation_private.clean_name(candidate)
      LIMIT 1;
  END IF;
  IF selected IS NULL OR NOT bound_social_private.username_is_available(selected,actor) THEN
    generated_base:='Player_'||left(replace(actor::text,'-',''),8);
    selected:=generated_base;
    WHILE NOT bound_social_private.username_is_available(selected,actor) LOOP
      suffix:=suffix+1;
      selected:=generated_base||'_'||suffix::text;
      IF suffix>100000 THEN RAISE EXCEPTION 'unable to allocate unique fallback username'; END IF;
    END LOOP;
  END IF;
  INSERT INTO bound_social_private.profiles(owner,username) VALUES(actor,selected)
    ON CONFLICT(owner) DO NOTHING;
  SELECT username INTO selected FROM bound_social_private.profiles WHERE owner=actor;
  RETURN selected;
END $$;

CREATE FUNCTION bound_social_private.username_is_available(candidate text, excluded_owner uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT bound_moderation_private.clean_name(candidate)
    AND NOT EXISTS (
      SELECT 1 FROM bound_social_private.profiles p
      WHERE lower(btrim(p.username))=lower(btrim(candidate))
        AND (excluded_owner IS NULL OR p.owner<>excluded_owner)
    )
    AND (
      (excluded_owner IS NOT NULL AND EXISTS (
        SELECT 1 FROM bound_social_private.profiles p
        WHERE p.owner=excluded_owner AND lower(btrim(p.username))=lower(btrim(candidate))
      ))
      OR NOT EXISTS (
        SELECT 1 FROM auth.users u
        WHERE u.id IS DISTINCT FROM excluded_owner
          AND u.deleted_at IS NULL AND NOT u.is_anonymous
          AND u.email_confirmed_at IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM bound_social_private.profiles p WHERE p.owner=u.id)
          AND bound_moderation_private.clean_name(u.raw_user_meta_data->>'cupcake_username_v1')
          AND lower(btrim(u.raw_user_meta_data->>'cupcake_username_v1'))=lower(btrim(candidate))
      )
    )
$$;
REVOKE ALL ON FUNCTION bound_social_private.username_is_available(text,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bound_social_private.ensure_profile(uuid) FROM PUBLIC, anon, authenticated;

-- New signups opt in by supplying bound_username_v1 in Auth user metadata.
-- Legacy Build 13 signups without that key pass through untouched.
CREATE FUNCTION bound_social_private.claim_signup_username() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE requested text;
BEGIN
  IF NOT (coalesce(NEW.raw_user_meta_data,'{}'::jsonb) ? 'bound_username_v1') THEN
    RETURN NEW;
  END IF;
  IF jsonb_typeof(NEW.raw_user_meta_data->'bound_username_v1') IS DISTINCT FROM 'string' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='name_not_allowed';
  END IF;
  requested:=btrim(NEW.raw_user_meta_data->>'bound_username_v1');
  IF NOT bound_moderation_private.clean_name(requested) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='name_not_allowed';
  END IF;
  IF coalesce(NEW.is_anonymous,false) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='name_not_allowed';
  END IF;
  PERFORM pg_advisory_xact_lock(505002026);
  IF NOT bound_social_private.username_is_available(requested,NEW.id) THEN
    RAISE EXCEPTION USING ERRCODE='23505', MESSAGE='username_taken';
  END IF;
  INSERT INTO bound_social_private.profiles(owner,username) VALUES(NEW.id,requested);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION bound_social_private.claim_signup_username() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER bound_claim_signup_username
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION bound_social_private.claim_signup_username();

CREATE FUNCTION bound_username_private.available(username text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE normalized text;
BEGIN
  IF NOT bound_moderation_private.clean_name(username) THEN
    RETURN jsonb_build_object('ok',false,'available',false,'error','name_not_allowed');
  END IF;
  normalized:=btrim(username);
  RETURN jsonb_build_object('ok',true,
    'available',bound_social_private.username_is_available(normalized,NULL));
END $$;
REVOKE ALL ON FUNCTION bound_username_private.available(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bound_username_private.available(text) TO anon, authenticated;

CREATE FUNCTION bound_username_private.name_available(candidate text, excluded_owner uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT bound_moderation_private.clean_name(candidate) THEN RETURN NULL; END IF;
  IF excluded_owner IS NULL OR auth.uid() IS DISTINCT FROM excluded_owner THEN RETURN false; END IF;
  RETURN bound_social_private.username_is_available(candidate,excluded_owner);
END $$;
REVOKE ALL ON FUNCTION bound_username_private.name_available(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bound_username_private.name_available(text,uuid) TO authenticated;

CREATE FUNCTION public.bound_username_available(username text) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
  SELECT bound_username_private.available(username)
$$;
REVOKE ALL ON FUNCTION public.bound_username_available(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bound_username_available(text) TO anon, authenticated;

CREATE FUNCTION bound_username_private.social_add(payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE actor uuid:=auth.uid(); stamp timestamptz:=clock_timestamp(); profile_name text;
        requested text; lookup_key text; candidate_count integer; peer uuid;
        pairing cup050_private.rooms%rowtype; result jsonb; quota cup050_private.limits%rowtype;
BEGIN
  PERFORM cup117_private.assert_active(actor);
  IF actor IS NULL OR NOT EXISTS(
    SELECT 1 FROM auth.users u WHERE u.id=actor AND NOT u.is_anonymous
      AND u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL
  ) THEN RETURN jsonb_build_object('ok',false); END IF;
  IF payload IS NULL OR jsonb_typeof(payload)<>'object' OR payload-'username'<>'{}'::jsonb
     OR jsonb_typeof(payload->'username') IS DISTINCT FROM 'string'
     OR octet_length(payload::text)>512 THEN RETURN jsonb_build_object('ok',false); END IF;
  requested:=btrim(payload->>'username');
  IF NOT bound_moderation_private.clean_name(requested) THEN
    RETURN jsonb_build_object('ok',false,'error','name_not_allowed');
  END IF;

  PERFORM pg_advisory_xact_lock(505002026);
  profile_name:=bound_social_private.ensure_profile(actor);
  lookup_key:=lower(requested);

  -- Resolve already-materialized usernames first, then support a legacy
  -- account's saved Build 13 name only when no profile owns the name.
  -- Charge every attempted lookup before returning any username-dependent
  -- result, matching the legacy bounded-guess behavior for invite codes.
  INSERT INTO cup050_private.limits(owner,window_start) VALUES(actor,stamp) ON CONFLICT DO NOTHING;
  SELECT * INTO quota FROM cup050_private.limits WHERE owner=actor FOR UPDATE;
  IF stamp-quota.window_start>=interval '1 hour' THEN
    UPDATE cup050_private.limits SET window_start=stamp,requests=0,creates=0,guesses=0 WHERE owner=actor;
    quota.requests:=0; quota.creates:=0; quota.guesses:=0;
  END IF;
  IF quota.requests>=240 OR quota.guesses>=10 THEN
    RETURN jsonb_build_object('ok',false,'error','rate_limited');
  END IF;
  UPDATE cup050_private.limits SET requests=requests+1,guesses=guesses+1 WHERE owner=actor;

  -- Materialized profiles are authoritative. Consult legacy metadata only
  -- when no profile currently owns the requested normalized name.
  SELECT count(*) INTO candidate_count
  FROM bound_social_private.profiles p
  JOIN auth.users u ON u.id=p.owner
  WHERE u.deleted_at IS NULL AND NOT u.is_anonymous AND u.email_confirmed_at IS NOT NULL
    AND lower(btrim(p.username))=lookup_key;
  IF candidate_count>1 THEN RETURN jsonb_build_object('ok',false,'error','friend_not_found'); END IF;
  IF candidate_count=1 THEN
    SELECT p.owner INTO peer FROM bound_social_private.profiles p
    JOIN auth.users u ON u.id=p.owner
    WHERE u.deleted_at IS NULL AND NOT u.is_anonymous AND u.email_confirmed_at IS NOT NULL
      AND lower(btrim(p.username))=lookup_key
    ORDER BY p.owner LIMIT 1;
  ELSE
    SELECT count(*) INTO candidate_count
    FROM auth.users u
    WHERE u.deleted_at IS NULL AND NOT u.is_anonymous AND u.email_confirmed_at IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM bound_social_private.profiles p WHERE p.owner=u.id)
      AND bound_moderation_private.clean_name(u.raw_user_meta_data->>'cupcake_username_v1')
      AND lower(btrim(u.raw_user_meta_data->>'cupcake_username_v1'))=lookup_key;
    IF candidate_count=0 OR candidate_count>1 THEN
      RETURN jsonb_build_object('ok',false,'error','friend_not_found');
    END IF;
    SELECT u.id INTO peer FROM auth.users u
    WHERE u.deleted_at IS NULL AND NOT u.is_anonymous AND u.email_confirmed_at IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM bound_social_private.profiles p WHERE p.owner=u.id)
      AND bound_moderation_private.clean_name(u.raw_user_meta_data->>'cupcake_username_v1')
      AND lower(btrim(u.raw_user_meta_data->>'cupcake_username_v1'))=lookup_key
    ORDER BY u.id LIMIT 1;
  END IF;
  IF peer=actor THEN RETURN jsonb_build_object('ok',false,'error','cannot_add_self'); END IF;
  PERFORM cup117_private.assert_active(peer);
  IF bound_moderation_private.denied_pair(actor,peer) THEN
    RETURN jsonb_build_object('ok',false,'error','friend_not_found');
  END IF;

  profile_name:=bound_social_private.ensure_profile(actor);
  requested:=bound_social_private.ensure_profile(peer);
  IF lower(btrim(requested))<>lookup_key THEN
    RETURN jsonb_build_object('ok',false,'error','friend_not_found');
  END IF;

  -- Repeated taps return the existing relationship without creating another.
  SELECT * INTO pairing FROM cup050_private.rooms r WHERE r.active
    AND ((r.owner_a=actor AND r.owner_b=peer) OR (r.owner_b=actor AND r.owner_a=peer))
    ORDER BY r.id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok',true,'username',profile_name,
      'room',jsonb_build_object('roomID',pairing.id,'displayName',requested));
  END IF;

  INSERT INTO cup050_private.limits(owner,window_start) VALUES(actor,stamp) ON CONFLICT DO NOTHING;
  SELECT * INTO quota FROM cup050_private.limits WHERE owner=actor FOR UPDATE;
  IF stamp-quota.window_start>=interval '1 hour' THEN
    UPDATE cup050_private.limits SET window_start=stamp,requests=0,creates=0,guesses=0 WHERE owner=actor;
    quota.requests:=0; quota.creates:=0; quota.guesses:=0;
  END IF;
  IF quota.creates>=5 THEN
    RETURN jsonb_build_object('ok',false,'error','rate_limited');
  END IF;
  UPDATE cup050_private.limits SET creates=creates+1 WHERE owner=actor;
  IF (SELECT count(*) FROM cup050_private.rooms WHERE active AND actor IN(owner_a,owner_b))>=20
     OR (SELECT count(*) FROM cup050_private.rooms WHERE active AND peer IN(owner_a,owner_b))>=20 THEN
    RETURN jsonb_build_object('ok',false,'error','friend_limit');
  END IF;
  INSERT INTO cup050_private.rooms(owner_a,owner_b,name_a,name_b)
    VALUES(actor,peer,profile_name,requested) RETURNING * INTO pairing;
  RETURN jsonb_build_object('ok',true,'username',profile_name,
    'room',jsonb_build_object('roomID',pairing.id,'displayName',requested));
END $$;
REVOKE ALL ON FUNCTION bound_username_private.social_add(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bound_username_private.social_add(jsonb) TO authenticated;

CREATE FUNCTION public.bound_social_v2(action text, payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE can_use boolean;
BEGIN
  IF action='add' THEN RETURN bound_username_private.social_add(payload); END IF;
  IF action='username' AND jsonb_typeof(payload->'username')='string' THEN
    PERFORM pg_advisory_xact_lock(505002026);
    can_use:=bound_username_private.name_available(btrim(payload->>'username'),auth.uid());
    IF can_use IS FALSE THEN
      RETURN jsonb_build_object('ok',false,'error','username_taken');
    END IF;
    BEGIN
      RETURN public.bound_social_v1(action,payload);
    EXCEPTION WHEN unique_violation THEN
      RETURN jsonb_build_object('ok',false,'error','username_taken');
    END;
  END IF;
  RETURN public.bound_social_v1(action,payload);
END $$;
REVOKE ALL ON FUNCTION public.bound_social_v2(text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bound_social_v2(text,jsonb) TO authenticated;

COMMIT;
