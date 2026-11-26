// Zella Voice - the business's own mailbox (Gmail, Outlook): what the provider's answer to one send means. Shared by the
// Email Sender and Follow-up Emails (inlined into their After send steps). Only a status, a short name and our own id
// are kept: never the provider's text. refused: "quota" (its daily sending limit: the rest of the business's day goes
// through the fallback) or "sign_in" (the mailbox needs reconnecting); both go to zella_business_email_mailbox_refused.
function mailboxResult(transport, status, body, fail, messageId) {
  if (fail === 'sign_in') return { ok: false, refused: 'sign_in', external_id: null, error: 'The mailbox sign in no longer works; it needs reconnecting.' };
  if (fail === 'not_connected') return { ok: false, refused: null, external_id: null, error: 'The mailbox is not connected any more; trying again.' };
  if (fail) return { ok: false, refused: null, external_id: null, error: 'No answer from the mailbox sign in; trying again later.' };
  const b = body && typeof body === 'object' ? body : {};
  const err = b.error && typeof b.error === 'object' ? b.error : {};
  const name = (s) => (typeof s === 'string' && /^[A-Za-z_]{1,60}$/.test(s) ? ' (' + s + ')' : '');
  if (transport === 'gmail') {
    if (status >= 200 && status < 300 && typeof b.id === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(b.id)) return { ok: true, refused: null, external_id: 'gmail:' + b.id, error: null };
    const reasons = Array.isArray(err.errors) ? err.errors.map((e) => (e && typeof e.reason === 'string' ? e.reason : '')) : [];
    if (status === 429 || err.status === 'RESOURCE_EXHAUSTED' || reasons.some((r) => ['dailyLimitExceeded', 'userRateLimitExceeded', 'rateLimitExceeded', 'quotaExceeded', 'limitExceeded'].includes(r))) {
      return { ok: false, refused: 'quota', external_id: null, error: 'Gmail refused: its daily sending limit.' };
    }
    if (status === 401 || reasons.includes('authError') || reasons.includes('insufficientPermissions')) return { ok: false, refused: 'sign_in', external_id: null, error: 'Gmail refused the sign in; it needs reconnecting.' };
    return { ok: false, refused: null, external_id: null, error: isNaN(status) ? 'No answer from Gmail (timed out); trying again later.' : 'Gmail returned ' + status + name(reasons[0]) + '.' };
  }
  // Microsoft Graph sendMail answers 202 Accepted with no body and no id: our own message id stands in for it
  if (status >= 200 && status < 300) return { ok: true, refused: null, external_id: 'graph:' + String(messageId || '').replace(/[^0-9a-f-]/gi, '').slice(0, 40), error: null };
  const code = typeof err.code === 'string' ? err.code : '';
  if (status === 429 || ['ErrorExceededMessageLimit', 'ErrorQuotaExceeded', 'ErrorSubmissionQuotaExceeded'].includes(code)) {
    return { ok: false, refused: 'quota', external_id: null, error: 'Outlook refused: its daily sending limit.' };
  }
  if (status === 401 || ['InvalidAuthenticationToken', 'ErrorAccessDenied', 'Authorization_RequestDenied'].includes(code)) return { ok: false, refused: 'sign_in', external_id: null, error: 'Outlook refused the sign in; it needs reconnecting.' };
  return { ok: false, refused: null, external_id: null, error: isNaN(status) ? 'No answer from Outlook (timed out); trying again later.' : 'Outlook returned ' + status + name(code) + '.' };
}
