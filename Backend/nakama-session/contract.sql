-- Additive authorization for the Nakama broker. Existing friend/account/lease
-- functions retain their definitions and permissions.
BEGIN;
CREATE FUNCTION bound_multiplayer_private.nakama_room_v1(payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' SET lock_timeout = '3s' AS $$
DECLARE
  actor uuid := auth.uid();
  claims jsonb := auth.jwt();
  session_id uuid;
  pairing cup050_private.rooms%rowtype;
  peer uuid;
  denied constant jsonb := '{"ok":false,"error":"forbidden"}'::jsonb;
  pattern constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
BEGIN
  IF actor IS NULL OR claims->>'role' IS DISTINCT FROM 'authenticated'
     OR coalesce(claims->>'session_id','') !~ pattern THEN RETURN denied; END IF;
  session_id := (claims->>'session_id')::uuid;
  PERFORM public.bound_require_mfa();
  PERFORM cup117_private.assert_active(actor);
  IF jsonb_typeof(payload) IS DISTINCT FROM 'object' OR octet_length(payload::text)>128
     OR payload-'roomID'<>'{}'::jsonb OR jsonb_typeof(payload->'roomID') IS DISTINCT FROM 'string'
     OR coalesce(payload->>'roomID','') !~ pattern THEN RETURN denied; END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id=actor AND u.deleted_at IS NULL
      AND u.is_anonymous IS FALSE AND u.email_confirmed_at IS NOT NULL) THEN RETURN denied; END IF;
  -- Follow the existing friend/deletion lock order; a membership change cannot
  -- race the authorization snapshot used to sign a short-lived admission ticket.
  PERFORM pg_advisory_xact_lock(505002026);
  PERFORM 1 FROM auth.sessions s WHERE s.id=session_id AND s.user_id=actor
    AND (s.not_after IS NULL OR s.not_after>clock_timestamp()) FOR KEY SHARE;
  IF NOT FOUND THEN RETURN denied; END IF;
  SELECT r.* INTO pairing FROM cup050_private.rooms r
    WHERE r.id=(payload->>'roomID')::uuid AND r.active AND actor IN(r.owner_a,r.owner_b) FOR KEY SHARE;
  IF NOT FOUND OR bound_moderation_private.denied_pair(pairing.owner_a,pairing.owner_b) THEN RETURN denied; END IF;
  peer := CASE WHEN pairing.owner_a=actor THEN pairing.owner_b ELSE pairing.owner_a END;
  PERFORM cup117_private.assert_active(peer);
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id=peer AND u.deleted_at IS NULL
      AND u.is_anonymous IS FALSE AND u.email_confirmed_at IS NOT NULL) THEN RETURN denied; END IF;
  RETURN jsonb_build_object('roomID',pairing.id,'ownerID',actor,'peerID',peer,
    'members',CASE WHEN pairing.owner_a<pairing.owner_b
      THEN jsonb_build_array(pairing.owner_a,pairing.owner_b)
      ELSE jsonb_build_array(pairing.owner_b,pairing.owner_a) END);
END $$;
REVOKE ALL ON FUNCTION bound_multiplayer_private.nakama_room_v1(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION bound_multiplayer_private.nakama_room_v1(jsonb) TO authenticated;

CREATE FUNCTION public.bound_nakama_room_v1(payload jsonb)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$
  SELECT bound_multiplayer_private.nakama_room_v1(payload)
$$;
REVOKE ALL ON FUNCTION public.bound_nakama_room_v1(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bound_nakama_room_v1(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
