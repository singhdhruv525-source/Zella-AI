// The words for the usage banners on Today (UsageLive.jsx). Words only; the database decides what actually happens.
export const fmt = (v) => Number(v ?? 0).toLocaleString("en-US", { maximumFractionDigits: 0 });

// The banner for one resource at 80% or 100%. It describes the limit, never what happens to calls or messages: the
// browser can't see whether usage limits are switched on (sql/zella_usage_enforcement.sql), so it never says that
// anything is paused or still going out.
export function usageBanner(resource, u, daysLeft) {
  if (!u?.configured || !(Number(u.included) > 0)) return null;
  const pct = Number(u.percent_used ?? 0);
  if (pct < 80) return null;
  const out = Boolean(u.exhausted) || pct >= 100;
  const days = Number.isFinite(daysLeft) ? `${daysLeft} ${daysLeft === 1 ? "day" : "days"} to go` : "this period";
  if (resource === "minutes") {
    return out
      ? { tone: "urgent", kicker: "Action needed", title: "This month's minutes are used up",
          body: `${fmt(u.used)} of ${fmt(u.included)} minutes used. Add minutes or turn on auto reload so your plan covers every call.`, action: "Add minutes" }
      : { tone: "heads", kicker: "Heads up", title: "Your AI receptionist has been busy this month",
          body: `${fmt(u.used)} of ${fmt(u.included)} minutes used, ${days}. Every call is still being answered.`, action: "Add minutes" };
  }
  const word = resource === "texts" ? "texts" : "emails";
  if (!out) {
    return { tone: "heads", kicker: "Heads up", title: `Your ${word} are running low`,
      body: `${fmt(u.used)} of ${fmt(u.included)} ${word} used, ${days}. Add a pack before you run out.`, action: `Add a ${word} pack` };
  }
  const reserveLeft = Number(u.buffer_remaining ?? 0), reserve = Number(u.buffer ?? 0);
  return reserveLeft > 0
    ? { tone: "heads", kicker: "Limit reached", title: `This month's ${word} are used up`,
        body: `${fmt(u.used)} of ${fmt(u.included)} ${word} used. Your small reserve for appointment confirmations and reminders has ${fmt(reserveLeft)} of ${fmt(reserve)} left.`, action: `Add a ${word} pack` }
    : { tone: "urgent", kicker: "Action needed", title: `This month's ${word} and reserve are used up`,
        body: `${fmt(u.used)} of ${fmt(u.included)} ${word} used, and the reserve for appointment messages is used up too. Add a pack to cover the rest of the month.`, action: `Add a ${word} pack` };
}

