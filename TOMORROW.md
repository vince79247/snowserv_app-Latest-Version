# SnowServ — Tomorrow's To-Do

Legend: **[you]** = your action (bank/Stripe/IRS) · **[claude]** = I build it in the app.

## 1. Business banking (you)
- [ ] **Retry the Bank of America** business-account application (the site was glitching tonight).
- [ ] **If BofA keeps failing**, don't waste hours — alternatives that open fast:
  - Chase Business Complete, or a local **credit union**, or
  - **online business banking** (Mercury, Bluevine, Relay) — quick online signup, good for a startup.
- [ ] **Bring/have ready:** filed **LLC Articles of Organization** + your **EIN**.
- [ ] If the bank wants **official EIN proof**: call IRS **800-829-4933 at 7 AM sharp**, ask for the **147C letter** (they fax it).

## 2. Stripe — finish activation (you)
- [ ] Now that you have the **EIN**, complete the business section:
  - Business type: **Company → LLC (single-member)**
  - Legal name: **SnowServ LLC** · **EIN**
  - **Attach the business bank account** once it's open (not your personal one).
- [ ] Customer support: personal number **on file but hidden** on receipts; **support@snowserv.app** as the public contact (decided).
- [ ] Website field: **snowserv.app** (it's live).

## 3. Provider 1099 tax collection — NEW build (claude)
**Goal:** enable Stripe to issue **bulk year-end 1099-NEC forms** to providers. That requires collecting each provider's tax info and passing it to their Stripe Connect account.

- [ ] **Add these provider tax fields** (app + `providers` table):
  - **Legal name** (and **business name** if they operate as a business/LLC)
  - **Tax classification** — Individual / Sole proprietor / Single-member LLC / Partnership / C-corp / S-corp
  - **Mailing address** — line, city, state, ZIP
  - **Taxpayer ID** — **SSN** (individual) or **EIN** (business)
  - **Electronic-delivery consent** checkbox (Stripe requires it to e-deliver 1099s)
- [ ] Add these to the provider **onboarding + "Update Banking Details"** screen (secure fields; SSN/EIN handled like the existing SSN field).
- [ ] **Pass the info to the provider's Stripe Connect account** (the fields Stripe needs on the connected account for tax reporting).
- [ ] **Turn on Stripe 1099 tax reporting** for Connect (Stripe dashboard → Connect → Tax forms) so it generates + files + e-delivers them.

## 4. Stripe Connect (claude + you)
- [ ] **[you]** Enable **Connect** on the Stripe account (needed to pay providers *and* issue 1099s).
- [ ] **[claude]** Finalize Connect settings (payout schedule, who pays Stripe fees) — the batch-payouts function is already built to use Connect.

## Already done (reference)
- ✅ Website live at **snowserv.app** (+ Privacy Policy & Terms) — your Mac's DNS cache clears on restart.
- ✅ Commission is admin-editable (set to 25%).
- ✅ LLC operating agreement drafted (docs/) · EIN obtained.

## Later (not tomorrow)
- Sales tax: Stripe Tax + confirm marketplace-facilitator rules with a CPA.
- Trademark "SnowServ" (knockout search first).
- NY LLC **publication requirement** (120-day window).
- App Store / Play Store submission (privacy-policy URL is ready).
