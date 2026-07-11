-- Short, human-friendly provider number (mirrors jobs.job_number) so the admin
-- can tell same-name providers apart at a glance ("John Doe #7"). The UUID id
-- stays the real key — this is display-only. Auto-assigned off a sequence:
-- existing providers are backfilled in sign-up order, and new providers get the
-- next number via the column default (no change needed in the registration code).

CREATE SEQUENCE IF NOT EXISTS provider_number_seq;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS provider_number int;

-- Backfill existing rows in creation order (stable: created_at then id).
UPDATE providers p SET provider_number = s.rn
FROM (
  SELECT id, row_number() OVER (ORDER BY created_at, id) AS rn FROM providers
) s
WHERE p.id = s.id AND p.provider_number IS NULL;

-- Advance the sequence past the highest assigned so the NEXT new provider is
-- max+1. is_called=true when providers already exist; if the table is empty,
-- start the sequence at 1 (is_called=false).
SELECT setval(
  'provider_number_seq',
  GREATEST((SELECT COALESCE(max(provider_number), 0) FROM providers), 1),
  (SELECT count(*) FROM providers) > 0
);

ALTER TABLE providers ALTER COLUMN provider_number SET DEFAULT nextval('provider_number_seq');
