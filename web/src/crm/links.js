// B3-07: linked-record titles for the rows on screen. Pure helpers (tests/batch3_unit.test.mjs).
export const LINK_BATCH = 100;   // ids per request; a page of 25 rows has at most 25 x (record columns) ids
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// the distinct, well-formed ids that the shown rows link to through their "Link to another record" columns
export function linkIdsOf(rows, cols) {
  const linkCols = (cols ?? []).filter((c) => c.type === "record");
  if (!linkCols.length) return [];
  return [...new Set((rows ?? []).flatMap((r) => linkCols.map((c) => r?.data?.[c.key])).filter((v) => typeof v === "string" && UUID.test(v)))].sort();
}

// what a link cell says: the title; "…" while loading; a clear word when it can't be read or no longer exists
export function linkTitle(titles, id) {
  if (titles && typeof titles === "object" && "status" in titles && "map" in titles) {
    if (titles.map[id] !== undefined) return titles.map[id];
    if (titles.status === "loading") return "…";
    if (titles.status === "failed") return "Couldn't load";
    return "Unavailable record";
  }
  return titles?.[id] ?? "Linked record";
}
