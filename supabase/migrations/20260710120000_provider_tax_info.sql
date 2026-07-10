-- Provider tax info for year-end 1099-NEC reporting via Stripe Connect.
-- SSN already exists on providers (collected at registration for individuals);
-- these add the rest of the W-9-style data Stripe needs to file/e-deliver 1099s.
ALTER TABLE providers
  ADD COLUMN IF NOT EXISTS tax_legal_name       text,   -- full legal name for tax
  ADD COLUMN IF NOT EXISTS tax_business_name    text,   -- if operating as a business/LLC
  ADD COLUMN IF NOT EXISTS tax_classification   text,   -- individual|sole_prop|single_member_llc|partnership|c_corp|s_corp
  ADD COLUMN IF NOT EXISTS tax_ein              text,   -- EIN when the provider is a business
  ADD COLUMN IF NOT EXISTS tax_address_line     text,
  ADD COLUMN IF NOT EXISTS tax_city             text,
  ADD COLUMN IF NOT EXISTS tax_state            text,
  ADD COLUMN IF NOT EXISTS tax_zip              text,
  ADD COLUMN IF NOT EXISTS tax_efile_consent    boolean DEFAULT false,  -- consent to e-delivery of 1099
  ADD COLUMN IF NOT EXISTS tax_efile_consent_at timestamptz;
