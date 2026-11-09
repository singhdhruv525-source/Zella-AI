import { useState } from "react";
import { supabase } from "../supabase";
import { Banner, Card, LoadState, Pill, Table, Toggle, useAsync } from "./SettingsKit";

// Settings > Industry and workflows > What your business does. The kinds of work this business does (zella_capabilities):
// the industry decides what's supported and what starts on; owners and admins switch the optional ones. Turning one
// off hides its pages and the server refuses new work of that kind; nothing already recorded is deleted.

const STATE = {
  on: ["success", "On"],
  needs_setup: ["warning", "On, needs setup"],
  off: ["", "Off"],
  unsupported: ["", "Not for your industry"],
};

const ABOUT = {
  scheduling: "Calendar, bookings, and the receptionist offering times",
  checkins: "Marking people arrived and in service at the front desk",
  waitlist: "A list of people waiting for an earlier time",
  dispatch: "Jobs at the customer's address, arrival windows and technicians",
  classes: "Group classes with places, bookings and attendance",
  orders: "Order questions, returns and delivery problems",
  money: "Estimates, invoices, deposits and gift cards your team records (Zella never takes card details)",
  access_vault: "Gate codes, lockbox and alarm details, shown only to managers and the person assigned",
};

const friendlyError = (message = "") =>
  message.includes("NEEDS:") ? "Turn on Appointments and bookings first."
    : message.includes("NOT_FOR_THIS_INDUSTRY") ? "This isn't offered for your industry."
      : message.includes("NOT_ALLOWED") ? "Only owners and admins can change this."
        : message || "Couldn't save. Try again.";

export function CapabilitiesPanel({ w, onReload }) {
  const [attempt, setAttempt] = useState(0);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [note, setNote] = useState("");
  const state = useAsync(async () => {
    const { data, error: e } = await supabase.rpc("zella_capabilities", { p_business_id: w.id });
    if (e) throw new Error(/could not find the function/i.test(e.message) ? "This needs the latest Zella Voice update." : e.message);
    return data;
  }, [w.id, attempt]);
  const canManage = ["owner", "admin"].includes(w.role);

  async function change(key, enabled) {
    setBusy(key); setError(""); setNote("");
    const { error: e } = await supabase.rpc("zella_set_capability", { p_business_id: w.id, p_key: key, p_enabled: enabled });
    setBusy("");
    if (e) { setError(friendlyError(e.message)); return; }
    setNote(enabled ? "Switched on. The menu updates when you reload." : "Switched off. Nothing already recorded was deleted.");
    setAttempt((n) => n + 1);
    onReload?.();
  }

  return (
    <LoadState state={state}>{(caps) => {
      const rows = Object.entries(caps).map(([key, c]) => ({ key, ...c })).sort((a, b) => a.order - b.order);
      const supported = rows.filter((r) => r.supported);
      const other = rows.filter((r) => !r.supported);
      return (
        <>
          <Banner tone="error">{error}</Banner>
          <Banner>{note}</Banner>
          <Card title="What your business does" sub="Starts from your industry. Switching something off hides its pages and stops new work of that kind; your records are kept.">
            <Table rowKey={(r) => r.key} rows={supported} columns={[
              ["Work", (r) => <><strong>{r.label}</strong><br /><small className="zs-muted">{ABOUT[r.key]}</small></>],
              ["State", (r) => { const [tone, label] = STATE[r.state] ?? ["", r.state]; return <><Pill tone={tone}>{label}</Pill>{r.why && r.enabled && <><br /><small className="zs-muted">{r.why}</small></>}</>; }],
              ["", (r) => (
                <Toggle on={r.enabled} label={`${r.label} ${r.enabled ? "on" : "off"}`} disabled={!canManage || busy === r.key}
                  onChange={(next) => change(r.key, next)} />
              )],
            ]} />
            {!canManage && <p className="zs-muted" style={{ marginTop: 10 }}>Only owners and admins can change these.</p>}
          </Card>
          {other.length > 0 && (
            <Card title="Not offered for your industry" sub="Ask the Zella Voice team if your business does this too.">
              <p className="zs-muted">{other.map((r) => r.label).join(", ")}</p>
            </Card>
          )}
        </>
      );
    }}</LoadState>
  );
}

// Settings > Phone system > Call recording and privacy: who may read transcripts and recordings.
export function CallContentAccess({ w }) {
  const [attempt, setAttempt] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const state = useAsync(async () => {
    const [{ data: b, error: e1 }, { data: sensitive, error: e2 }] = await Promise.all([
      supabase.from("businesses").select("setup_data").eq("id", w.id).maybeSingle(),
      supabase.rpc("zella_sensitive_industry", { p_business_id: w.id }),
    ]);
    if (e1) throw new Error(e1.message);
    return { staff: Boolean(b?.setup_data?.privacy?.staff_read_call_content), sensitive: e2 ? null : Boolean(sensitive) };
  }, [w.id, attempt]);
  const canManage = ["owner", "admin"].includes(w.role);

  async function change(next) {
    setBusy(true); setError("");
    const { error: e } = await supabase.rpc("zella_set_call_content_access", { p_business_id: w.id, p_staff: next });
    setBusy(false);
    if (e) { setError(friendlyError(e.message)); return; }
    setAttempt((n) => n + 1);
  }

  return (
    <LoadState state={state}>{(s) => (
      <Card title="Who can read transcripts and play recordings" sub="Owners, admins and managers always can. View-only members never can.">
        <Banner tone="error">{error}</Banner>
        {s.sensitive === null ? (
          <p className="zs-muted">Choosing this needs the latest Zella Voice update.</p>
        ) : s.sensitive ? (
          <p className="zs-muted">Calls in your industry often include health, legal, financial or children's details, so staff can't be given access.</p>
        ) : (
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <Toggle on={s.staff} label="Staff can read transcripts and play recordings" disabled={!canManage || busy} onChange={change} />
            <span>Staff can read transcripts and play recordings</span>
          </div>
        )}
        {!canManage && s.sensitive === false && <p className="zs-muted" style={{ marginTop: 10 }}>Only owners and admins can change this.</p>}
      </Card>
    )}</LoadState>
  );
}
