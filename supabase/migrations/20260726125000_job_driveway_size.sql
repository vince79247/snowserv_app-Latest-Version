-- Driveway size captured at order time (#equipment, 2026-07-26): 'small' (1-2 car)
-- or 'large' (3+ car / extra-long). NULL when the order has no driveway, or for
-- legacy jobs. Used ONLY by qualification dispatch — a LARGE driveway soft-prefers
-- a snowblower/plow provider; small driveways stay open to everyone (incl. shovel).
-- Does NOT affect price. NULL/'small' both count as "not large", so dispatch always
-- errs toward keeping shovel-only providers eligible.
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS driveway_size text;
