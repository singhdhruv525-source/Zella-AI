// Zella - Inbound Email: turn the fetched email into the small, plain message the database expects.
// Only text is passed on (never the HTML), cut to a safe size. The database decides what the email is and what to do.
const plan = $('Plan').item.json;
const r = $json;
const status = Number(r.statusCode);
const e = r.body && typeof r.body === 'object' && !Array.isArray(r.body) ? r.body : null;
if (!(status >= 200 && status < 300) || !e) return { json: { record: null } };
const h = e.headers && typeof e.headers === 'object' && !Array.isArray(e.headers) ? e.headers : {};
const lower = {};
for (const k of Object.keys(h)) lower[k.toLowerCase()] = h[k];
const str = (v, max) => (typeof v === 'string' ? v.slice(0, max) : '');
const list = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === 'string').slice(0, 20) : typeof v === 'string' ? [v] : []);
const messageId = str(lower['message-id'] || e.message_id || (plan.hint && plan.hint.message_id) || '', 300).replace(/[<>\s]/g, '');
const inReplyTo = str(lower['in-reply-to'] || '', 300).replace(/[<>\s]/g, '');
const auto = /auto-(replied|generated)|auto_reply|yes/i.test(String(lower['auto-submitted'] || '')) && !/^no$/i.test(String(lower['auto-submitted'] || '')) ||
  /^(bulk|junk|list|auto_reply)$/i.test(String(lower['precedence'] || '')) || !!lower['x-autoreply'] || !!lower['x-autorespond'];
let text = str(e.text, 20000);
if (!text && typeof e.html === 'string') text = e.html.replace(/<style[\s\S]*?<\/style>|<script[\s\S]*?<\/script>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 20000);
return {
  json: {
    record: {
      p_key: plan.key,
      p_sig: plan.sig,
      p_message: {
        message_id: messageId, from: str(e.from || (plan.hint && plan.hint.from) || '', 300), to: list(e.to || (plan.hint && plan.hint.to)),
        subject: str(e.subject || (plan.hint && plan.hint.subject) || '', 300), text, in_reply_to: inReplyTo, auto_submitted: auto,
      },
    },
  },
};
