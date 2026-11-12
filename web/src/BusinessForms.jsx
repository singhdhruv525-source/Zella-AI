import { useEffect, useRef, useState } from "react";
import { supabase } from "./supabase";
import { Field, Modal, personName } from "./BusinessUI";
import { todayInput, zonedDateTime } from "./businessTime";
import { changed, findConflict, friendly } from "./BusinessShared";

// the database refuses overlapping bookings (gap included) on every path; staff can still book over one on purpose,
// which the database records on the booking (sql/zella_booking_buffers.sql)
const SLOT_TAKEN_MSG = "That time overlaps another booking, or the gap kept between bookings. Pick another time, or tick the box to book it anyway.";
import { EmailField, PhoneField } from "./formFields";
import { checkEmail, validatePhone } from "./formValidation";
import { addLead } from "./leadCreate";
import { resourceRefusal, scheduleError } from "./schedulingLogic";

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


// Staff add an existing customer by hand. The database checks the role, looks for
// the same person first (phone or email) and never creates a duplicate.
const ADD_ERRORS = {
  NAME_REQUIRED: "Enter a first name.",
  NO_CONTACT: "Enter a phone number or email.",
  BAD_EMAIL: "That email address doesn't look right.",
};
export function AddCustomerModal({ workspace, term, onClose, onDone }) {
  const [form, setForm] = useState({ first_name: "", last_name: "", phone: "", email: "", notes: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showErrors, setShowErrors] = useState(false);
  const set = (key) => (event) => setForm({ ...form, [key]: event.target.value });
  const noun = term("customer").toLowerCase();

  async function save(event) {
    event.preventDefault();
    setShowErrors(true);
    const v = Object.fromEntries(Object.entries(form).map(([k, x]) => [k, x.trim()]));
    if (!v.first_name) return setError(ADD_ERRORS.NAME_REQUIRED);
    if (!v.phone && !v.email) return setError(ADD_ERRORS.NO_CONTACT);
    if (validatePhone(v.phone)) return setError(`Phone: ${validatePhone(v.phone)}`);
    if (checkEmail(v.email)) return setError(`Email: ${checkEmail(v.email)}`);
    setBusy(true);
    setError("");
    const { data, error: e } = await supabase.rpc("zella_staff_add_customer", {
      p_business_id: workspace.id, p_first_name: v.first_name, p_last_name: v.last_name || null,
      p_phone: v.phone || null, p_email: v.email || null, p_notes: v.notes || null,
    });
    setBusy(false);
    if (e) {
      const code = Object.keys(ADD_ERRORS).find((k) => e.message.includes(k));
      return setError(code ? ADD_ERRORS[code] : friendly(e));
    }
    onDone(data);
  }

  return (
    <Modal icon="person_add" title={`Add a ${noun}`} description="Zella Voice checks for someone with the same phone or email first, so nobody is added twice." onClose={onClose} busy={busy}
      footer={<>
        <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-add-customer" className="ba-btn primary" disabled={busy}>{busy ? "Saving..." : `Add ${noun}`}</button>
      </>}>
      <form id="ba-add-customer" className="ba-modal-body" onSubmit={save}>
        <div className="ba-form-grid">
          <Field label="First name"><input value={form.first_name} onChange={set("first_name")} autoFocus maxLength={100} /></Field>
          <Field label="Last name"><input value={form.last_name} onChange={set("last_name")} maxLength={100} /></Field>
          <Field label="Phone" bare><PhoneField value={form.phone} onChange={(phone) => setForm((f) => ({ ...f, phone }))} showErrors={showErrors} label="Phone" /></Field>
          <Field label="Email" bare><EmailField value={form.email} onChange={(email) => setForm((f) => ({ ...f, email }))} showErrors={showErrors} /></Field>
          <Field label="Administrative notes" hint="Front-desk notes only. No medical or treatment details." full><textarea value={form.notes} onChange={set("notes")} maxLength={2000} /></Field>
        </div>
        {error && <p className="ba-error" role="alert">{error}</p>}
      </form>
    </Modal>
  );
}

export function AddLeadModal({ workspace, term, onClose, onSaved }) {
  const [form, setForm] = useState({ first_name: "", last_name: "", phone: "", email: "", source: "manual", notes: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showErrors, setShowErrors] = useState(false);
  const inFlight = useRef(false);
  const set = (key) => (event) => setForm({ ...form, [key]: event.target.value });

  async function save(event) {
    event.preventDefault();
    setShowErrors(true);
    const values = Object.fromEntries(Object.entries(form).map(([k, v]) => [k, v.trim()]));
    if (!values.first_name && !values.last_name) return setError("Enter a name.");
    if (!values.phone && !values.email) return setError("Enter a phone number or email so you can follow up.");
    if (validatePhone(values.phone)) return setError(`Phone: ${validatePhone(values.phone)}`);
    if (checkEmail(values.email)) return setError(`Email: ${checkEmail(values.email)}`);

    // One submission at a time: a second click or Enter while the first is still saving does nothing.
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError("");
    // Only through the lead pipeline (duplicate check, lead stage, contact deadline, task): never a direct insert.
    const res = await addLead((fn, args) => supabase.rpc(fn, args), workspace.id, values);
    inFlight.current = false;
    setBusy(false);
    if (!res.ok) return setError(res.error);
    onSaved(res.message);
  }

  return (
    <Modal
      icon="trending_up"
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
      </form>
    </Modal>
  );
}

export function BookAppointmentModal({ workspace, term, onClose, onSaved, initial }) {
  const tz = workspace.timezone;
  const [query, setQuery] = useState("");
  const [results, setResults] = useState([]);
  const [customer, setCustomer] = useState(initial?.customer ?? null);
  // what the booking is for: a pet, vehicle, property ... of this customer (zella_appointment_records.sql)
  const [things, setThings] = useState([]);
  const [recordId, setRecordId] = useState(initial?.record?.id ?? "");
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
  // rooms, chairs, bays ... this booking uses (Release 2); the database refuses one that's taken
  const [resources, setResources] = useState([]);
  const [resourceError, setResourceError] = useState(false);
  const [resourceIds, setResourceIds] = useState([]);
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

  // Resources are optional too; an older database without them just shows none.
  useEffect(() => {
    let active = true;
    supabase.from("resources").select("id, name, kind, capacity").eq("business_id", workspace.id).eq("is_active", true).order("sort_order").order("name")
      .then(({ data, error: resError }) => {
        if (!active) return;
        setResources(resError ? [] : data ?? []);
        setResourceError(Boolean(resError && !["42P01", "PGRST205"].includes(resError.code)));
      }).catch(() => { if (active) { setResources([]); setResourceError(true); } });
    return () => { active = false; };
  }, [workspace.id]);

  // The customer's records a booking can be for. Exactly one pet, vehicle, property ... is picked for them.
  useEffect(() => {
    let active = true;
    if (!customer) { setThings(initial?.record ? [initial.record] : []); return undefined; }
    (async () => {
      const types = await supabase.from("crm_record_types").select("key, singular, appointment_link").eq("business_id", workspace.id).eq("enabled", true).eq("appointment_link", true);
      if (!active || types.error || !(types.data ?? []).length) { if (active) setThings(initial?.record ? [initial.record] : []); return; }
      const label = Object.fromEntries(types.data.map((t) => [t.key, t.singular]));
      const recs = await supabase.from("crm_records").select("id, title, type_key").eq("business_id", workspace.id).eq("customer_id", customer.id)
        .in("type_key", types.data.map((t) => t.key)).is("archived_at", null).is("closed_at", null).order("title").limit(50);
      if (!active || recs.error) return;
      const list = (recs.data ?? []).map((r) => ({ ...r, singular: label[r.type_key] }));
      // the record the booking was started from is always offered, even when it's closed
      if (initial?.record && !list.some((r) => r.id === initial.record.id)) list.unshift(initial.record);
      setThings(list);
      const assets = list.filter((r) => ["pets", "vehicles", "properties", "sites", "units", "equipment", "children"].includes(r.type_key));
      setRecordId((cur) => cur || (assets.length === 1 ? assets[0].id : ""));
    })();
    return () => { active = false; };
    // initial is fixed for this modal
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [customer, workspace.id]);

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
      if (blockResult.error || !blockResult.data) { setBusy(false); return setError("Couldn't check for blocked times. Try again."); }
      const message = findConflict({ staff, blocks: blockResult.data, start, end, staffId: form.staffId, timeZone: tz, resourceIds });
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
      ...(recordId ? { record_id: recordId } : {}),
      ...(resourceIds.length ? { resource_ids: resourceIds } : {}),
      title: form.title.trim(),
      start_time: start.toISOString(),
      end_time: end.toISOString(),
      timezone: tz,
      status: "scheduled",
      location: form.location.trim() || null,
      description: form.description.trim() || null,
      ...(force ? { metadata: { allow_overlap: true } } : {}),
    });
    setBusy(false);

    if (insertError) {
      // a resource or a crew can't be booked over, so no "book anyway" for those: say which one is taken
      if (/SLOT_TAKEN/.test(insertError.message ?? "") && /resource|booked, full or blocked|crew/.test(String(insertError.details ?? ""))) return setError(scheduleError(insertError));
      if (/SLOT_TAKEN/.test(insertError.message ?? "")) { setConflict(SLOT_TAKEN_MSG); return setError(SLOT_TAKEN_MSG); }
      return setError(/RECORD_OTHER_CUSTOMER/.test(insertError.message ?? "") ? "That belongs to another customer. Pick theirs, or change the customer."
        : /BAD_RECORD/.test(insertError.message ?? "") ? "That record can't be booked for. Pick another, or none." : friendly(insertError));
    }
    onSaved(`${term("appointment")} booked${customer ? ` for ${personName(customer)}` : ""}.`);
  }

  return (
    <Modal
      icon="event_available"
      title={`New ${term("appointment").toLowerCase()}`}
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
              <button type="button" className="ba-link" onClick={() => { setCustomer(null); setQuery(""); setRecordId(""); }}>Change</button>
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
        {things.length > 0 && (
          <Field label="For" hint={things.length === 1 && recordId === things[0].id && !initial?.record ? "Their only one on file. Check it's the right one, or pick Nothing in particular." : "What this booking is for. Shown on the record and on Today."}>
            <select value={recordId} onChange={(e) => setRecordId(e.target.value)}>
              <option value="">Nothing in particular</option>
              {things.map((r) => <option key={r.id} value={r.id}>{r.title}{r.singular ? ` (${r.singular.toLowerCase()})` : ""}</option>)}
            </select>
          </Field>
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
          {resourceError && <p role="alert" className="ba-muted">Resources could not be loaded. Check availability before saving this booking.</p>}
          {resources.length > 0 && (
            <fieldset className="ba-prefs" aria-label="Uses">
              <legend>Uses (optional)</legend>
              {resources.map((r) => (
                <label key={r.id} className="ba-check">
                  <input type="checkbox" checked={resourceIds.includes(r.id)}
                    onChange={() => { setResourceIds((ids) => (ids.includes(r.id) ? ids.filter((x) => x !== r.id) : [...ids, r.id])); setError(""); }} />
                  <span>{r.name}{r.capacity > 1 ? ` (holds ${r.capacity})` : ""}</span>
                </label>
              ))}
            </fieldset>
          )}
          {hospitality && (
            <Field label="Party size"><input type="number" min="1" max="500" value={form.partySize} onChange={set("partySize")} placeholder="Guests" /></Field>
          )}
          <Field label="Location"><input value={form.location} onChange={set("location")} placeholder="Optional" /></Field>
          <Field label="Notes" full><textarea value={form.description} onChange={set("description")} /></Field>
        </div>
        {error && <div className="ba-error">{error}</div>}
        {conflict && (
          <label className="ba-check">
            <input type="checkbox" checked={force} onChange={(e) => setForce(e.target.checked)} />
            <span>Book it anyway</span>
          </label>
        )}
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

    // Checked on every save, "Move it anyway" included: a block on a room, chair or bay can't be overridden (a block may
    // have been added since the warning, and the database guard doesn't cover every booking).
    const blockResult = await supabase.from("blocked_times").select("*").eq("business_id", workspace.id)
      .lt("start_time", end.toISOString()).gt("end_time", start.toISOString());
    if (blockResult.error || !blockResult.data) { setBusy(false); return setError("Couldn't check for blocked times, so nothing was moved. Try again."); }
    const refused = resourceRefusal({ blocks: blockResult.data, start, end, resourceIds: appt.resource_ids });
    if (refused) { setBusy(false); setConflict(""); return setError(refused); }
    if (!force) {
      const message = findConflict({ staff, blocks: blockResult.data, start, end, staffId: form.staffId, timeZone: tz, resourceIds: appt.resource_ids });
      if (message) {
        setBusy(false);
        setConflict(message);
        return setError(message);
      }
    }

    const was = `${start0.toLocaleDateString("en-US", { timeZone: tz, month: "short", day: "numeric" })}, ${start0.toLocaleTimeString("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" })}`;
    const note = `Rescheduled from ${was}.`;
    const { error: updateError } = await changed(supabase.from("appointments").update({
      start_time: start.toISOString(),
      end_time: end.toISOString(),
      status: "scheduled",
      checked_in_at: null,
      ...(form.staffId !== (appt.staff_id ?? "") ? { staff_id: form.staffId || null } : {}),
      description: appt.description ? `${appt.description}\n${note}` : note,
      ...(force ? { metadata: { ...(appt.metadata ?? {}), allow_overlap: true } } : {}),
      updated_at: new Date().toISOString(),
    }).eq("id", appt.id));
    setBusy(false);
    // a room, chair or crew can't be overridden: name it instead of offering "Move it anyway"
    if (updateError && /SLOT_TAKEN/.test(updateError.message ?? "") && /resource|booked, full or blocked|crew/.test(String(updateError.details ?? ""))) { setConflict(""); return setError(scheduleError(updateError)); }
    if (updateError && /SLOT_TAKEN/.test(updateError.message ?? "")) { setConflict(SLOT_TAKEN_MSG); return setError(SLOT_TAKEN_MSG); }
    if (updateError) return setError(friendly(updateError));
    onSaved(`${appt.title} moved${personName(person) ? ` for ${personName(person)}` : ""}.`);
  }

  return (
    <Modal
      icon="event_repeat"
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
