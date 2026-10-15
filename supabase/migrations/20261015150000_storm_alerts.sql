-- Storm-window alerts to providers. Vince, 2026-10-15: "the providers need to
-- have some sense of when to be available for work... Frank should know to
-- toggle online."
--
-- THE PROBLEM. A provider only receives job offers while they are ONLINE.
-- Demand is concentrated in roughly 48–72 hours around a storm and is near zero
-- otherwise. So a provider who is offline during the window misses the season's
-- work, and one who stays online for weeks gets nothing and drifts away.
-- Nothing told them which it was: Frank has been is_online=true since September
-- with zero jobs and no way to know when it mattered.
--
-- THIS TABLE EXISTS ONLY TO STOP REPEAT ALERTS. The checker runs every few
-- hours and the forecast refines constantly, so without a dedupe key the same
-- storm would notify everybody on every tick and train them to ignore the one
-- notification that matters. One row per (zone, storm date).
CREATE TABLE IF NOT EXISTS public.storm_alerts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  zone_id            uuid NOT NULL REFERENCES public.service_areas(id) ON DELETE CASCADE,
  -- The local date of the heaviest forecast snowfall in the window. Stable
  -- enough to dedupe on as a forecast firms up, and readable in the admin panel.
  storm_date         date NOT NULL,
  forecast_inches    numeric,
  providers_notified int  NOT NULL DEFAULT 0,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (zone_id, storm_date)
);

ALTER TABLE public.storm_alerts ENABLE ROW LEVEL SECURITY;

-- Admin reads it (so the panel can show "we told them"); only the service role
-- writes. Same shape as email_log: no insert policy at all, so a client cannot
-- fabricate a record of having warned somebody.
DROP POLICY IF EXISTS storm_alerts_admin_select ON public.storm_alerts;
CREATE POLICY storm_alerts_admin_select ON public.storm_alerts
  FOR SELECT TO authenticated USING (public.is_admin());

-- How much forecast snow counts as a storm worth waking people for. Below the
-- 3" band storm pricing stays at 1.0x, but 2" still fills driveways and makes
-- real work, so the alert threshold sits below the surge threshold on purpose.
INSERT INTO public.app_settings (key, value)
VALUES ('storm_alert_min_inches', '2')
ON CONFLICT (key) DO NOTHING;

-- How far ahead to look. 72h matches what Vince asked for — "maybe even up to
-- seventy-two hours" — and gives somebody time to arrange their day.
INSERT INTO public.app_settings (key, value)
VALUES ('storm_alert_lookahead_hours', '72')
ON CONFLICT (key) DO NOTHING;
