// What an audit row changed, in words, for the Activity tab (BIZ-17). Pure: web/tests/businessChanges.test.mjs.
import { humanize } from "../copy/labels.js";

const short = (v) => {
  if (v === null || v === undefined || v === "") return "not set";
  const text = typeof v === "object" ? (Array.isArray(v) ? v.map(String).join(", ") || "none" : JSON.stringify(v)) : String(v);
  return text.length > 60 ? `${text.slice(0, 57)}…` : text;
};

// "Suspended at: not set → 16 Nov" lines for the fields that changed (at most 5).
export function changeLines(oldData, newData) {
  const before = oldData && typeof oldData === "object" ? oldData : {};
  const after = newData && typeof newData === "object" ? newData : {};
  const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])]
    .filter((k) => JSON.stringify(before[k] ?? null) !== JSON.stringify(after[k] ?? null));
  return keys.slice(0, 5).map((k) => `${humanize(k)}: ${k in before ? `${short(before[k])} → ` : ""}${short(after[k])}`);
}
