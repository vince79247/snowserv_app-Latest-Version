-- Records a provider's acceptance of the Provider Service Agreement (the
-- anti-harvesting / non-circumvention terms). Captured at registration as a
-- typed-name e-signature. Signed_at null = not signed yet.
alter table providers add column if not exists service_agreement_signed_at timestamptz;
alter table providers add column if not exists service_agreement_name text;
alter table providers add column if not exists service_agreement_version text;
