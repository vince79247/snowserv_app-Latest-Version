-- Admin-editable storm pricing. Moves the snow-depth -> multiplier ladder out of
-- hardcoded code (kStormBands in customer_home.dart + STORM_BANDS in the
-- create-checkout-session function) and into app_settings, so the admin can tune
-- BOTH the depth increments AND the multipliers from the panel without a rebuild.
--
-- Stored as a JSON array of {min, mult}, ascending by min, first band min=0 (the
-- standard/1.0x baseline). The client (AppConfig.stormBands) and the server
-- (create-checkout-session) both read this same row, so the price shown always
-- equals the price charged. Both fall back to the same hardcoded default on any
-- parse problem, so a bad value can never break pricing.
--
-- Seeds the current Yonkers-launch ladder: 0-3" 1.0x, 3-6" 1.3x, 6-10" 1.7x, 10"+ 2.3x.
INSERT INTO app_settings (key, value) VALUES
  ('storm_bands', '[{"min":0,"mult":1.0},{"min":3,"mult":1.3},{"min":6,"mult":1.7},{"min":10,"mult":2.3}]')
  ON CONFLICT (key) DO NOTHING;
