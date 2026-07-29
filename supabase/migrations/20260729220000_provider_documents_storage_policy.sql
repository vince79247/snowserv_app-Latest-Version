-- Provider registration was IMPOSSIBLE to submit: uploading the driver's licence /
-- insurance photo to the private `provider-documents` bucket failed with
-- "new row violates row-level security policy" (403 Unauthorized).
--
-- Cause: storage.objects has RLS on, and the ONLY policy that existed was an INSERT
-- policy for bucket 'job-photos'. There was never any policy for
-- 'provider-documents', so every upload was denied by default. Both pre-existing
-- providers have NULL dl_photo_url/insurance_photo_url — this never once worked.
-- (Found 2026-07-29 when the first real outside tester tried to register.)
--
-- Scope: the deployed app uploads FLAT filenames `dl_<uid>_<ts>.jpg` /
-- `ins_<uid>_<ts>.jpg` (provider_registration_screen.dart), so the policy keys off
-- that pattern — a provider can only create objects that carry their OWN uid. Do not
-- change the client path without changing this policy (and vice versa).
--
-- Reads stay closed on purpose: no SELECT policy, so providers/customers/public
-- cannot read the bucket. The admin views documents only through admin-doc-url,
-- which uses the service role (bypasses RLS) to mint a short-lived signed URL.

drop policy if exists "Providers can upload own documents" on storage.objects;

create policy "Providers can upload own documents"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'provider-documents'
  and (
    name like 'dl_'  || auth.uid()::text || '_%'
    or name like 'ins_' || auth.uid()::text || '_%'
  )
);
