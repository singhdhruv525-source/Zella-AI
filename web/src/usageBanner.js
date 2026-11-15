// The words for the usage banners on Today (UsageLive.jsx). Words only; the database decides what actually happens.
export const fmt = (v) => Number(v ?? 0).toLocaleString("en-US", { maximumFractionDigits: 0 });

// The banner for one resource at 80% or 100%. Words only; the database decides what actually happens.
export function usageBanner(resource, u, daysLeft) {
  if (!u?.configured || !(Number(u.included) > 0)) return null;
  const pct = Number(u.percent_used ?? 0);
  if (pct < 80) return null;
  const out = Boolean(u.exhausted) || pct >= 100;
  const days = Number.isFinite(daysLeft) ? `${daysLeft} ${daysLeft === 1 ? "day" : "days"} to go` : "this period";
  if (resource === "minutes") {
    return out
      ? { tone: "urgent", kicker: "Action needed", title: "This month's minutes are used up",
          body: `${fmt(u.used)} of ${fmt(u.included)} minutes used. Add minutes or turn on auto reload so your receptionist keeps answering every call.`, action: "Add minutes" }
      : { tone: "heads", kicker: "Heads up", title: "Your receptionist has been busy this month",
          body: `${fmt(u.used)} of ${fmt(u.included)} minutes used, ${days}. Every call is still being answered.`, action: "Add minutes" };
  }
  const word = resource === "texts" ? "texts" : "emails";
  return out
    ? { tone: "heads", kicker: "Paused for now", title: `Routine ${word} are on hold`,
        body: `This month's ${word} are used up. Appointment confirmations and reminders still go out from your reserve (${fmt(u.buffer_remaining)} of ${fmt(u.buffer)} left).`, action: `Add a ${word} pack` }
    : { tone: "heads", kicker: "Heads up", title: `Your ${word} are running low`,
        body: `${fmt(u.used)} of ${fmt(u.included)} ${word} used, ${days}. At 100%, routine ${word} pause; appointment messages keep going.`, action: `Add a ${word} pack` };
}

