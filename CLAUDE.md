# SnowServ App

## What this app is
Uber-style snow removal marketplace. Customers request snow removal services, providers accept jobs. Built with Flutter + Supabase.

## Supabase project
- URL: https://swttuujhcgpcsrxgupzv.supabase.co
- Anon key: sb_publishable_SnyCvdfwgHOQe-NB0D8Ipw_DUI9uWRe
- Service role key: (stored in Supabase dashboard — do not commit)

## Database tables

### jobs
id, customer_id (fkey → users), provider_id (fkey → providers), address_id (fkey → addresses), job_type, provider_type_required, driveway (bool), walkway (bool), salting (bool), base_price, surge_multiplier, final_price, status, created_at, completion_photos (text[]), provider_notes (text), service_type, snow_level

Valid status values: requested, assigned, in_progress, completed
NOT valid: pending, accepted (violate jobs_status_check constraint)

### users (public)
id (uuid, matches auth.users.id), name, email, phone, role, dispute_count, is_flagged, is_suspended, created_at

### providers
id (uuid, auto-generated — NOT same as auth user id), user_id (fkey → users), provider_type, is_online, is_verified, current_lat, current_lng, has_vehicle, crew_size, rating, total_jobs, created_at

IMPORTANT: jobs.provider_id references providers.id (NOT auth user id). Must look up providers.id via user_id when accepting jobs.

### profiles
id (uuid, matches auth.users.id), role (customer/provider), full_name, phone, is_online, created_at
Used for: role-based routing in Flutter (RoleRouter)

### addresses
Schema unknown. address_id in jobs references this table.

### payments
Schema unknown.

## Auth flow
- Email confirmation is ON — users must confirm email before logging in
- On signup: insert into profiles, users, and providers (if role=provider)
- No trigger — profile/user/provider creation handled in Flutter (auth_screen.dart)
- Role stored in profiles.role — used to route to CustomerHome or ProviderHome

## File structure
```
lib/
  main.dart                        — app entry, AuthGate, RoleRouter
  screens/
    auth/
      auth_screen.dart             — login, signup, forgot password
    customer/
      customer_home.dart           — service selector, request job
    provider/
      provider_home.dart           — online toggle, available jobs, active jobs
```

## Pricing
- Sidewalk only: $50
- Driveway only: $100
- Sidewalk + Driveway: $125
- Salting add-on: +$40
- Surge pricing: base_price × surge_multiplier (not yet built)

## Provider flow
1. Toggle online → loads available jobs (status=requested)
2. Accept job → status becomes assigned, job moves to Active Jobs section
3. Start Job → status becomes in_progress
4. Reject job → hidden from this provider's list only (other providers still see it)

## What's working
- Customer signup/login/logout
- Provider signup/login/logout
- Customer requests job (service selector + pricing)
- Provider goes online/offline
- Provider sees available jobs, accepts or rejects
- Active jobs shown to provider after accepting
- Forgot password flow

## What's NOT built yet
- Address collection for customers
- Job completion (provider marks done, uploads photos, adds notes)
- Real-time updates (currently manual refresh)
- Customer job status tracking
- Location-based provider matching
- Surge pricing
- Stripe / Apple Pay payments
- Push notifications
- Admin panel

## macOS entitlements
Both network.client and network.server enabled in macos/Runner/DebugProfile.entitlements
