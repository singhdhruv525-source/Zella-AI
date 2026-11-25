// Settings > Billing and subscription > Auto reload: what one resource's form can offer, read safely from
// zella_billing_overview (sql/zella_billing_allowances.sql). Pure, so it is tested without a browser (tests/autoReload.test.mjs).

// { packs, current } for "minutes", "texts" or "emails". A missing or broken list gives no packs, never a crash.
export function autoReloadChoices(overview, resource) {
  const list = (v) => (Array.isArray(v) ? v.filter((x) => x && typeof x === "object") : []);
  return {
    packs: list(overview?.packs).filter((p) => p.resource === resource && p.code),
    current: list(overview?.auto_reload).find((a) => a.resource === resource) ?? null,
  };
}
