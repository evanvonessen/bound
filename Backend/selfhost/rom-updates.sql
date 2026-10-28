-- Applied exactly once by migrate.mjs, in the same transaction as its receipt.
-- Approval is account UUID scoped and independent of backup or client toggles.
CREATE SCHEMA bound_developer_private;
REVOKE ALL ON SCHEMA bound_developer_private FROM PUBLIC,anon,authenticated;
CREATE TABLE bound_developer_private.approvals (
  owner uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  approved boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON bound_developer_private.approvals FROM PUBLIC,anon,authenticated;

-- Define the initial cohort at migration execution, excluding Nakama's system
-- user. Blocking inserts until commit prevents ambiguous registration races.
LOCK TABLE public.users IN SHARE MODE;
INSERT INTO bound_developer_private.approvals(owner,approved)
  SELECT id,true FROM public.users WHERE id<>'00000000-0000-0000-0000-000000000000';
-- No signup trigger or default grant: future accounts have no approval row.
