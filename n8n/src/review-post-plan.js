// Zella - Review Replies: post exactly the reply the owner approved, on exactly that Google review.
const r = $json || {};
const num = (v) => typeof v === 'string' && /^[0-9]{1,30}$/.test(v);
if (!r.review_id || !num(r.account_id) || !num(r.location_id) || typeof r.external_id !== 'string' || !/^[A-Za-z0-9_-]{1,300}$/.test(r.external_id)
    || typeof r.reply !== 'string' || r.reply.length < 2 || r.reply.length > 4000) return { json: { skip: true, review_id: r.review_id || null } };
return { json: { skip: false, review_id: r.review_id, body: { comment: r.reply },
  url: 'https://mybusiness.googleapis.com/v4/accounts/' + r.account_id + '/locations/' + r.location_id + '/reviews/' + r.external_id + '/reply' } };
