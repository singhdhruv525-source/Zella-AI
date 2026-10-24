// Zella - Staff Texts: turn Telnyx's answer into the message update. Only the status and an error code are kept.
const plan = $('Plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const externalId = b.data && b.data.id ? String(b.data.id) : null;
const ok = status >= 200 && status < 300 && !!externalId;
const code = Array.isArray(b.errors) && b.errors[0] && b.errors[0].code ? ' (code ' + String(b.errors[0].code).slice(0, 20) + ')' : '';
return { json: { update: { p_id: plan.message_id, p_status: ok ? 'sent' : 'failed', p_external_id: externalId, p_error: ok ? null : 'Telnyx returned ' + status + code + '.' } } };
