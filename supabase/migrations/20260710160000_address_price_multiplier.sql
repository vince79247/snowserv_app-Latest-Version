-- Per-address custom pricing. When a provider reports that a specific property
-- is underpriced (huge driveway, long walkway, hard access), the admin sets a
-- multiplier on that saved address. It STACKS on top of the storm-depth surge:
--   final_price = zone base price × surge_multiplier × price_multiplier
-- Default 1.0 = normal pricing. Applies to FUTURE orders at that address
-- (an already-placed job's price/hold is locked in and unchanged).
ALTER TABLE addresses
  ADD COLUMN IF NOT EXISTS price_multiplier numeric NOT NULL DEFAULT 1.0;
