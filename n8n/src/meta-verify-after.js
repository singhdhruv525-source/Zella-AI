// Zella - Meta Webhook (set-up check): the challenge is echoed only when the database said the word was right.
const plan = $('Check').item.json;
const r = $json;
const ok = plan.check && Number(r.statusCode) >= 200 && Number(r.statusCode) < 300 && r.body === true;
return { json: { ok, challenge: ok ? plan.challenge : '' } };
