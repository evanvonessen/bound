CREATE TABLE cup117_private.deletion_jobs (
  token_hash text PRIMARY KEY CHECK(token_hash ~ '^[0-9a-f]{64}$'),
  owner uuid UNIQUE NOT NULL,
  complete boolean NOT NULL DEFAULT false,
  started_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON cup117_private.deletion_jobs FROM PUBLIC,anon,authenticated;
