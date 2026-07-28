-- Provider equipment, for qualification-based dispatch (#equipment, 2026-07-26).
--   shovel     = hand tools only (walkways/sidewalks; a driveway by hand is slow)
--   snowblower = motorized, handles driveways + walkways
--   plow       = plow truck, handles driveways + lots
-- dispatch_jobs() SOFT-prefers snowblower/plow for any job that includes a
-- driveway, but never hard-excludes anyone — a job is never stranded. Only an
-- EXPLICIT 'shovel' provider is deprioritized (and only on driveway jobs).
-- NULL = a provider who registered before this field → treated as capable, so
-- existing providers' routing does not regress.
ALTER TABLE providers ADD COLUMN IF NOT EXISTS equipment text;

-- Backfill legacy providers who declared a vehicle as plow owners, so they keep
-- (and are explicitly marked for) driveway work. Everyone else stays NULL (capable).
UPDATE providers SET equipment = 'plow'
  WHERE equipment IS NULL AND has_vehicle = true;
