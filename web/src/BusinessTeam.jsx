import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials } from "./BusinessUI";
import { makeTerm } from "./businessWorkspace";
import { formatDay, formatTime, timeAgo, todayInput } from "./businessTime";
import {
  DAYS, Empty, Notice, PageHead, availabilityAt, defaultHours, friendly, orThrow, plural, useLoad,
} from "./BusinessShared";
import { BlockTimeModal } from "./BusinessPages";
import { EmailField, PhoneField } from "./formFields";
import { checkEmail, validatePhone } from "./formValidation";

// Team: the people customers book with (stylists, dentists, servers,
// technicians... the words follow the industry), their weekly hours and
// breaks, and who is away. Sign-in accounts are listed underneath.

const COLORS = ["#6F4E37", "#6B5B95", "#15803D", "#D97706", "#DC2626", "#7C3AED", "#DB2777", "#0F766E"];

function StaffModal({ workspace, member, count, onClose, onSaved }) {
  const term = makeTerm(workspace);
  const editing = Boolean(member);
  const [form, setForm] = useState({
    name: member?.name ?? "", title: member?.title ?? "", phone: member?.phone ?? "", email: member?.email ?? "",
    color: member?.color ?? COLORS[count % COLORS.length], is_active: member?.is_active ?? true,
  });
  const [hours, setHours] = useState(() => ({ ...defaultHours(), ...(member?.working_hours ?? {}) }));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showErrors, setShowErrors] = useState(false);
  const set = (key) => (e) => setForm({ ...form, [key]: e.target.type === "checkbox" ? e.target.checked : e.target.value });
  const setDay = (day, key, value) => setHours({ ...hours, [day]: { ...hours[day], [key]: value } });

  async function save(event) {
    event.preventDefault();
    setShowErrors(true);
    if (!form.name.trim()) return setError(`Enter the ${term("staff").toLowerCase()}'s name.`);
    if (validatePhone(form.phone)) return setError(`Phone: ${validatePhone(form.phone)}`);
    if (checkEmail(form.email)) return setError(`Email: ${checkEmail(form.email)}`);
    for (const [key, label] of DAYS) {
      const d = hours[key];
      if (!d.on) continue;
      if (!d.start || !d.end || d.end <= d.start) return setError(`${label}: the finish time must be after the start time.`);
      if ((d.break_start || d.break_end) && (!d.break_start || !d.break_end || d.break_end <= d.break_start || d.break_start < d.start || d.break_end > d.end)) {
        return setError(`${label}: the break must fall inside working hours.`);
      }
    }
    setBusy(true);
    setError("");
    const values = {
      name: form.name.trim(), title: form.title.trim() || null, phone: form.phone.trim() || null,
      email: form.email.trim() ? form.email.trim().toLowerCase() : null, color: form.color,
      is_active: form.is_active, working_hours: hours, updated_at: new Date().toISOString(),
    };
    const result = editing
      ? await supabase.from("staff_members").update(values).eq("id", member.id)
      : await supabase.from("staff_members").insert({ ...values, business_id: workspace.id, sort_order: count });
    setBusy(false);
    if (result.error) return setError(friendly(result.error));
    onSaved(editing ? `${values.name} updated.` : `${values.name} added to your team.`);
  }

  return (
    <Modal
      wide
      title={editing ? `Edit ${member.name}` : `Add ${term("staff").toLowerCase()}`}
      description="Working hours and breaks decide when this person can be booked. Your AI receptionist follows them."
      onClose={onClose}
      busy={busy}
    >
      <form className="ba-form-grid ba-modal-body" onSubmit={save}>
        {error && <div className="ba-banner error full">{error}</div>}
        <Field label="Name"><input value={form.name} onChange={set("name")} required autoFocus /></Field>
        <Field label="Role" hint="For example: Senior stylist, Hygienist, Head waiter"><input value={form.title} onChange={set("title")} /></Field>
        <Field label="Phone" bare><PhoneField value={form.phone} onChange={(phone) => setForm((f) => ({ ...f, phone }))} showErrors={showErrors} label="Phone" /></Field>
        <Field label="Email" bare><EmailField value={form.email} onChange={(email) => setForm((f) => ({ ...f, email }))} showErrors={showErrors} /></Field>
        <div className="full">
          <span className="ba-label">Calendar colour</span>
          <div className="ba-swatches" role="radiogroup" aria-label="Calendar colour">
            {COLORS.map((c) => (
              <button key={c} type="button" role="radio" aria-checked={form.color === c} aria-label={c}
                className={form.color === c ? "on" : ""} style={{ background: c }} onClick={() => setForm({ ...form, color: c })} />
            ))}
          </div>
        </div>

        <div className="full">
          <span className="ba-label">Weekly hours and daily break</span>
          <div className="ba-hours">
            <div className="ba-hours-head"><span /><span>From</span><span>Until</span><span>Break from</span><span>Break until</span></div>
            {DAYS.map(([key, label]) => {
              const d = hours[key];
              return (
                <div key={key} className={`ba-hours-row ${d.on ? "" : "off"}`}>
                  <label className="ba-check"><input type="checkbox" checked={d.on} onChange={(e) => setDay(key, "on", e.target.checked)} /><span>{label}</span></label>
                  <input type="time" value={d.start} disabled={!d.on} onChange={(e) => setDay(key, "start", e.target.value)} aria-label={`${label} start`} />
                  <input type="time" value={d.end} disabled={!d.on} onChange={(e) => setDay(key, "end", e.target.value)} aria-label={`${label} finish`} />
                  <input type="time" value={d.break_start} disabled={!d.on} onChange={(e) => setDay(key, "break_start", e.target.value)} aria-label={`${label} break start`} />
                  <input type="time" value={d.break_end} disabled={!d.on} onChange={(e) => setDay(key, "break_end", e.target.value)} aria-label={`${label} break end`} />
                </div>
              );
            })}
          </div>
        </div>

        {editing && (
          <label className="ba-check full">
            <input type="checkbox" checked={form.is_active} onChange={set("is_active")} />
            <span>Currently works here (untick when they leave, their history stays)</span>
          </label>
        )}
        <div className="full ba-form-actions">
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : editing ? "Save changes" : `Add ${term("staff").toLowerCase()}`}</button>
        </div>
      </form>
    </Modal>
  );
}

export function TeamPage({ workspace, email, refreshKey, onNotice }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const [me, setMe] = useState(null);
  const [editing, setEditing] = useState(null); // member, "new" or null
  const [blockFor, setBlockFor] = useState(null); // staff id or "" for everyone
  const [tick, setTick] = useState(0);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setMe(data?.user?.id ?? null)).catch(() => {});
    const timer = setInterval(() => setTick((t) => t + 1), 60000); // keep "available now" fresh
    return () => clearInterval(timer);
  }, []);

  const { data, error, loading, reload } = useLoad(async () => {
    const staffResult = await supabase.from("staff_members").select("*").eq("business_id", workspace.id).order("sort_order").order("name");
    const blocksResult = await supabase.from("blocked_times").select("*").eq("business_id", workspace.id)
      .gt("end_time", new Date(Date.now() - 3600000).toISOString()).order("start_time").limit(200);
    const logins = orThrow(await supabase.from("business_members").select("id, user_id, role, status, created_at").eq("business_id", workspace.id).order("created_at"));
    return {
      staff: staffResult.error ? [] : staffResult.data ?? [],
      staffMissing: Boolean(staffResult.error),
      blocks: blocksResult.error ? [] : blocksResult.data ?? [],
      logins,
    };
  }, [workspace.id, refreshKey]);

  const staff = data?.staff ?? [];
  const active = staff.filter((m) => m.is_active);
  const away = (data?.blocks ?? []).filter((b) => new Date(b.end_time) > new Date());
  const nameOf = Object.fromEntries(staff.map((m) => [m.id, m.name]));
  const now = new Date();
  void tick;

  async function removeBlock(block) {
    const { error: deleteError } = await supabase.from("blocked_times").delete().eq("id", block.id);
    if (deleteError) return onNotice(friendly(deleteError));
    onNotice("Removed. The time is open again.");
    reload();
  }

  return (
    <>
      <PageHead
        crumb="Management / Team"
        title="Team"
        sub={`${term("staff_plural")}, their hours and breaks, and who is away. Your AI receptionist only books people who are available.`}
      >
        <button type="button" className="ba-btn" onClick={() => setBlockFor("")}><Icon name="block" size="sm" /><span>Block time</span></button>
        <button type="button" className="ba-btn primary" onClick={() => setEditing("new")}><Icon name="person_add" size="sm" /><span>Add {term("staff").toLowerCase()}</span></button>
      </PageHead>

      <Notice error={error} onRetry={reload} />
      {data?.staffMissing && (
        <div className="ba-banner error"><span>Team availability needs the latest Zella update. Please ask the Zella team to apply it.</span></div>
      )}

      <section className="ba-panel">
        <div className="ba-panel-head">
          <div className="ba-panel-title"><div><h2>{term("staff_plural")}</h2><p>{loading && !data ? "Loading…" : plural(active.length, "active person", "active people")}</p></div></div>
        </div>
        {!staff.length && !loading ? (
          <div className="ba-panel-body"><Empty title={`No ${term("staff_plural").toLowerCase()} added yet`}>Add the people customers book with so you can set their hours, breaks and time off.</Empty></div>
        ) : (
          <ul className="ba-staff">
            {staff.map((m) => {
              const a = m.is_active ? availabilityAt(m, data.blocks, now, tz) : { state: "off", label: "No longer works here" };
              return (
                <li key={m.id} className={m.is_active ? "" : "inactive"}>
                  <span className="ba-staff-avatar" style={{ background: m.color }}>{initials(m.name)}</span>
                  <div className="ba-staff-main">
                    <strong>{m.name}</strong>
                    <small>{[m.title, m.phone].filter(Boolean).join(" · ") || term("staff")}</small>
                  </div>
                  <span className={`ba-who ${a.state}`}><i /><small>{a.label}</small></span>
                  <div className="ba-staff-actions">
                    {m.is_active && <button type="button" className="ba-btn sm" onClick={() => setBlockFor(m.id)}>Time off</button>}
                    <button type="button" className="ba-btn sm" onClick={() => setEditing(m)}>Edit hours</button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      <section className="ba-panel ba-gap">
        <div className="ba-panel-head">
          <div className="ba-panel-title"><div><h2>Time off and blocked time</h2><p>Upcoming. These times can't be booked.</p></div></div>
        </div>
        {!away.length ? (
          <div className="ba-panel-body"><Empty title="Nothing blocked">Use Block time for lunch, leave, holidays or training.</Empty></div>
        ) : (
          <ul className="ba-threads">
            {away.map((b) => (
              <li key={b.id}>
                <span className="ba-thread-icon"><Icon name="block" size="sm" /></span>
                <div>
                  <strong>{b.title}: {b.staff_id ? nameOf[b.staff_id] ?? "Team member" : "Whole business"}</strong>
                  <small>{b.all_day ? `${formatDay(b.start_time, tz)} to ${formatDay(new Date(new Date(b.end_time).getTime() - 60000), tz)}, all day` : `${formatDay(b.start_time, tz)} · ${formatTime(b.start_time, tz)} to ${formatTime(b.end_time, tz)}`}{b.reason ? ` · ${b.reason}` : ""}</small>
                </div>
                <div className="ba-thread-meta"><button type="button" className="ba-btn sm" onClick={() => removeBlock(b)}>Remove</button></div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="ba-panel ba-gap">
        <div className="ba-panel-head">
          <div className="ba-panel-title"><div><h2>Who can sign in</h2><p>Accounts with access to this workspace. To add or remove one, ask the Zella team.</p></div></div>
        </div>
        <ul className="ba-threads">
          {(data?.logins ?? []).map((m) => {
            const mine = m.user_id === me;
            const label = mine ? email : "Team member";
            return (
              <li key={m.id}>
                <span className="ba-avatar sm">{initials(label)}</span>
                <div><strong>{label}{mine ? " (you)" : ""}</strong><small>Joined {timeAgo(m.created_at)}</small></div>
                <div className="ba-thread-meta">
                  <Pill tone="indigo">{m.role}</Pill>
                  <Pill tone={m.status === "active" ? "success" : m.status === "invited" ? "warning" : ""}>{m.status}</Pill>
                </div>
              </li>
            );
          })}
        </ul>
      </section>

      {editing && (
        <StaffModal
          workspace={workspace}
          member={editing === "new" ? null : editing}
          count={staff.length}
          onClose={() => setEditing(null)}
          onSaved={(message) => { setEditing(null); onNotice(message); reload(); }}
        />
      )}
      {blockFor !== null && (
        <BlockTimeModal
          workspace={workspace}
          staff={active}
          defaultStaffId={blockFor}
          defaultDate={todayInput(tz)}
          onClose={() => setBlockFor(null)}
          onSaved={(message) => { setBlockFor(null); onNotice(message); reload(); }}
        />
      )}
    </>
  );
}
