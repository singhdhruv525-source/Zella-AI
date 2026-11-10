// Zella - Staff Texts: one text to a team member, decided by the database (who, what, and the hourly limit).
// Only a well-formed phone number and a short plain message get through.
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const j = $json || {};
const phone = /^\+[1-9][0-9]{7,14}$/;
if (typeof j.message_id !== 'string' || !uuid.test(j.message_id) || !phone.test(String(j.to || '')) || !phone.test(String(j.from || ''))) return { json: { skip: true } };
const text = String(j.text || '').replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 300);
if (text.length < 5) return { json: { skip: true } };
return { json: { skip: false, message_id: j.message_id, telnyx: { from: j.from, to: j.to, text, type: 'SMS' } } };
