// Shared branded email shell. Used by send-welcome-email and send-dispute-email
// so every message SnowServ sends looks like the same company.
//
// Email HTML constraints (not the same as web HTML): tables for layout (Outlook
// ignores flex/grid), every style inline (Gmail strips <style> blocks), 600px max
// width, and explicit color-scheme:only light so a dark-mode client can't invert
// it into unreadable dark-on-dark.

export function shell(heading: string, bodyHtml: string): string {
  return `<div style="background-color:#F0F6FF;margin:0;padding:24px 12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color-scheme:only light;supported-color-schemes:only light;">
  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:600px;margin:0 auto;background-color:#FFFFFF;border-radius:12px;border:1px solid #E2ECF6;">
    <tr><td bgcolor="#0D1B2A" style="background-color:#0D1B2A;padding:28px 32px;border-radius:12px 12px 0 0;text-align:center;">
      <div style="font-size:24px;font-weight:700;color:#FFFFFF;letter-spacing:-0.3px;">&#10052;&#65039; SnowServ</div>
      <div style="font-size:13px;color:#B8D4F0;padding-top:4px;">Snow removal, on demand</div>
    </td></tr>
    <tr><td style="padding:32px;background-color:#FFFFFF;color:#15242F;">
      <h1 style="margin:0 0 16px;font-size:21px;font-weight:700;color:#0D1B2A;">${heading}</h1>
      ${bodyHtml}
    </td></tr>
    <tr><td bgcolor="#F7FBFF" style="background-color:#F7FBFF;padding:18px 32px;border-radius:0 0 12px 12px;border-top:1px solid #E2ECF6;text-align:center;">
      <p style="margin:0;font-size:12px;line-height:1.6;color:#5A7184;">
        Questions? <a href="mailto:support@snowserv.app" style="color:#1565C0;text-decoration:none;">support@snowserv.app</a><br>
        You're receiving this because you created a SnowServ account.
      </p>
    </td></tr>
  </table>
</div>`
}
