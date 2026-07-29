-- Provider registration failed at Submit with 23514 (check_violation), immediately
-- after the storage-policy fix unblocked the photo upload. Second wall, same path.
--
-- Cause: providers_provider_type_check required provider_type IN ('driver','shoveler')
-- — the ORIGINAL capability vocabulary. But the registration form's "Provider Type"
-- dropdown is really a CREW SIZE picker and writes 'solo' / 'small_crew' /
-- 'large_crew' (and separately, correctly, sets crew_size). So every submit was
-- rejected by the database.
--
-- Why dropping it is safe: provider_type is now VESTIGIAL. Capability moved to
-- providers.equipment (shovel/snowblower/plow, 2026-07-26) and the live dispatch_jobs()
-- does not reference provider_type at all. All existing providers have it NULL, so the
-- constraint has never actually guarded a real value. Keeping a stale constraint that
-- blocks 100% of provider signups is pure downside.
--
-- Follow-up (client, next build): stop writing the crew value into provider_type —
-- write a derived 'driver'/'shoveler' instead (crew size already lives in crew_size).
-- This migration is what lets ALREADY-INSTALLED builds submit in the meantime.

alter table public.providers drop constraint if exists providers_provider_type_check;

comment on column public.providers.provider_type is
  'VESTIGIAL legacy capability field (was driver|shoveler). Dispatch uses '
  'providers.equipment instead. Kept for historical rows; do not add new logic on it.';
