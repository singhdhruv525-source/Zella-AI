// The tabs of one business's page and their addresses: /businesses/<id>/<slug> (BIZ-30). Slugs are single words, so
// they never clash with "setup" (the wizard) or need a dash. Pure: tested in web/tests/businessTabs.test.mjs.
export const DETAIL_TABS = [
  { slug: "overview", label: "Overview" },
  { slug: "configuration", label: "Configuration" },
  { slug: "people", label: "People" },
  { slug: "receptionist", label: "AI receptionist" },
  { slug: "phone", label: "Phone & integrations" },
  { slug: "automations", label: "Automations" },
  { slug: "calls", label: "Calls" },
  { slug: "activity", label: "Activity" },
];
export const DEFAULT_TAB = "overview";
export const isDetailTab = (slug) => DETAIL_TABS.some((t) => t.slug === slug);

// Where focus goes from tab `index` of `count` for a key (roving tabindex, WAI-ARIA tabs), or null for other keys.
export function tabKeyTarget(key, index, count) {
  if (key === "ArrowRight") return (index + 1) % count;
  if (key === "ArrowLeft") return (index - 1 + count) % count;
  if (key === "Home") return 0;
  if (key === "End") return count - 1;
  return null;
}
