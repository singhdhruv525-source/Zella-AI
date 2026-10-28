// Zella - Review Replies: keep only what the database stores from Google's answer (who, stars, text, when, any reply
// already there). Anything unexpected is dropped; a failed request is reported as a failure.
const plan = $('Plan fetch').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' && !Array.isArray($json.body) ? $json.body : {};
const STARS = { ONE: 1, TWO: 2, THREE: 3, FOUR: 4, FIVE: 5 };
const str = (v, n) => (typeof v === 'string' ? v.slice(0, n) : null);
const items = (Array.isArray(b.reviews) ? b.reviews : []).slice(0, 200).map((r) => {
  const o = r && typeof r === 'object' ? r : {};
  return {
    external_id: str(o.reviewId, 300),
    author_name: str(o.reviewer && o.reviewer.displayName, 120),
    rating: STARS[o.starRating] || null,
    body: str(o.comment, 5000),
    reviewed_at: str(o.createTime, 40),
    existing_reply: str(o.reviewReply && o.reviewReply.comment, 4096),
  };
}).filter((x) => x.external_id && /^[A-Za-z0-9_-]+$/.test(x.external_id) && x.rating);
return { json: { record: { p_business_id: plan.business_id, p_status_code: Number.isFinite(status) ? status : null, p_items: status >= 200 && status < 300 ? items : null } } };
