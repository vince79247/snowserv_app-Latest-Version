-- Insurance is now conditional at registration: REQUIRED for vehicle/plow
-- providers, OPTIONAL for hand-tool (no-vehicle) providers. A hand-tool provider
-- who carries no insurance instead acknowledges personal responsibility. These
-- columns record which path they took, for the admin and the liability trail.
alter table public.providers add column if not exists has_insurance boolean not null default false;
alter table public.providers add column if not exists insurance_ack_at timestamptz;

comment on column public.providers.has_insurance is
  'True if the provider has liability insurance on file (always true for vehicle providers). False = hand-tool provider who acknowledged carrying none.';
comment on column public.providers.insurance_ack_at is
  'When a no-insurance hand-tool provider acknowledged personal responsibility at registration. NULL if they carry insurance.';
