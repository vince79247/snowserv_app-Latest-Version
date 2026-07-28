-- Sales tax (Stripe Tax) collected on a job, in dollars. Written by stripe-webhook
-- from checkout.session.total_details.amount_tax. Kept separate from final_price so
-- provider payouts (75% of final_price) never include tax, and so the tax collected
-- is recorded per job for remittance/receipts. Null/0 until a tax registration exists.
alter table jobs add column if not exists tax_amount numeric;
