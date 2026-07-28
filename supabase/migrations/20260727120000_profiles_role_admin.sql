-- Make 'admin' a first-class role (#admin-login, 2026-07-27). The platform operator
-- is neither a customer nor a provider — they log in and land straight on the Admin
-- Panel (RoleRouter routes on profiles.is_admin, and role can now say 'admin' so the
-- data reflects reality). is_admin stays the authoritative permission flag used by
-- RLS and the admin-only edge functions; role='admin' is the honest label + router hint.
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('customer', 'provider', 'admin'));
