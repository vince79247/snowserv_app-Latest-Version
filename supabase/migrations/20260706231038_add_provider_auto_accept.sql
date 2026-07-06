-- Opt-in: when a provider is on duty with auto_accept on, jobs routed to them
-- are auto-assigned (no manual accept / no 4-min countdown to miss).
alter table providers add column if not exists auto_accept boolean not null default false;
