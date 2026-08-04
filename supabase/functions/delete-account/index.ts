// In-app account deletion — required by App Store Guideline 5.1.1(v) (and a
// GDPR/CCPA right-to-delete). A caller can only ever delete THEIR OWN account:
// every read/write is keyed off the verified JWT's `sub`, never a client-supplied
// id. verify_jwt stays TRUE (default, NOT in config.toml) so the platform rejects
// anonymous callers before we run.
//
// STRATEGY — kill the login, scrub the person, KEEP the records:
// Every FK into public.users / public.providers is ON DELETE **NO ACTION**, so the
// rows physically cannot be deleted while jobs/addresses reference them — and we
// wouldn't want to anyway: job rows are needed for tax, payouts and disputes. So we
//   1. scrub all personally identifying data (name/email/phone/card/bank/SSN/DOB/
//      license/insurance/tax/vehicle),
//   2. delete the provider's private documents from storage,
//   3. detach their card from Stripe,
//   4. DELETE the auth.users row so they can never log in again.
//
// VERIFIED end-to-end 2026-07-13 (throwaway account): login dies, PII is scrubbed,
// and ALL job rows survive. Note `profiles.id` IS `REFERENCES auth.users(id) ON
// DELETE CASCADE`, so step 4 also drops the profiles row — that's the outcome we
// want, and the cascade stops there (nothing references profiles). `public.users`
// has NO FK to auth, so it survives as the scrubbed anchor that keeps
// jobs/addresses FK-intact. The profiles PATCH below is therefore belt-and-braces.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function decodeCaller(auth: string | null): { sub?: string } {
  try {
    if (!auth) return {}
    const payload = auth.replace(/^Bearer\s+/i, '').split('.')[1]
    if (!payload) return {}
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')))
  } catch {
    return {}
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (!caller.sub) {
      return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: cors })
    }
    const uid = caller.sub

    const url = Deno.env.get('SUPABASE_URL')!
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    const h = { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }

    const rest = async (path: string, init?: RequestInit) =>
      fetch(`${url}/rest/v1/${path}`, { ...init, headers: { ...h, ...(init?.headers ?? {}) } })

    // ---- 1. Look up what we're dealing with -------------------------------
    const userRes = await rest(`users?id=eq.${uid}&select=card_pm_id,stripe_customer_id`)
    const userRow = (await userRes.json())?.[0] ?? {}

    const provRes = await rest(
      `providers?user_id=eq.${uid}&select=id,dl_photo_url,insurance_photo_url,stripe_connect_id`)
    const provider = (await provRes.json())?.[0]

    // A provider deleting themselves may still be owed money. We do NOT block the
    // deletion (Apple requires it to be possible) — we report it so the UI can warn
    // them, and the job rows survive so the operator can still settle up.
    let pendingEarnings = 0
    if (provider?.id) {
      const owedRes = await rest(
        `jobs?provider_id=eq.${provider.id}&status=eq.completed&payout_status=eq.pending&select=final_price`)
      const owed = await owedRes.json()
      if (Array.isArray(owed)) {
        pendingEarnings = owed.reduce(
          (s: number, j: { final_price: number | string }) => s + Number(j.final_price ?? 0), 0)
      }
    }

    // ---- 2. Scrub the provider row (this is where the sensitive PII lives) --
    if (provider?.id) {
      // NOTE: SSN/DOB/bank + the W-9 tax_* columns no longer exist — since the
      // Connect Express migration (#21) that sensitive data lives at Stripe, not
      // here, so there is nothing of that kind left in our DB to scrub.
      await rest(`providers?user_id=eq.${uid}`, {
        method: 'PATCH',
        headers: { Prefer: 'return=minimal' },
        body: JSON.stringify({
          dl_number: null, dl_state: null, dl_photo_url: null,
          insurance_carrier: null, insurance_policy: null,
          insurance_expiry: null, insurance_photo_url: null,
          vehicle_vin: null, vehicle_plate: null,
          service_agreement_name: null,
          current_lat: null, current_lng: null,
          is_online: false,
          stripe_connect_id: null, payouts_enabled: false,
          registration_status: 'deleted',
        }),
      })

      // Their license / insurance scans live in the PRIVATE provider-documents
      // bucket. Purge them — leaving them behind would defeat the deletion.
      const docs = [provider.dl_photo_url, provider.insurance_photo_url].filter(Boolean)
      if (docs.length) {
        await fetch(`${url}/storage/v1/object/provider-documents`, {
          method: 'DELETE',
          headers: h,
          body: JSON.stringify({ prefixes: docs }),
        }).catch(() => {})
      }

      // Delete their Stripe Connect Express account so no connected account is
      // orphaned. Best-effort: if Stripe refuses (e.g. a residual balance), we
      // still complete the local deletion — the operator settles any balance out
      // of band. (Pending SnowServ earnings sit in OUR balance, not theirs.)
      if (stripeKey && provider.stripe_connect_id) {
        await fetch(`https://api.stripe.com/v1/accounts/${provider.stripe_connect_id}`, {
          method: 'DELETE',
          headers: { Authorization: `Bearer ${stripeKey}` },
        }).catch(() => {})
      }
    }

    // ---- 3. Detach their card from Stripe (don't keep it on file) ----------
    if (stripeKey && userRow.card_pm_id) {
      await fetch(`https://api.stripe.com/v1/payment_methods/${userRow.card_pm_id}/detach`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${stripeKey}` },
      }).catch(() => {})
    }

    // ---- 4. Scrub the identity rows (kept for FK integrity / tax records) ---
    await rest(`users?id=eq.${uid}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({
        name: 'Deleted user',
        email: `deleted+${uid}@deleted.invalid`,
        phone: null,
        stripe_customer_id: null,
        card_pm_id: null, card_last4: null, card_brand: null,
        card_exp_month: null, card_exp_year: null,
      }),
    })

    await rest(`profiles?id=eq.${uid}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({
        full_name: 'Deleted user',
        phone: null,
        fcm_token: null,   // stop pushing to a deleted account
        is_online: false,
      }),
    })

    // ---- 5. Delete the auth user — they can never log in again -------------
    // Nothing FKs to auth.users, so this does not cascade into job records.
    const authDel = await fetch(`${url}/auth/v1/admin/users/${uid}`, {
      method: 'DELETE',
      headers: { apikey: key, Authorization: `Bearer ${key}` },
    })
    if (!authDel.ok && authDel.status !== 404) {
      const t = await authDel.text()
      return new Response(
        JSON.stringify({ error: `Could not delete login: ${t}` }),
        { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    return new Response(
      JSON.stringify({ deleted: true, pending_earnings: pendingEarnings }),
      { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
