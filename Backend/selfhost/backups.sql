-- Private, opt-in game-save backups. Approval is server-managed and keyed to a
-- verified email once, then bound to that Nakama owner; usernames grant nothing.
CREATE SCHEMA bound_backups_private;
REVOKE ALL ON SCHEMA bound_backups_private FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE bound_backups_private.approvals(
  email text PRIMARY KEY CHECK(email=lower(email) AND length(email) BETWEEN 3 AND 320),
  owner uuid UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  approved boolean NOT NULL DEFAULT true,
  revision uuid NOT NULL DEFAULT gen_random_uuid(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bound_backups_private.preferences(
  owner uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  provider text NOT NULL DEFAULT 'dropbox' CHECK(provider IN('none','dropbox','server')),
  revision uuid NOT NULL DEFAULT gen_random_uuid()
);
-- No cascading FK: disk receipts must survive account deletion until bytes are
-- removed successfully. Backups contain opaque save ZIPs, never extracted ROMs.
CREATE TABLE bound_backups_private.objects(
  version uuid PRIMARY KEY,
  owner uuid NOT NULL,
  game_id text NOT NULL CHECK(game_id ~ '^[A-Za-z0-9_-]{1,128}$'),
  name text NOT NULL CHECK(length(name) BETWEEN 1 AND 256),
  size bigint NOT NULL CHECK(size>0),
  sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
  state text NOT NULL CHECK(state IN('uploading','ready')),
  modified_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ON bound_backups_private.objects(owner,game_id,modified_at DESC,version DESC);
REVOKE ALL ON ALL TABLES IN SCHEMA bound_backups_private FROM PUBLIC,anon,authenticated,service_role;
