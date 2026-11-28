// The words for the one server definition of connected, answering and live (docs/PRODUCT.md §9.1,
// sql/zella_connection_state.sql). Pages show what the server says and never work it out themselves.
import { formatDate } from "./ownerFormat.js";

export const NOT_TRACKED = "Not tracked";

// How long ago, in words for a sentence: "just now", "5 minutes ago", "yesterday", "5 days ago", then the date.
// Never "5 d ago" (docs/DESIGN_SYSTEM.md, Writing).
export function relativeText(value, now = Date.now()) {
  if (!value) return "";
  const t = new Date(value).getTime();
  if (Number.isNaN(t)) return "";
  const plural = (n, w) => `${n} ${w}${n === 1 ? "" : "s"}`;
  const minutes = Math.round((now - t) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${plural(minutes, "minute")} ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${plural(hours, "hour")} ago`;
  const days = Math.round(hours / 24);
  if (days === 1) return "yesterday";
  if (days < 30) return `${plural(days, "day")} ago`;
  return `on ${formatDate(value)}`;
}

// 1203 -> "1,203". Missing stays missing ("").
const countFormat = new Intl.NumberFormat("en-US");
export const countText = (n) => (n === null || n === undefined || n === "" || !Number.isFinite(Number(n)) ? "" : countFormat.format(Number(n)));

// When the definition isn't available yet (connectionsAvailable false), nothing is called live or not live.
export function livePill(row, available = true) {
  if (!available) return ["neutral", "Not available"];
  if (row?.live === true) return ["success", "Live"];
  if (row?.status === "paused") return ["warning", "Paused"];
  if (row?.status === "disabled") return ["neutral", "Off"];
  if (row?.businessState === "suspended") return ["warning", "Business suspended"];
  if (row?.businessState === "cancelled") return ["neutral", "Business cancelled"];
  if (row?.status === "active") return ["neutral", "Not live"];
  return ["neutral", "Unknown"];
}

// Answering is its own state: a call served in the last 7 days. It is never folded into live.
export function answeringText(answering, lastServedAt, available = true) {
  if (!available) return "Answering not available";
  if (answering) return lastServedAt ? `Answered a call ${relativeText(lastServedAt)}` : "Answering calls";
  return lastServedAt ? `No call answered in 7 days (last ${relativeText(lastServedAt)})` : "No call answered yet";
}

// What a business still needs before the receptionist can be live (in the order an admin fixes them).
export function missingForLive(row) {
  const out = [];
  if (row?.businessState && row.businessState !== "active") out.push(row.businessState === "setup" ? "setup finished" : `business ${row.businessState}`);
  if (row?.status && row.status !== "active") out.push("AI receptionist switched on");
  if (!row?.checks?.phone) out.push("an active phone number");
  else if (!row?.checks?.voice) out.push("the number linked to Vapi");
  return out;
}

// COM-03: what calls actually got (assistant_deliveries). Plain words for each outcome.
export const OUTCOME = {
  served: ["success", "Served"],
  not_ready: ["danger", "Not ready"],
  unknown_number: ["warning", "Unknown number"],
  forwarded_usage: ["neutral", "Forwarded, over its limit"],
};
export const outcomePill = (outcome) => OUTCOME[outcome] ?? ["neutral", "Unknown"];

// The version line: which version calls got last, and the published one with its sync state.
export function versionText(d) {
  if (!d) return "Not available";
  const parts = [];
  if (d.servedVersion != null) parts.push(`Serving version ${d.servedVersion}`);
  if (d.publishedVersion != null && d.publishedVersion !== d.servedVersion) parts.push(`published version ${d.publishedVersion}`);
  if (d.syncStatus === "failed") parts.push("last check failed");
  return parts.length ? parts.join(", ") : "No version served yet";
}

// One delivery problem as text (the server stores plain text lines; anything else is shown as given).
export const problemText = (p) => (typeof p === "string" ? p : p && typeof p === "object" ? Object.values(p).filter((v) => typeof v === "string").join(": ") || JSON.stringify(p) : String(p));
