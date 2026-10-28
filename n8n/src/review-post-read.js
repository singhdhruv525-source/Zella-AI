// Zella - Review Replies: tell the database whether Google accepted the reply (it retries up to 5 times).
const plan = $('Plan post').item.json;
const status = Number($json.statusCode);
return { json: { record: { p_review_id: plan.review_id, p_status_code: Number.isFinite(status) ? status : null } } };
