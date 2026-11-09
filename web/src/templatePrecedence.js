// Which message templates apply to one business, in the same order the database picks them (zella_resolve_template):
// the business's own version, then Zella's version for its industry, then Zella's general version; newest first.
// A person in several businesses can read every one of their businesses' templates (row security allows it), so the
// list is always narrowed to the business being viewed here.

export function templatesForBusiness(rows, businessId, industryId) {
  const mine = (rows || []).filter((t) =>
    t.business_id === businessId || (t.business_id == null && (t.industry_id == null || t.industry_id === industryId)));
  const rank = (t) => [t.business_id ? 0 : 1, t.industry_id ? 0 : 1, -(t.version || 0)];
  const cmp = (a, b) => { const x = rank(a), y = rank(b); for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; };
  const inUse = new Map();
  for (const t of [...mine].filter((t) => t.status === "active").sort(cmp)) {
    const slot = `${t.key}|${t.channel}|${t.locale || "en-US"}`;
    if (!inUse.has(slot)) inUse.set(slot, t.id);
  }
  return mine
    .map((t) => ({ ...t, source: t.business_id ? "Yours" : t.industry_id ? "Zella Voice (your industry)" : "Zella Voice",
      inUse: inUse.get(`${t.key}|${t.channel}|${t.locale || "en-US"}`) === t.id }))
    .sort((a, b) => a.key.localeCompare(b.key) || a.channel.localeCompare(b.channel) || cmp(a, b));
}
