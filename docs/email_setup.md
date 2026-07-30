# Email setup (Resend → Supabase Auth SMTP)

**Why this is a launch blocker.** Supabase's built-in email sender is a shared,
heavily rate-limited service meant for development, and it already warned us about
bounce rate. If a confirmation email doesn't arrive, the user cannot log in —
email confirmation is ON. On a launch-day / snowstorm signup rush, the built-in
sender will silently drop mail. Nobody signs up.

---

## ⚠️ Read this first: do NOT add an SPF record to snowserv.app

`snowserv.app` already sends mail through **Zoho** and has exactly one SPF record:

```
snowserv.app  TXT  "v=spf1 include:zohomail.com ~all"
```

A domain may only have **ONE** `v=spf1` record. Add a second and, per RFC 7208,
**both fail** — which would send outbound mail from support@snowserv.app to spam.
Resend's default instructions will tell you to add one at the root. Don't.

Instead we verify the **subdomain `send.snowserv.app`**, which gets its own
records and never touches Zoho's. This is also Resend's own recommendation, and
it isolates reputation: a wave of bounced signup confirmations can't poison the
domain your human support email sends from.

Mail will come from **`noreply@send.snowserv.app`**. Replies are pointed at
support@snowserv.app, so customers still reach the real inbox.

---

## Step 1 — Create the Resend account (~2 min)

1. Go to <https://resend.com> → **Sign up** (free tier: 3,000 emails/month,
   100/day — far more than launch needs).
2. Use **snowserv.app@snowserv.app** (the Zoho inbox) as the account email, so
   account notices land where you already watch. Not the Yahoo one.

## Step 2 — Add the sending domain (~2 min)

1. Resend → **Domains** → **Add Domain**.
2. Enter exactly: **`send.snowserv.app`**  ← the subdomain, NOT `snowserv.app`
3. Region: **US East (N. Virginia)** — closest to NY.
4. Resend shows you 3 DNS records. Leave that tab open for Step 3.

## Step 3 — Add the DNS records in Cloudflare (~5 min)

Cloudflare → snowserv.app → **DNS** → **Records** → **Add record**, once per row.

> **Cloudflare auto-appends the domain.** In the Name field type `send`, NOT
> `send.snowserv.app` — otherwise you create `send.snowserv.app.snowserv.app`.
> Same for the DKIM row: type `resend._domainkey.send`.

| # | Type | Name (type this) | Value | Notes |
|---|------|------------------|-------|-------|
| 1 | MX   | `send` | `feedback-smtp.us-east-1.amazonses.com` | Priority **10**. Handles bounces. |
| 2 | TXT  | `send` | `v=spf1 include:amazonses.com ~all` | SPF for the SUBDOMAIN only. |
| 3 | TXT  | `resend._domainkey.send` | *(long `p=…` key — copy from Resend)* | DKIM. Copy-paste it whole. |

Copy values from the Resend screen rather than from this table — the DKIM key is
generated per-domain and is unique to you.

**Recommended 4th record** (safe, improves deliverability):

| # | Type | Name | Value |
|---|------|------|-------|
| 4 | TXT | `_dmarc.send` | `v=DMARC1; p=none; rua=mailto:support@snowserv.app` |

`p=none` is monitor-only — it cannot cause mail to be rejected. Do **not** use
`p=quarantine` or `p=reject` here without checking with me first; those can bounce
real mail if alignment is wrong.

Then back in Resend → **Verify DNS Records**. Cloudflare is usually near-instant;
if it says pending, wait a few minutes and re-check. All three must go green.

## Step 4 — Create the API key (~1 min)

1. Resend → **API Keys** → **Create API Key**.
2. Name: `snowserv-supabase`. Permission: **Sending access**.
3. Copy the key (starts `re_`). It is shown **once**.

> 🔒 Paste this key only into the Supabase dashboard in Step 5. Do not paste it
> into the chat — anything that appears there has to be treated as compromised
> and rotated.

## Step 5 — Point Supabase Auth at Resend (~3 min)

Supabase dashboard → project `swttuujhcgpcsrxgupzv` → **Authentication** →
**Emails** → **SMTP Settings** → enable **Custom SMTP**:

| Field | Value |
|-------|-------|
| Sender email | `noreply@send.snowserv.app` |
| Sender name | `SnowServ` |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | *the `re_…` API key from Step 4* |

Save.

## Step 6 — Raise the auth email rate limit (~1 min) — DON'T SKIP

Supabase caps auth emails **per hour**, and the default is low enough to break a
launch-day rush. Custom SMTP does not raise it automatically.

**Authentication** → **Rate Limits** → **Rate limit for sending emails** → raise
to **150/hour** (comfortably under Resend's free 100/day while removing the
Supabase-side cliff; revisit if volume grows).

## Step 7 — Tell me when it's done

I'll then verify end-to-end myself: trigger a real confirmation email to an
address I control, confirm it arrives, check SPF/DKIM/DMARC all pass in the
received headers, and confirm the link completes signup. I won't call this done
on a green checkmark in a dashboard.

---

## After this works — welcome emails

Separate customer + provider welcome emails (asked for 2026-07-29) ride on this
same Resend plumbing via an edge function. They fire **after email confirmation**,
not at signup, so a new user doesn't get two emails at once and the welcome
doesn't arrive before the account is usable.

## Not doing yet (deliberate)

Inbound email — parsing replies to support@ into the app. The Support Draft
Assistant is still paste-in by design. Revisit post-launch.
