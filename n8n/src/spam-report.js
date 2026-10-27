// Zella - Spam Response: the weekly summary for one business, from the counts the database prepared. Posted once per
// week (the database refuses a second one); emailed only if the person turned that on in their notification settings.
const r = $json;
const s = r.stats || {};
const n = (v) => (Number.isFinite(Number(v)) ? Math.max(0, Math.round(Number(v))) : 0);
const total = n(s.total);
const plural = (k, one, many) => k + ' ' + (k === 1 ? one : many);
const parts = [['calls', 'call', 'calls'], ['texts', 'text', 'texts'], ['emails', 'email', 'emails'], ['bookings', 'booking', 'bookings']]
  .filter(([k]) => n(s[k]) > 0).map(([k, one, many]) => plural(n(s[k]), one, many));
const lines = [
  plural(total, 'suspicious contact was', 'suspicious contacts were') + ' flagged last week' + (parts.length ? ' (' + parts.join(', ') + ')' : '') + '.',
  n(s.high) ? plural(n(s.high), 'was', 'were') + ' high risk.' : null,
  n(s.blocked) ? plural(n(s.blocked), 'was', 'were') + ' blocked, screened or restricted.' : null,
  n(s.held) ? plural(n(s.held), 'booking was', 'bookings were') + ' held for your team to confirm.' : null,
  n(s.confirmed) || n(s.not_spam) ? 'Your team confirmed ' + n(s.confirmed) + ' as spam and marked ' + n(s.not_spam) + ' as not spam.' : null,
  n(s.open) ? plural(n(s.open), 'incident is', 'incidents are') + ' still waiting for review.' : 'Nothing is waiting for review.',
  'Open Spam protection for details.',
].filter(Boolean);
return {
  json: {
    body: {
      p_business_id: r.business_id,
      p_week_start: r.week_start,
      p_title: 'Spam protection: ' + plural(total, 'incident', 'incidents') + ' last week',
      p_body: lines.join(' '),
    },
  },
};
