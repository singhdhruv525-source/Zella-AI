// Zella - Admin Alerts: report the provider's answer. Only the status and a short error name are kept.
const prev = $('Plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const ok = status >= 200 && status < 300 && !!b.id;
const name = typeof b.name === 'string' && /^[a-z_]{1,40}$/.test(b.name) ? ' (' + b.name + ')' : '';
return {
  json: {
    finish: { rpc: 'zella_finish_admin_alert_email', body: { p_ids: prev.ids, p_ok: ok, p_error: ok ? null : 'The email provider returned ' + status + name + '.' } },
  },
};
