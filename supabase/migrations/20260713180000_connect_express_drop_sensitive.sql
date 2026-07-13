-- Stripe Connect Express migration (#21): stop being the custodian of provider
-- SSNs, bank numbers, DOB, and W-9 tax data. Providers now onboard bank +
-- identity directly with Stripe (connect-onboard), Stripe verifies (KYC) and
-- files their 1099s, and we store only `stripe_connect_id` + a cached
-- `payouts_enabled` flag. So these plaintext columns can be dropped entirely.
--
-- Safe to drop now: no provider had real values here (payout setup was never
-- completed), and every reader has been migrated off them in the same change
-- (registration, payout functions, delete-account, admin panel, provider UI).

-- Cache of the Connect account's payouts_enabled, refreshed by connect-status;
-- batch-payouts gates on it so it never tries to pay an un-onboarded provider.
ALTER TABLE providers ADD COLUMN IF NOT EXISTS payouts_enabled boolean NOT NULL DEFAULT false;

-- Payout-KYC fields — now collected + held by Stripe, not us.
ALTER TABLE providers DROP COLUMN IF EXISTS ssn;
ALTER TABLE providers DROP COLUMN IF EXISTS dob;
ALTER TABLE providers DROP COLUMN IF EXISTS bank_routing;
ALTER TABLE providers DROP COLUMN IF EXISTS bank_account;

-- W-9 tax fields — Stripe collects tax info and files the 1099-NEC now.
ALTER TABLE providers DROP COLUMN IF EXISTS tax_legal_name;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_business_name;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_classification;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_ein;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_address_line;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_city;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_state;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_zip;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_efile_consent;
ALTER TABLE providers DROP COLUMN IF EXISTS tax_efile_consent_at;
