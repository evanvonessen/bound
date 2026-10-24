-- Completed legacy deletion receipts remain private historical evidence only.
-- They never enter deletion_jobs or any executable capability lookup.
CREATE TABLE bound_archive_private.deleted_records(
  source_table text NOT NULL REFERENCES bound_archive_private.catalog(source_table)
    CHECK(source_table IN('cup117_private.deletions','cup117_private.capabilities')),
  source_key text NOT NULL,
  -- These owners were already deleted, so deliberately do not reference users.
  owner uuid NOT NULL,
  source_row jsonb NOT NULL CHECK(jsonb_typeof(source_row)='object'),
  PRIMARY KEY(source_table,source_key)
);
CREATE INDEX ON bound_archive_private.deleted_records(owner);
REVOKE ALL ON bound_archive_private.deleted_records FROM PUBLIC,anon,authenticated;
