// Zella - Spam Response: repeat-offender check for incidents that need a closer look. Uses only the counts the
// database handed over (never another business's name or messages) and writes down what was found. Any action
// that follows (a temporary restriction, a platform alert) is decided by the database's approved policy.
const s = $json;
const f = s.facts || {};
const n = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
const findings = [];
if (n(f.here_confirmed) > 0) findings.push('confirmed_here_' + n(f.here_confirmed));
else if (n(f.here_prior) > 0) findings.push('seen_here_before');
if (n(f.other_confirmed) > 0) findings.push('confirmed_elsewhere_' + n(f.other_confirmed));
else if (n(f.other_businesses) > 0) findings.push('seen_elsewhere');
if (f.platform_rule === true) findings.push('platform_rule');
const repeat = n(f.here_confirmed) >= 2 || n(f.other_confirmed) >= 2;
return {
  json: {
    ...s,
    finish: { ...s.finish, p_result: { ...s.finish.p_result, route: 'investigate', repeat_offender: repeat, findings } },
  },
};
