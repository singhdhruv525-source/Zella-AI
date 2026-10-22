import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import { Field, Modal, personName } from "./BusinessUI";
import { todayInput, zonedDateTime } from "./businessTime";
import { findConflict, friendly } from "./BusinessShared";
import { EmailField, PhoneField } from "./formFields";
import { checkEmail, validatePhone } from "./formValidation";

// Quick actions from the header: add a lead and book an appointment.
// Both write with the signed-in member's session, so Row Level Security
// only allows records for their own business.

const SOURCES = [
  ["manual", "Added by team"],
  ["phone", "Phone call"],
  ["walk_in", "Walk-in"],
  ["website", "Website"],
  ["google", "Google"],
  ["meta", "Facebook / Instagram"],
  ["referral", "Referral"],
  ["other", "Other"],
];


export function AddLeadModal({ workspace, term, onClose, onSaved }) {
  const [form, setForm] = useState({ first_name: "", last_name: "", phone: "", email: "", source: "manual", notes: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showErrors, setShowErrors] = useState(false);
  const set = (key) => (event) => setForm({ ...form, [key]: event.target.value });

  async function save(event) {
    event.preventDefault();
    setShowErrors(true);
    const values = Object.fromEntries(Object.entries(form).map(([k, v]) => [k, v.trim()]));
    if (!values.first_name && !values.last_name) return setError("Enter a name.");
    if (!values.phone && !values.email) return setError("Enter a phone number or email so you can follow up.");
    if (validatePhone(values.phone)) return setError(`Phone: ${validatePhone(values.phone)}`);
    if (checkEmail(values.email)) return setError(`Email: ${checkEmail(values.email)}`);

    setBusy(true);
    setError("");
    const { data, error: insertError } = await supabase
      .from("customers")
      .insert({
        business_id: workspace.id,
        first_name: values.first_name || null,
        last_name: values.last_name || null,
        phone: values.phone || null,
        email: values.email ? values.email.toLowerCase() : null,
        source: values.source,
        notes: values.notes || null,
        status: "active",
      })
      .select("id, first_name, last_name")
      .single();
    setBusy(false);

    if (insertError) return setError(insertError.message);
    onSaved(`${personName(data) ?? "New lead"} was added.`);
  }

  return (
    <Modal
      title="Add a lead"
      description={`A new enquiry. They'll appear in your ${term("customers").toLowerCase()} and on Today.`}
      onClose={onClose}
      busy={busy}
      footer={
        <>
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" form="ba-add-lead" className="ba-btn primary" disabled={busy}>
            {busy ? "Saving..." : "Add lead"}
          </button>
        </>
      }
    >
      <form id="ba-add-lead" className="ba-modal-body" onSubmit={save}>
        <div className="ba-form-grid">
          <Field label="First name"><input value={form.first_name} onChange={set("first_name")} autoFocus /></Field>
          <Field label="Last name"><input value={form.last_name} onChange={set("last_name")} /></Field>
          <Field label="Phone" bare><PhoneField value={form.phone} onChange={(phone) => setForm((f) => ({ ...f, phone }))} showErrors={showErrors} label="Phone" /></Field>
          <Field label="Email" bare><EmailField value={form.email} onChange={(email) => setForm((f) => ({ ...f, email }))} showErrors={showErrors} /></Field>
          <Field label="Where did they come from?" full>
            <select value={form.source} onChange={set("source")}>
              {SOURCES.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </select>
          </Field>
          <Field label="Notes" full>
            <textarea value={form.notes} onChange={set("notes")} placeholder="What are they looking for?" />
          </Field>
        </div>
        {error && <div className="ba-error">{error}</div>}
        {conflict && (
          <label className="ba-check">
            <input type="checkbox" checked={force} onChange={(e) => setForce(e.target.checked)} />
            <span>Book anyway</span>
          </label>
        )}
      </form>
    </Modal>
  );
}

export function BookAppointmentModal({ workspace, term, onClose, onSaved, initial }) {
  const tz = workspace.timezone;
  const [query, setQuery] = useState("");
  const [results, setResults] = useState([]);
  const [customer, setCustomer] = useState(null);
  const [form, setForm] = useState({
    title: "",
    date: initial?.date || todayInput(tz),
    time: initial?.time || "09:00",
    duration: "30",
    location: "",
    description: "",
    staffId: initial?.staffId || "",
    partySize: "",
  });
  const [staff, setStaff] = useState([]);
  const [conflict, setConflict] = useState("");
  const [force, setForce] = useState(false);
  const hospitality = /restaurant|cafe|café|bar\b|food|dining|hotel|catering/i.test(`${workspace.industry ?? ""} ${term("appointment")}`);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (key) => (event) => {
    setForm({ ...form, [key]: event.target.value });
    if (["date", "time", "duration"].includes(key)) { setConflict(""); setForce(false); setError(""); }
  };

  // The people customers can book with. Optional: not every business adds them.
  useEffect(() => {
    let active = true;
    supabase.from("staff_members").select("id, name, working_hours, is_active").eq("business_id", workspace.id).eq("is_active", true).order("sort_order").order("name")
      .then(({ data, error: staffError }) => { if (active && !staffError) setStaff(data ?? []); });
    return () => { active = false; };
  }, [workspace.id]);

  // Find an existing customer by name, phone or email.
  useEffect(() => {
    const q = query.trim();
    if (q.length < 2 || customer) {
      setResults([]);
      return undefined;
    }
    const safe = q.replace(/[%*,()]/g, " ").trim();
    const timer = setTimeout(async () => {
      const { data } = await supabase
        .from("customers")
        .select("id, first_name, last_name, company_name, phone, email")
        .eq("business_id", workspace.id)
        .or(`first_name.ilike.*${safe}*,last_name.ilike.*${safe}*,phone.ilike.*${safe}*,email.ilike.*${safe}*`)
        .limit(8);
      setResults(data ?? []);
    }, 250);
    return () => clearTimeout(timer);
  }, [query, customer, workspace.id]);

  async function save(event) {
    event.preventDefault();
    if (!form.title.trim()) return setError(`Give the ${term("appointment").toLowerCase()} a title.`);
    if (!form.date || !form.time) return setError("Choose a date and time.");

    const start = zonedDateTime(form.date, form.time, tz);
    const end = new Date(start.getTime() + Number(form.duration) * 60000);

    setBusy(true);
    setError("");

    // Don't book into a break, a day off or blocked time unless they choose to.
    if (!force) {
      const blockResult = await supabase.from("blocked_times").select("*").eq("business_id", workspace.id)
        .lt("start_time", end.toISOString()).gt("end_time", start.toISOString());
      const message = findConflict({ staff, blocks: blockResult.error ? [] : blockResult.data ?? [], start, end, staffId: form.staffId, timeZone: tz });
      if (message) {
        setBusy(false);
        setConflict(message);
        return setError(message);
      }
    }

    const { error: insertError } = await supabase.from("appointments").insert({
      ...(form.staffId ? { staff_id: form.staffId } : {}),
      ...(form.partySize ? { party_size: Number(form.partySize) } : {}),
      business_id: workspace.id,
      customer_id: customer?.id ?? null,
      title: form.title.trim(),
      start_time: start.toISOString(),
      end_time: end.toISOString(),
      timezone: tz,
      status: "scheduled",
      location: form.location.trim() || null,
      description: form.description.trim() || null,
    });
    setBusy(false);

    if (insertError) return setError(friendly(insertError));
    onSaved(`${term("appointment")} booked${customer ? ` for ${personName(customer)}` : ""}.`);
  }

  return (
    <Modal
      title={`Book ${term("appointment").toLowerCase()}`}
      description={`Times are in ${workspace.name}'s time zone (${tz.replace("_", " ")}).`}
      onClose={onClose}
      busy={busy}
      footer={
        <>
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" form="ba-book" className="ba-btn primary" disabled={busy}>
            {busy ? "Booking..." : "Book"}
          </button>
        </>
      }
    >
      <form id="ba-book" className="ba-modal-body" onSubmit={save}>
        <Field label={term("customer")} hint={customer ? undefined : "Search by name, phone or email. Optional."}>
          {customer ? (
            <div className="ba-status-row">
              <strong>{personName(customer) ?? customer.phone}</strong>
              <button type="button" className="ba-link" onClick={() => { setCustomer(null); setQuery(""); }}>Change</button>
            </div>
          ) : (
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder={`Find a ${term("customer").toLowerCase()}`} />
          )}
        </Field>
        {!customer && results.length > 0 && (
          <div className="ba-picker">
            {results.map((r) => (
              <button type="button" key={r.id} onClick={() => setCustomer(r)}>
                <strong>{personName(r) ?? "Unnamed"}</strong>
                <span>{r.phone || r.email || ""}</span>
              </button>
            ))}
          </div>
        )}
        <div className="ba-form-grid">
          <Field label="Title" full>
            <input value={form.title} onChange={set("title")} placeholder={`e.g. ${term("service")}`} />
          </Field>
          <Field label="Date"><input type="date" value={form.date} onChange={set("date")} required /></Field>
          <Field label="Start time"><input type="time" value={form.time} onChange={set("time")} required /></Field>
          <Field label="Length">
            <select value={form.duration} onChange={set("duration")}>
              {[15, 30, 45, 60, 90, 120].map((m) => (
                <option key={m} value={m}>{m < 60 ? `${m} min` : `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ""}`}</option>
              ))}
            </select>
          </Field>
          {staff.length > 0 && (
            <Field label={`With (${term("staff").toLowerCase()})`}>
              <select value={form.staffId} onChange={(e) => { setForm({ ...form, staffId: e.target.value }); setConflict(""); setForce(false); setError(""); }}>
                <option value="">Anyone</option>
                {staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
              </select>
            </Field>
          )}
          {hospitality && (
            <Field label="Party size"><input type="number" min="1" max="500" value={form.partySize} onChange={set("partySize")} placeholder="Guests" /></Field>
          )}
          <Field label="Location"><input value={form.location} onChange={set("location")} placeholder="Optional" /></Field>
          <Field label="Notes" full><textarea value={form.description} onChange={set("description")} /></Field>
        </div>
        {error && <div className="ba-error">{error}</div>}
      </form>
    </Modal>
  );
}

// Move an appointment to a new day, time or person. Checks for breaks, days
// off and blocked time first, and keeps a note of where it was moved from.
export function RescheduleModal({ workspace, term, appt, person, onClose, onSaved }) {
  const tz = workspace.timezone;
  const start0 = new Date(appt.start_time);
  const minutes = Math.max(5, Math.round((new Date(appt.end_time) - start0) / 60000));
  const [form, setForm] = useState({
    date: new Date(start0).toLocaleDateString("en-CA", { timeZone: tz }),
    time: start0.toLocaleTimeString("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }),
    duration: String(minutes),
    staffId: appt.staff_id ?? "",
  });
  const [staff, setStaff] = useState([]);
  const [conflict, setConflict] = useState("");
  const [force, setForce] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const change = (key) => (e) => {
    setForm({ ...form, [key]: e.target.value });
    setConflict(""); setForce(false); setError("");
  };

  useEffect(() => {
    let active = true;
    supabase.from("staff_members").select("id, name, working_hours, is_active").eq("business_id", workspace.id).eq("is_active", true).order("sort_order").order("name")
      .then(({ data, error: staffError }) => { if (active && !staffError) setStaff(data ?? []); });
    return () => { active = false; };
  }, [workspace.id]);

  async function save(event) {
    event.preventDefault();
    if (!form.date || !form.time) return setError("Choose a date and time.");
    const start = zonedDateTime(form.date, form.time, tz);
    const end = new Date(start.getTime() + Number(form.duration) * 60000);
    setBusy(true);
    setError("");

    if (!force) {
      const blockResult = await supabase.from("blocked_times").select("*").eq("business_id", workspace.id)
        .lt("start_time", end.toISOString()).gt("end_time", start.toISOString());
      const message = findConflict({ staff, blocks: blockResult.error ? [] : blockResult.data ?? [], start, end, staffId: form.staffId, timeZone: tz });
      if (message) {
        setBusy(false);
        setConflict(message);
        return setError(message);
      }
    }

    const was = `${start0.toLocaleDateString("en-US", { timeZone: tz, month: "short", day: "numeric" })}, ${start0.toLocaleTimeString("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" })}`;
    const note = `Rescheduled from ${was}.`;
    const { error: updateError } = await supabase.from("appointments").update({
      start_time: start.toISOString(),
      end_time: end.toISOString(),
      status: "scheduled",
      checked_in_at: null,
      ...(form.staffId !== (appt.staff_id ?? "") ? { staff_id: form.staffId || null } : {}),
      description: appt.description ? `${appt.description}\n${note}` : note,
      updated_at: new Date().toISOString(),
    }).eq("id", appt.id);
    setBusy(false);
    if (updateError) return setError(friendly(updateError));
    onSaved(`${appt.title} moved${personName(person) ? ` for ${personName(person)}` : ""}.`);
  }

  return (
    <Modal
      title={`Reschedule ${term("appointment").toLowerCase()}`}
      description={`${appt.title}${personName(person) ? ` · ${personName(person)}` : ""}. Times are in ${workspace.name}'s time zone (${tz.replace("_", " ")}).`}
      onClose={onClose}
      busy={busy}
      footer={
        <>
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" form="ba-resched" className="ba-btn primary" disabled={busy}>{busy ? "Moving..." : "Move it"}</button>
        </>
      }
    >
      <form id="ba-resched" className="ba-modal-body" onSubmit={save}>
        <div className="ba-form-grid">
          <Field label="New date"><input type="date" value={form.date} onChange={change("date")} required /></Field>
          <Field label="New start time"><input type="time" value={form.time} onChange={change("time")} required /></Field>
          <Field label="Length">
            <select value={form.duration} onChange={change("duration")}>
              {[...new Set([15, 30, 45, 60, 90, 120, minutes])].sort((a, b) => a - b).map((m) => (
                <option key={m} value={m}>{m < 60 ? `${m} min` : `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ""}`}</option>
              ))}
            </select>
          </Field>
          {staff.length > 0 && (
            <Field label={`With (${term("staff").toLowerCase()})`}>
              <select value={form.staffId} onChange={change("staffId")}>
                <option value="">Anyone</option>
                {staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
              </select>
            </Field>
          )}
        </div>
        <p className="ba-muted">It returns to Scheduled so it can be confirmed again.</p>
        {error && <div className="ba-error">{error}</div>}
        {conflict && (
          <label className="ba-check">
            <input type="checkbox" checked={force} onChange={(e) => setForce(e.target.checked)} />
            <span>Move it anyway</span>
          </label>
        )}
      </form>
    </Modal>
  );
}
