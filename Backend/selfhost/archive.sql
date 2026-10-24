-- Durable, private copies of historical objects. These are not temporary
-- multiplayer transfers and have no expiry or age-based cleanup.
CREATE SCHEMA bound_archive_private;
REVOKE ALL ON SCHEMA bound_archive_private FROM PUBLIC,anon,authenticated;
CREATE TABLE bound_archive_private.objects(
  id uuid PRIMARY KEY,
  -- Keep the disk receipt after Nakama deletes its account; purge bytes first.
  owner uuid NOT NULL,
  project_ref text NOT NULL CHECK(length(project_ref) BETWEEN 1 AND 128),
  bucket text NOT NULL CHECK(bucket IN('bound-roms','cup040-saves','cup071-covers')),
  name text NOT NULL CHECK(split_part(name,'/',1)=owner::text AND length(name)>37),
  source_id uuid NOT NULL,
  source_version text,
  source_updated_at timestamptz,
  source_row jsonb NOT NULL CHECK(jsonb_typeof(source_row)='object'),
  size bigint NOT NULL CHECK(size>=0 AND size<=9007199254740991),
  sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'),
  state text NOT NULL DEFAULT 'staged' CHECK(state IN('staged','ready')),
  imported_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(project_ref,bucket,name)
);
CREATE INDEX ON bound_archive_private.objects(owner,id);
-- Original column types and primary-key order accompany textual SQL values, so
-- historical records can be restored without JSON number/timestamp coercion.
CREATE TABLE bound_archive_private.catalog(
  source_table text PRIMARY KEY,
  source_columns jsonb NOT NULL,
  source_primary_key jsonb NOT NULL
);
CREATE TABLE bound_archive_private.records(
  source_table text NOT NULL REFERENCES bound_archive_private.catalog(source_table),
  source_key text NOT NULL,
  owner uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  source_row jsonb NOT NULL CHECK(jsonb_typeof(source_row)='object'),
  PRIMARY KEY(source_table,source_key)
);
CREATE INDEX ON bound_archive_private.records(owner);
REVOKE ALL ON ALL TABLES IN SCHEMA bound_archive_private FROM PUBLIC,anon,authenticated;
