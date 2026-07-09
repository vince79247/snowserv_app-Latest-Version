-- Editable business config (starting with the platform commission %) so the
-- admin can tune it from the app without a code change. Key/value so future
-- settings slot in without schema changes.
CREATE TABLE IF NOT EXISTS app_settings (
  key text PRIMARY KEY,
  value text NOT NULL,
  updated_at timestamptz DEFAULT now()
);

-- Seed the current commission (30%). Stored as a percentage for readability;
-- provider take = 100 - this.
INSERT INTO app_settings (key, value) VALUES ('commission_pct', '30')
  ON CONFLICT (key) DO NOTHING;

ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

-- Readable by everyone (the pre-login FAQ / quote may want it too).
DROP POLICY IF EXISTS app_settings_read ON app_settings;
CREATE POLICY app_settings_read ON app_settings FOR SELECT USING (true);

-- Only admins can change settings.
DROP POLICY IF EXISTS app_settings_admin_write ON app_settings;
CREATE POLICY app_settings_admin_write ON app_settings FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.is_admin = true))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.is_admin = true));

GRANT SELECT ON app_settings TO anon, authenticated;
GRANT INSERT, UPDATE ON app_settings TO authenticated;
GRANT ALL ON app_settings TO service_role;
