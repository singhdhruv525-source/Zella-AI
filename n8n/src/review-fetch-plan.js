// Zella - Review Replies: the Google Business Profile address for one connected location. Only numeric ids chosen by
// the business's owner ever reach the URL. Reviews are read newest-first, 50 at a time (every 6 hours).
const s = $json || {};
const ok = (v) => typeof v === 'string' && /^[0-9]{1,30}$/.test(v);
if (!ok(s.account_id) || !ok(s.location_id) || typeof s.business_id !== 'string') return { json: { skip: true } };
return { json: { skip: false, business_id: s.business_id,
  url: 'https://mybusiness.googleapis.com/v4/accounts/' + s.account_id + '/locations/' + s.location_id + '/reviews?pageSize=50&orderBy=updateTime%20desc' } };
