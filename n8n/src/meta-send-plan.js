// Zella - Meta Sender: one claimed reply in. The destination is built here from known ids only; the text is sent as plain text.
const id = (v, re) => (typeof v === 'string' && re.test(v) ? v : null);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const outId = id($json.id, uuid);
if (!outId) return { json: { skip: true } };
const page = id($json.page_id, /^[0-9]{5,30}$/);
const ch = $json.channel;
const kind = $json.kind;
const to = typeof $json.recipient === 'string' ? $json.recipient.slice(0, 200) : '';
const text = typeof $json.text === 'string' ? $json.text.slice(0, 1000) : '';
const base = 'https://graph.facebook.com/v21.0/';
let url = null; let body = null;
if (page && text && to) {
  if (ch === 'whatsapp') {
    const phone = id($json.whatsapp_phone_id, /^[0-9]{5,30}$/);
    if (phone && /^[0-9]{7,15}$/.test(to) && kind === 'message') { url = base + phone + '/messages'; body = { messaging_product: 'whatsapp', to, type: 'text', text: { body: text } }; }
    // An approved template with no fill-in values, for a customer whose 24-hour window has closed.
    const tname = id($json.template_name, /^[a-z0-9_]{1,200}$/);
    const tlang = id($json.template_language, /^[a-z]{2}(_[A-Z]{2})?$/);
    if (phone && /^[0-9]{7,15}$/.test(to) && kind === 'template' && tname && tlang) { url = base + phone + '/messages'; body = { messaging_product: 'whatsapp', to, type: 'template', template: { name: tname, language: { code: tlang } } }; }
  } else if ((ch === 'messenger' || ch === 'instagram') && kind === 'message' && /^[0-9A-Za-z_-]{3,100}$/.test(to)) {
    url = base + page + '/messages'; body = { recipient: { id: to }, messaging_type: 'RESPONSE', message: { text } };
  } else if ((ch === 'messenger' || ch === 'instagram') && kind === 'private_reply' && /^[0-9A-Za-z_-]{3,100}$/.test(to)) {
    const igId = id($json.instagram_id, /^[0-9]{5,30}$/);
    url = base + (ch === 'instagram' && igId ? igId : page) + '/messages'; body = { recipient: { comment_id: to }, message: { text } };
  }
}
return { json: { skip: false, id: outId, page_id: page, valid: !!url, url, body } };
