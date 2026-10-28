import { useState } from "react";
import { supabase } from "./supabase";
import { Empty, PageHead, Segment, friendly, useLoad } from "./BusinessShared";

// Scorecards: how each person is doing with callbacks, leads and tasks, and how each bookable team member's
// appointments went, for a period. Owners, admins and managers see everyone; others see their own.
// Database: zella_staff_scorecards (sql/zella_scorecards.sql), read-only.

const RANGES = [["7", "7 days"], ["30", "30 days"], ["90", "90 days"]];
const missing = (e) => e && (e.code === "PGRST202" || /could not find|does not exist/i.test(e.message ?? ""));
const n = (v) => (v === null || v === undefined ? "—" : v);
const minutes = (v) => (v === null || v === undefined ? "—" : v < 90 ? `${v} min` : `${Math.round(v / 6) / 10} h`);
const hours = (v) => (v === null || v === undefined ? "—" : v < 48 ? `${v} h` : `${Math.round(v / 2.4) / 10} days`);
const pct = (part, whole) => (whole ? `${Math.round((part / whole) * 100)}%` : "—");

export default function ScorecardsPage({ workspace }) {
  const [range, setRange] = useState("30");
  const { data, error, loading, reload } = useLoad(async () => {
    const to = new Date();
    const { data: result, error: loadError } = await supabase.rpc("zella_staff_scorecards", {
      p_business_id: workspace.id, p_from: new Date(to.getTime() - Number(range) * 86400000).toISOString(), p_to: to.toISOString(),
    });
    if (loadError) { if (missing(loadError)) return { missing: true }; throw new Error(friendly(loadError)); }
    return result;
  }, [workspace.id, range]);

  const head = <PageHead crumb="Team & Staff / Scorecards" title="Scorecards" sub="Callbacks, leads and tasks per person, and how each team member's appointments went." />;
  if (data?.missing) return <>{head}<Empty icon="leaderboard" title="Scorecards aren't set up yet">The Zella team needs to apply its latest database update.</Empty></>;

  const people = data?.people ?? [];
  const bookable = data?.bookable ?? [];
  return (
    <>
      {head}
      <Segment value={range} onChange={setRange} options={RANGES} label="Period" />
      {error && <div className="ba-banner error"><span>{error}</span><button type="button" className="ba-btn sm" onClick={reload}>Try again</button></div>}
      {data && !data.everyone && <p className="ba-muted sc-note">You're seeing your own scorecard. Owners and managers see the whole team.</p>}

      <section className="ba-panel ba-gap">
        <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>People</h2><p>Work given to each person who signs in, for the last {range} days. Overdue counts are as of now.</p></div></div></div>
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !people.length ? (
          <div className="ba-panel-body"><Empty icon="groups" title="No one to show">People appear here once they're part of the team.</Empty></div>
        ) : (
          <div className="sc-table-wrap">
            <table className="sc-table">
              <thead>
                <tr><th rowSpan={2}>Person</th><th colSpan={4}>Callbacks</th><th colSpan={4}>Leads</th><th colSpan={2}>Tasks</th></tr>
                <tr><th>Given</th><th>Done</th><th>First call</th><th>Overdue</th><th>Given</th><th>Won</th><th>Lost</th><th>First contact</th><th>Done</th><th>Overdue</th></tr>
              </thead>
              <tbody>
                {people.map((p) => (
                  <tr key={p.user_id}>
                    <th scope="row">{p.name}{p.you && p.name !== "You" ? " (you)" : ""}<small>{p.role}</small></th>
                    <td>{n(p.callbacks.assigned)}</td>
                    <td>{n(p.callbacks.completed)}</td>
                    <td>{minutes(p.callbacks.median_minutes_to_first_call)}</td>
                    <td className={p.callbacks.overdue_now ? "warn" : ""}>{n(p.callbacks.overdue_now)}</td>
                    <td>{n(p.leads.assigned)}</td>
                    <td>{n(p.leads.won)}</td>
                    <td>{n(p.leads.lost)}</td>
                    <td>{hours(p.leads.median_hours_to_contact)}</td>
                    <td>{n(p.tasks.completed)}</td>
                    <td className={p.tasks.overdue_now ? "warn" : ""}>{n(p.tasks.overdue_now)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="ba-muted sc-foot">“First call” and “First contact” are medians: half were faster, half slower.</p>
      </section>

      {data?.everyone && (
        <section className="ba-panel ba-gap">
          <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Appointments by team member</h2><p>Appointments that started in the last {range} days.</p></div></div></div>
          {!bookable.length ? (
            <div className="ba-panel-body"><Empty icon="event" title="No bookable team members">Add the people customers book with on the Team page.</Empty></div>
          ) : (
            <div className="sc-table-wrap">
              <table className="sc-table">
                <thead><tr><th>Team member</th><th>Booked</th><th>Done</th><th>No-shows</th><th>No-show rate</th><th>Cancelled</th></tr></thead>
                <tbody>
                  {bookable.map((b) => (
                    <tr key={b.staff_id}>
                      <th scope="row">{b.name}{!b.active && <small>no longer works here</small>}</th>
                      <td>{b.booked}</td><td>{b.completed}</td>
                      <td className={b.no_shows ? "warn" : ""}>{b.no_shows}</td>
                      <td>{pct(b.no_shows, b.completed + b.no_shows)}</td>
                      <td>{b.cancelled}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}
    </>
  );
}
