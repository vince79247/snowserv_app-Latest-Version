import { shell } from '../_shared/email_shell.ts'

// Welcome-email copy. The HTML shell lives in _shared so dispute mail matches.
// Extracted from index.ts so a preview script
// can render EXACTLY what gets sent — a hand-copied preview drifts from the real
// thing the moment either side is edited, which is worse than no preview.
//
// Email HTML constraints (not the same as web HTML): tables for layout (Outlook
// ignores flex/grid), every style inline (Gmail strips <style> blocks), 600px max
// width, and explicit color-scheme:only light so a dark-mode client can't invert
// it into unreadable dark-on-dark.

const p = (t: string) =>
  `<p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:#15242F;">${t}</p>`
const li = (t: string) =>
  `<li style="margin:0 0 8px;font-size:15px;line-height:1.5;color:#15242F;">${t}</li>`
const ul = (items: string[]) =>
  `<ul style="margin:0 0 16px;padding-left:20px;">${items.join('')}</ul>`

export function customerEmail(name: string) {
  const hi = name ? `Hi ${name}, welcome` : 'Welcome'
  return {
    subject: 'Welcome to SnowServ',
    html: shell(`${hi} to SnowServ`, [
      p('Your account is confirmed and ready. Here\'s how it works:'),
      ul([
        li('<b>Add your address</b>, then pick what you need — sidewalk, driveway, or both. Salting is an optional add-on.'),
        li('<b>You\'re not charged when you order.</b> We place a temporary hold on your card. It only becomes a real charge when a provider actually starts the work.'),
        li('<b>Cancel before work starts and the hold is released</b> — no charge at all.'),
        li('<b>Your provider photographs the finished job</b>, so you can see the work even if you weren\'t home.'),
      ]),
      // Kept, but reordered to lead with the PROMISE rather than the increase, and
      // to say WHY prices move. Unexplained surge reads as gouging; "deep snow is
      // more work" reads as fair. This paragraph is also a cheap dispute shield —
      // a timestamped, pre-order disclosure that storm pricing exists is exactly
      // what you want on file when someone asks why a job was $165 and not $125.
      p('You\'ll always see your exact total before you confirm — no surprises. Prices vary by area, and deep snow costs more than a dusting, simply because it\'s more work to clear.'),
      p('<a href="mailto:support@snowserv.app" style="color:#1565C0;">Email us</a> any time — a real person reads it.'),
    ].join('')),
  }
}

export function providerEmail(name: string) {
  const hi = name ? `Hi ${name}, welcome` : 'Welcome'
  return {
    subject: 'Welcome to SnowServ — what happens next',
    html: shell(`${hi} to SnowServ`, [
      p('Thanks for signing up to work with us. Here\'s what to expect:'),
      ul([
        li('<b>Approval comes first.</b> We review your registration and documents before you can take jobs. You\'ll be notified when you\'re approved.'),
        li('<b>You keep 75% of every job.</b> No fee to join, nothing deducted for equipment or fuel.'),
        li('<b>Payouts run on a 7-day rolling batch</b> to the bank account you connect through Stripe. Set that up in the app before your first job so nothing is held up.'),
        li('<b>Jobs are matched to your equipment.</b> Tell us whether you run a shovel, snowblower, or plow — large driveways are routed to the gear that can handle them.'),
        li('<b>You choose when you work.</b> Go online to receive offers, offline when you\'re done. You can decline any job.'),
      ]),
      p('Two things that protect you: take a photo <b>before</b> you start (optional, but it settles disputes fast), and a live completion photo is required when you finish.'),
      p('Your agreement with us includes a non-solicitation clause — SnowServ customers stay on SnowServ. It\'s in the app under your account menu.'),
      p('<a href="mailto:support@snowserv.app" style="color:#1565C0;">Email us</a> with any question.'),
    ].join('')),
  }
}
