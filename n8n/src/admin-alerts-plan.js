// Zella - Admin Alerts: turn the claimed platform alerts into one plain-text digest email for the Zella admins.
// The database only hands out alerts when email is switched on and a sender address is set.
const r = $json;
const alerts = Array.isArray(r.alerts) ? r.alerts.filter((a) => a && a.id && a.title) : [];
const to = Array.isArray(r.to) ? r.to.filter((e) => typeof e === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)).slice(0, 20) : [];
if (!alerts.length) return { json: { skip: true, why: r.why || 'nothing_waiting' } };
const ids = alerts.map((a) => a.id);
if (!to.length || !r.from) {
  return { json: { skip: false, ids, resend: null, finish: { rpc: 'zella_finish_admin_alert_email', body: { p_ids: ids, p_ok: false, p_error: 'no_recipients_or_sender' } } } };
}

const clean = (s, n) => String(s ?? '').replace(/[\r\n]+/g, ' ').slice(0, n);
const label = { urgent: 'URGENT', warning: 'Needs a look', info: 'For your information' };
const urgent = alerts.filter((a) => a.severity === 'urgent').length;
const subject = alerts.length === 1
  ? '[Zella] ' + clean(alerts[0].title, 120)
  : '[Zella] ' + alerts.length + ' alerts' + (urgent ? ' (' + urgent + ' urgent)' : '');
const lines = alerts.map((a) => {
  const who = a.business ? ' (' + clean(a.business, 80) + ')' : '';
  const times = Number(a.occurrences) > 1 ? ' Seen ' + Number(a.occurrences) + ' times.' : '';
  return '- ' + (label[a.severity] || 'Alert') + ': ' + clean(a.title, 160) + who + (a.detail ? '\n  ' + clean(a.detail, 400) : '') + times;
});
const text = 'Here is what needs your attention on Zella:\n\n' + lines.join('\n\n')
  + '\n\nOpen the admin dashboard to see details. Offer alerts are under Offers & Promotions.\n';

return {
  json: {
    skip: false,
    ids,
    finish: null,
    resend: { from: (r.from_name || 'Zella') + ' <' + r.from + '>', to, subject, text },
  },
};
