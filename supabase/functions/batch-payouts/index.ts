import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

Deno.serve(async (req: Request) => {
  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()

    const { data: jobs, error } = await supabase
      .from('jobs')
      .select('*, providers!inner(id, bank_routing, bank_account, ssn, stripe_connect_id, users!inner(name, email, id))')
      .eq('status', 'completed')
      .eq('payout_status', 'pending')
      .lt('created_at', cutoff)

    if (error) throw new Error(error.message)
    if (!jobs || jobs.length === 0) {
      return new Response(JSON.stringify({ processed: 0, message: 'No payouts due' }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const results = []

    for (const job of jobs) {
      try {
        const provider = job.providers
        const providerUser = provider.users
        const payoutCents = Math.round((job.final_price ?? job.base_price) * 0.70 * 100)

        let connectId: string = provider.stripe_connect_id

        if (!connectId) {
          if (!provider.bank_routing || !provider.bank_account || !provider.ssn) {
            results.push({ job_id: job.id, status: 'skipped', reason: 'missing bank info or SSN' })
            continue
          }

          const { data: providerRecord } = await supabase
            .from('providers')
            .select('dob')
            .eq('id', provider.id)
            .single()

          const dobParts = (providerRecord?.dob ?? '').split('-').map(Number)
          const [year, month, day] = dobParts

          const acctBody = new URLSearchParams()
          acctBody.append('type', 'custom')
          acctBody.append('country', 'US')
          acctBody.append('email', providerUser.email)
          acctBody.append('capabilities[transfers][requested]', 'true')
          acctBody.append('business_type', 'individual')
          acctBody.append('individual[first_name]', (providerUser.name ?? '').split(' ')[0] ?? '')
          acctBody.append('individual[last_name]', (providerUser.name ?? '').split(' ').slice(1).join(' ') || 'Unknown')
          acctBody.append('individual[email]', providerUser.email)
          acctBody.append('individual[ssn_last_4]', provider.ssn.slice(-4))
          if (!isNaN(year)) {
            acctBody.append('individual[dob][day]', String(day))
            acctBody.append('individual[dob][month]', String(month))
            acctBody.append('individual[dob][year]', String(year))
          }
          acctBody.append('tos_acceptance[date]', String(Math.floor(Date.now() / 1000)))
          acctBody.append('tos_acceptance[ip]', '127.0.0.1')

          const acctRes = await fetch('https://api.stripe.com/v1/accounts', {
            method: 'POST',
            headers: { Authorization: `Bearer ${stripeKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
            body: acctBody.toString(),
          })
          const acct = await acctRes.json()
          if (acct.error) throw new Error(`Connect account: ${acct.error.message}`)
          connectId = acct.id

          const bankBody = new URLSearchParams()
          bankBody.append('external_account[object]', 'bank_account')
          bankBody.append('external_account[country]', 'US')
          bankBody.append('external_account[currency]', 'usd')
          bankBody.append('external_account[routing_number]', provider.bank_routing)
          bankBody.append('external_account[account_number]', provider.bank_account)

          const bankRes = await fetch(`https://api.stripe.com/v1/accounts/${connectId}/external_accounts`, {
            method: 'POST',
            headers: { Authorization: `Bearer ${stripeKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
            body: bankBody.toString(),
          })
          const bankResult = await bankRes.json()
          if (bankResult.error) throw new Error(`Bank attach: ${bankResult.error.message}`)

          await supabase.from('providers').update({ stripe_connect_id: connectId }).eq('id', provider.id)
        }

        const transferBody = new URLSearchParams()
        transferBody.append('amount', String(payoutCents))
        transferBody.append('currency', 'usd')
        transferBody.append('destination', connectId)
        transferBody.append('transfer_group', `job_${job.id}`)

        const transferRes = await fetch('https://api.stripe.com/v1/transfers', {
          method: 'POST',
          headers: { Authorization: `Bearer ${stripeKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
          body: transferBody.toString(),
        })
        const transfer = await transferRes.json()
        if (transfer.error) throw new Error(`Transfer: ${transfer.error.message}`)

        await supabase.from('jobs').update({
          payout_status: 'paid',
          payout_amount: payoutCents / 100,
          stripe_transfer_id: transfer.id,
        }).eq('id', job.id)

        results.push({ job_id: job.id, status: 'paid', amount: payoutCents / 100, transfer_id: transfer.id })
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e)
        results.push({ job_id: job.id, status: 'error', reason: msg })
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500 })
  }
})
