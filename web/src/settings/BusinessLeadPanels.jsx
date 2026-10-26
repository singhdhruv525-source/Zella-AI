import { useState } from "react";
import { supabase } from "../supabase";
import { friendly } from "../BusinessShared";
import { OffersPanel } from "../BusinessOffers";
import { Banner, Card, Confirm, Facts, Field, LoadState, Pill, SaveBar, Table, Toggle, useAsync, useForm, when, words } from "./SettingsKit";

// Business Settings pages for website forms, lead rules and questions, work assignment, website knowledge
// sources and offers. Writes go through role-checked database functions, or straight to tables whose row level
// security allows only owners, admins and managers of this business (zella_settings_system.sql, sections 16-18).

const LEAD = ["owner", "admin", "manager"];
const MANAGE = ["owner", "admin"];
const SAY = {
  NOT_ALLOWED: "Your role can't change this. Ask an owner or admin.", "row-level security": "Your role can't change this. Ask an owner, admin or manager.",
  BAD_ORIGIN: "Each website must be just the address, like https://www.example.com (no page path).", TOO_MANY_ORIGINS: "Add up to 10 websites.",
  TARGET_NOT_ACTIVE: "That person isn't an active member of the team.", ROLES_REQUIRED: "Choose at least one role to share work with.",
  BAD_URL: "Enter your website address, like https://www.example.com.", TOO_MANY_SITES: "You can read up to 3 websites.",
  NOT_APPROVED: "Approve this website first.", BAD_INPUT: "Something in the form isn't valid.", lead_questions_business_id_key_key: "A question with that key already exists.",
};
const say = (e) => { const m = e?.message ?? String(e); const k = Object.keys(SAY).find((c) => m.includes(c)); return k ? SAY[k] : friendly(e); };
async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(say(error));
  return data;
}
// A table write that must change exactly the rows asked for. Row level security turns a refused update or delete
// into "0 rows", so that is reported instead of looking saved.
async function write(query) {
  const { data, error } = await query.select("id");
  if (error) throw new Error(say(error));
  if (!data?.length) throw new Error(SAY.NOT_ALLOWED);
  return data;
}
const roster = (w) => rpc("zella_team_roster", { p_business_id: w.id }).then((r) => (Array.isArray(r) ? r : []));
const can = (w, roles) => roles.includes(w.role);
const lines = (t) => String(t ?? "").split(/[\n,]+/).map((x) => x.trim()).filter(Boolean);

/* ---------- Website forms ---------- */

const ENDPOINT = `${import.meta.env.VITE_SUPABASE_URL ?? ""}/functions/v1/website-lead`;

function snippet(key) {
  return `<form id="zella-lead">
  <input name="name" placeholder="Your name" required>
  <input name="phone" placeholder="Phone">
  <input name="email" type="email" placeholder="Email">
  <textarea name="message" placeholder="How can we help?"></textarea>
  <input name="website_url" tabindex="-1" autocomplete="off" aria-hidden="true" style="position:absolute;left:-9999px">
  <button>Send</button>
  <p id="zella-lead-status" role="status"></p>
</form>
<script>
document.getElementById("zella-lead").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.target, status = document.getElementById("zella-lead-status");
  const fields = Object.fromEntries(new FormData(form));
  const res = await fetch("${ENDPOINT}", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key: "${key}", kind: "contact_form", ...fields, source: { page_url: location.href, referrer: document.referrer } }),
  }).catch(() => null);
  const out = res ? await res.json().catch(() => ({})) : {};
  status.textContent = out.message || (out.ok ? "Thank you." : "Something went wrong. Please call us.");
  if (out.ok) form.reset();
});
</script>`;
}

export function WebsiteForms({ w }) {
  const state = useAsync(() => rpc("zella_website_forms", { p_business_id: w.id }), [w.id]);
  const edit = can(w, LEAD);
  return (
    <>
      {!edit && <Banner tone="warn">Only owners, admins and managers can change website forms. You can see them.</Banner>}
      <LoadState state={state}>{(forms) => (
        <>
          {!forms.length && <Card title="No website forms yet" sub="A form lets visitors send their details straight into your leads." />}
          {forms.map((f) => <FormCard key={f.id} f={f} edit={edit} onSaved={state.reload} />)}
          {edit && <NewForm w={w} onCreated={state.reload} />}
        </>
      )}</LoadState>
    </>
  );
}

function FormCard({ f, edit, onSaved }) {
  const form = useForm({ name: f.name, origins: (f.allowed_origins ?? []).join("\n"), enabled: f.enabled });
  const [show, setShow] = useState(false);
  const [copied, setCopied] = useState("");
  const counts = f.last_30_days ?? {};
  async function copy() {
    try { await navigator.clipboard.writeText(snippet(f.public_key)); setCopied("Copied."); } catch { setCopied("Select the code and copy it."); }
  }
  return (
    <Card title={f.name} sub={`Created ${when(f.created_at)}`} actions={<Pill tone={f.enabled ? "success" : ""}>{f.enabled ? "On" : "Off"}</Pill>}>
      <Facts rows={[["Form key", <code key="k">{f.public_key}</code>], ["Last 30 days", Object.keys(counts).length ? Object.entries(counts).map(([k, n]) => `${n} ${words(k).toLowerCase()}`).join(", ") : "No submissions"],
        ["Last submission", f.last_submission_at ? when(f.last_submission_at) : "—"]]} />
      <fieldset disabled={!edit} style={{ border: 0, padding: 0, margin: "12px 0 0" }}>
        <div className="zs-grid">
          <Field label="Name" hint="For you, for example Contact page."><input value={form.values.name} onChange={form.set("name")} maxLength={80} /></Field>
          <Field label="Accept submissions"><Toggle on={form.values.enabled} onChange={form.set("enabled")} label="Accept submissions" disabled={!edit} /></Field>
          <Field full label="Websites allowed to use this form" hint="One per line, like https://www.example.com. Leave empty to accept any website (not recommended).">
            <textarea rows={3} value={form.values.origins} onChange={form.set("origins")} />
          </Field>
        </div>
      </fieldset>
      {edit && <SaveBar form={form} onSave={() => form.save(async (v) => {
        const out = await rpc("zella_website_form_save", { p_form_id: f.id, p_name: v.name, p_allowed_origins: lines(v.origins), p_enabled: v.enabled });
        onSaved();
        return { origins: (out.allowed_origins ?? []).join("\n") };
      })} />}
      <div className="zs-actions" style={{ marginTop: 10 }}>
        <button type="button" className="zs-btn sm" onClick={() => setShow(!show)}>{show ? "Hide website code" : "Show website code"}</button>
        {show && <button type="button" className="zs-btn sm" onClick={copy}>Copy code</button>}
        {copied && <span className="zs-muted" role="status">{copied}</span>}
      </div>
      {show && <pre className="zs-code" aria-label="Website code">{snippet(f.public_key)}</pre>}
    </Card>
  );
}

function NewForm({ w, onCreated }) {
  const form = useForm({ name: "", origins: "" });
  return (
    <Card title="Add a website form" sub="Each form gets its own key, so you can see which page leads come from.">
      <div className="zs-grid">
        <Field label="Name"><input value={form.values.name} onChange={form.set("name")} maxLength={80} placeholder="Contact page" /></Field>
        <Field full label="Websites allowed to use it" hint="One per line, like https://www.example.com."><textarea rows={2} value={form.values.origins} onChange={form.set("origins")} /></Field>
      </div>
      <SaveBar form={form} label="Create form" onSave={() => form.save(async (v) => {
        const origins = lines(v.origins);
        const key = await rpc("zella_create_website_form", { p_business_id: w.id, p_name: v.name || "Website", p_allowed_origins: [] });
        // Websites are checked by the save function, so they are added in a second step.
        if (origins.length) {
          const list = await rpc("zella_website_forms", { p_business_id: w.id });
          const made = list.find((f) => f.public_key === key);
          if (made) await rpc("zella_website_form_save", { p_form_id: made.id, p_name: made.name, p_allowed_origins: origins, p_enabled: true });
        }
        onCreated();
        return { name: "", origins: "" };
      }, "Form created.")} />
    </Card>
  );
}

/* ---------- Lead assignment rules ---------- */

const PRIORITY = [["", "Keep as is"], ["high", "High"], ["urgent", "Urgent"]];

export function LeadRules({ w }) {
  const state = useAsync(() => Promise.all([
    supabase.from("lead_rules").select("id, name, sort_order, match, assign_to, set_priority, is_active, created_at").eq("business_id", w.id).order("sort_order").order("created_at")
      .then(({ data, error }) => { if (error) throw new Error(say(error)); return data ?? []; }),
    roster(w),
    supabase.from("lead_questions").select("key").eq("business_id", w.id).then(({ data }) => (data ?? []).map((q) => q.key)),
  ]), [w.id]);
  const [editing, setEditing] = useState(null);
  const [removing, setRemoving] = useState(null);
  const [error, setError] = useState("");
  const edit = can(w, LEAD);

  async function move(rules, i, dir) {
    if (!rules[i + dir]) return;
    setError("");
    try {
      // Positions are rewritten for the whole list so equal numbers can't leave the order ambiguous.
      const order = rules.map((r) => r.id);
      [order[i], order[i + dir]] = [order[i + dir], order[i]];
      for (const [n, id] of order.entries()) await write(supabase.from("lead_rules").update({ sort_order: (n + 1) * 10 }).eq("id", id).eq("business_id", w.id));
      state.reload();
    } catch (err) { setError(err.message); }
  }

  return (
    <LoadState state={state}>{([rules, people, keys]) => {
      const nameOf = Object.fromEntries(people.map((p) => [p.user_id, p.name]));
      const matchText = (m) => [m?.source && `from ${m.source}`, m?.keyword && `mentions "${m.keyword}"`,
        ...Object.entries(m?.answer_equals ?? {}).map(([k, v]) => `${k} is "${v}"`)].filter(Boolean).join(" and ") || "Every new lead";
      return (
        <>
          <Card title="How new leads are assigned" sub="Rules are checked from the top. The first rule that names a person decides who gets the lead; priority can be raised by any matching rule. If no rule names anyone, the lead goes to the team member with the fewest open leads.">
            {!edit && <Banner tone="warn">Only owners, admins and managers can change these rules. You can see them.</Banner>}
            <Banner tone="error">{error}</Banner>
            <Table rows={rules} empty="No rules yet: leads are shared by workload." columns={[
              ["Order", (r) => rules.indexOf(r) + 1], ["Rule", (r) => <strong>{r.name}</strong>], ["When", (r) => matchText(r.match)],
              ["Assign to", (r) => (r.assign_to ? nameOf[r.assign_to] ?? "Former member" : "—")], ["Priority", (r) => (r.set_priority ? words(r.set_priority) : "—")],
              ["State", (r) => <Pill tone={r.is_active ? "success" : ""}>{r.is_active ? "On" : "Off"}</Pill>],
              ["", (r) => edit && (
                <div className="zs-actions">
                  <button type="button" className="zs-btn sm" aria-label={`Move ${r.name} up`} disabled={rules.indexOf(r) === 0} onClick={() => move(rules, rules.indexOf(r), -1)}>↑</button>
                  <button type="button" className="zs-btn sm" aria-label={`Move ${r.name} down`} disabled={rules.indexOf(r) === rules.length - 1} onClick={() => move(rules, rules.indexOf(r), 1)}>↓</button>
                  <button type="button" className="zs-btn sm" onClick={() => setEditing(r)}>Edit</button>
                  <button type="button" className="zs-btn sm danger-outline" onClick={() => setRemoving(r)}>Delete</button>
                </div>
              )]]} />
            {edit && !editing && <div className="zs-actions" style={{ marginTop: 10 }}><button type="button" className="zs-btn primary" onClick={() => setEditing({})}>Add a rule</button></div>}
          </Card>
          {editing && <RuleEditor key={editing.id ?? "new"} w={w} rule={editing} people={people} keys={keys} next={(rules.at(-1)?.sort_order ?? 0) + 10}
            onClose={() => setEditing(null)} onSaved={() => { setEditing(null); state.reload(); }} />}
          {removing && (
            <Confirm title={`Delete "${removing.name}"?`} danger confirmLabel="Delete rule" onClose={() => setRemoving(null)}
              onConfirm={async () => { await write(supabase.from("lead_rules").delete().eq("id", removing.id).eq("business_id", w.id)); state.reload(); }}>
              New leads stop using this rule. Leads already assigned keep their person and priority.
            </Confirm>
          )}
        </>
      );
    }}</LoadState>
  );
}

function RuleEditor({ w, rule, people, keys, next, onClose, onSaved }) {
  const [ak, av] = Object.entries(rule.match?.answer_equals ?? {})[0] ?? ["", ""];
  const form = useForm({ name: rule.name ?? "", source: rule.match?.source ?? "", keyword: rule.match?.keyword ?? "", answerKey: ak, answerValue: av,
    assign_to: rule.assign_to ?? "", set_priority: rule.set_priority ?? "", is_active: rule.is_active ?? true });
  const v = form.values;
  const empty = !v.assign_to && !v.set_priority;
  return (
    <Card title={rule.id ? `Edit "${rule.name}"` : "New rule"} actions={<button type="button" className="zs-btn sm" onClick={onClose} disabled={form.dirty}>Close</button>}>
      <div className="zs-grid">
        <Field label="Rule name"><input value={v.name} onChange={form.set("name")} maxLength={80} placeholder="Emergencies to Sam" /></Field>
        <Field label="Rule is on"><Toggle on={v.is_active} onChange={form.set("is_active")} label="Rule is on" /></Field>
        <Field label="Lead came from" hint="Leave empty for any source.">
          <input value={v.source} onChange={form.set("source")} list="zs-lead-sources" maxLength={40} placeholder="website" />
          <datalist id="zs-lead-sources">{["website", "website_chat", "phone", "facebook", "instagram", "referral"].map((s) => <option key={s} value={s} />)}</datalist>
        </Field>
        <Field label="Message mentions" hint="A word or phrase in the lead's notes. Leave empty for any."><input value={v.keyword} onChange={form.set("keyword")} maxLength={80} placeholder="leak" /></Field>
        <Field label="Answer to question" hint="A qualifying question's key. Leave empty to skip.">
          <input value={v.answerKey} onChange={form.set("answerKey")} list="zs-lead-keys" maxLength={40} />
          <datalist id="zs-lead-keys">{keys.map((k) => <option key={k} value={k} />)}</datalist>
        </Field>
        <Field label="Answer is"><input value={v.answerValue} onChange={form.set("answerValue")} maxLength={80} disabled={!v.answerKey} /></Field>
        <Field label="Assign to">
          <select value={v.assign_to} onChange={form.set("assign_to")}>
            <option value="">Don't choose (share by workload)</option>
            {people.map((p) => <option key={p.user_id} value={p.user_id}>{p.name} · {words(p.role)}</option>)}
          </select>
        </Field>
        <Field label="Set priority"><select value={v.set_priority} onChange={form.set("set_priority")}>{PRIORITY.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
      </div>
      {empty && <Banner tone="warn">Choose a person or a priority, or the rule won't change anything.</Banner>}
      <SaveBar form={form} disabled={!v.name.trim() || empty} onSave={() => form.save(async (x) => {
        const match = {};
        if (x.source.trim()) match.source = x.source.trim();
        if (x.keyword.trim()) match.keyword = x.keyword.trim();
        if (x.answerKey.trim() && x.answerValue.trim()) match.answer_equals = { [x.answerKey.trim()]: x.answerValue.trim() };
        const row = { name: x.name.trim(), match, assign_to: x.assign_to || null, set_priority: x.set_priority || null, is_active: x.is_active };
        if (rule.id) await write(supabase.from("lead_rules").update(row).eq("id", rule.id).eq("business_id", w.id));
        else await write(supabase.from("lead_rules").insert({ ...row, business_id: w.id, sort_order: next }));
        onSaved();
      })} />
    </Card>
  );
}

/* ---------- Qualifying questions ---------- */

export function LeadQuestions({ w }) {
  const state = useAsync(() => supabase.from("lead_questions").select("id, key, question, required, qualifies_when, sort_order, is_active").eq("business_id", w.id).order("sort_order")
    .then(({ data, error }) => { if (error) throw new Error(say(error)); return data ?? []; }), [w.id]);
  const [editing, setEditing] = useState(null);
  const [removing, setRemoving] = useState(null);
  const edit = can(w, LEAD);
  const rule = (q) => (q.qualifies_when?.equals !== undefined ? `Answer is "${q.qualifies_when.equals}"` : q.qualifies_when?.min !== undefined ? `At least ${q.qualifies_when.min}` : "—");
  return (
    <LoadState state={state}>{(qs) => (
      <>
        <Card title="Qualifying questions" sub="Answers saved on a lead decide whether it is qualified: a required question left blank keeps the lead as New, and an answer that fails its rule marks it not qualified. Lead rules can match answers by key.">
          {!edit && <Banner tone="warn">Only owners, admins and managers can change these. You can see them.</Banner>}
          <Table rows={qs} empty="No questions yet." columns={[["Key", (q) => <code>{q.key}</code>], ["Question", (q) => q.question], ["Required", (q) => (q.required ? "Yes" : "No")],
            ["Qualifies when", rule], ["State", (q) => <Pill tone={q.is_active ? "success" : ""}>{q.is_active ? "On" : "Off"}</Pill>],
            ["", (q) => edit && <div className="zs-actions"><button type="button" className="zs-btn sm" onClick={() => setEditing(q)}>Edit</button>
              <button type="button" className="zs-btn sm danger-outline" onClick={() => setRemoving(q)}>Delete</button></div>]]} />
          {edit && !editing && <div className="zs-actions" style={{ marginTop: 10 }}><button type="button" className="zs-btn primary" onClick={() => setEditing({})}>Add a question</button></div>}
        </Card>
        {editing && <QuestionEditor key={editing.id ?? "new"} w={w} q={editing} next={(qs.at(-1)?.sort_order ?? 0) + 10} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); state.reload(); }} />}
        {removing && (
          <Confirm title={`Delete "${removing.question}"?`} danger confirmLabel="Delete question" onClose={() => setRemoving(null)}
            onConfirm={async () => { await write(supabase.from("lead_questions").delete().eq("id", removing.id).eq("business_id", w.id)); state.reload(); }}>
            Answers already saved on leads stay. The question stops counting toward qualification. To keep it but stop asking, switch it off instead.
          </Confirm>
        )}
      </>
    )}</LoadState>
  );
}

function QuestionEditor({ w, q, next, onClose, onSaved }) {
  const kind = q.qualifies_when?.equals !== undefined ? "equals" : q.qualifies_when?.min !== undefined ? "min" : "";
  const form = useForm({ key: q.key ?? "", question: q.question ?? "", required: q.required ?? false, is_active: q.is_active ?? true, kind,
    value: String(q.qualifies_when?.equals ?? q.qualifies_when?.min ?? "") });
  const v = form.values;
  const keyOk = /^[a-z0-9_]{1,40}$/.test(v.key);
  const valueOk = !v.kind || (v.kind === "min" ? /^\d+(\.\d+)?$/.test(v.value.trim()) : v.value.trim().length > 0);
  return (
    <Card title={q.id ? "Edit question" : "New question"} actions={<button type="button" className="zs-btn sm" onClick={onClose} disabled={form.dirty}>Close</button>}>
      <div className="zs-grid">
        <Field full label="Question"><input value={v.question} onChange={form.set("question")} maxLength={200} placeholder="Is this an emergency?" /></Field>
        <Field label="Key" hint="Lowercase letters, numbers and _. Used by lead rules and forms." error={v.key && !keyOk ? "Use lowercase letters, numbers and _ only." : ""}>
          <input value={v.key} onChange={form.set("key")} maxLength={40} disabled={Boolean(q.id)} placeholder="emergency" />
        </Field>
        <Field label="Required"><Toggle on={v.required} onChange={form.set("required")} label="Required" /></Field>
        <Field label="Qualifies when">
          <select value={v.kind} onChange={form.set("kind")}><option value="">Any answer</option><option value="equals">Answer is exactly</option><option value="min">Number is at least</option></select>
        </Field>
        <Field label="Value"><input value={v.value} onChange={form.set("value")} maxLength={80} disabled={!v.kind} inputMode={v.kind === "min" ? "decimal" : undefined} /></Field>
        <Field label="Question is on"><Toggle on={v.is_active} onChange={form.set("is_active")} label="Question is on" /></Field>
      </div>
      <SaveBar form={form} disabled={!keyOk || !v.question.trim() || !valueOk} onSave={() => form.save(async (x) => {
        const qualifies_when = !x.kind ? null : x.kind === "min" ? { min: Number(x.value) } : { equals: x.value.trim() };
        const row = { question: x.question.trim(), required: x.required, is_active: x.is_active, qualifies_when };
        if (q.id) await write(supabase.from("lead_questions").update(row).eq("id", q.id).eq("business_id", w.id));
        else await write(supabase.from("lead_questions").insert({ ...row, key: x.key, business_id: w.id, sort_order: next }));
        onSaved();
      })} />
    </Card>
  );
}

/* ---------- Automatic work assignment ---------- */

const MODES = [["round_robin", "Take turns", "New leads and callbacks go to each person in turn."], ["least_busy", "Least busy first", "Each goes to whoever has the fewest open leads and callbacks."],
  ["off", "Off", "Nothing is assigned automatically; lead rules that name a person still apply."]];

export function AssignmentSettings({ w }) {
  const state = useAsync(() => supabase.from("assignment_rules").select("mode, roles, unassigned_alert_minutes, updated_at").eq("business_id", w.id).maybeSingle()
    .then(({ data, error }) => { if (error) throw new Error(say(error)); return data; }), [w.id]);
  return <LoadState state={state}>{(r) => <AssignmentForm w={w} r={r} />}</LoadState>;
}

function AssignmentForm({ w, r }) {
  const edit = can(w, MANAGE);
  const form = useForm({ mode: r?.mode ?? "round_robin", roles: r?.roles ?? ["owner", "admin", "manager", "staff"], minutes: String(r?.unassigned_alert_minutes ?? 10) });
  const v = form.values;
  const toggleRole = (role) => form.set("roles")(v.roles.includes(role) ? v.roles.filter((x) => x !== role) : [...v.roles, role]);
  const minutes = Number(v.minutes);
  const ok = Number.isInteger(minutes) && minutes >= 5 && minutes <= 1440 && (v.mode === "off" || v.roles.length > 0);
  return (
    <Card title="Sharing new work" sub={r ? `Changed ${when(r.updated_at)}` : "Using the starting settings."}>
      {!edit && <Banner tone="warn">Only owners and admins can change this. You can see it.</Banner>}
      <fieldset disabled={!edit} style={{ border: 0, padding: 0, margin: 0 }}>
        <div className="zs-choice">
          {MODES.map(([k, label, text]) => (
            <label key={k} className={`zs-option ${v.mode === k ? "on" : ""}`}>
              <input type="radio" name="zs-assign-mode" checked={v.mode === k} onChange={() => form.set("mode")(k)} />
              <span><strong>{label}</strong><small>{text}</small></span>
            </label>
          ))}
        </div>
        <div className="zs-grid">
          <Field label="Roles that take new work" hint="People marked away are skipped.">
            <div className="zs-actions">{["owner", "admin", "manager", "staff"].map((role) => (
              <label key={role} style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
                <input type="checkbox" checked={v.roles.includes(role)} onChange={() => toggleRole(role)} disabled={v.mode === "off"} />{words(role)}
              </label>
            ))}</div>
          </Field>
          <Field label="Flag unassigned work after (minutes)" hint="5 to 1440." error={v.minutes && !(minutes >= 5 && minutes <= 1440) ? "Enter 5 to 1440." : ""}>
            <input value={v.minutes} onChange={form.set("minutes")} inputMode="numeric" />
          </Field>
        </div>
      </fieldset>
      {edit && <SaveBar form={form} disabled={!ok} onSave={() => form.save(async (x) => {
        const out = await rpc("zella_save_assignment_rules", { p_business_id: w.id, p_mode: x.mode, p_roles: x.roles, p_alert_minutes: Number(x.minutes) });
        return { roles: out.roles?.length ? out.roles : x.roles };
      })} />}
    </Card>
  );
}

/* ---------- Website knowledge sources ---------- */

const FREQUENCY = [[24, "Every day"], [72, "Every 3 days"], [168, "Every week"], [336, "Every 2 weeks"], [720, "Every month"]];

export function WebsiteSources({ w }) {
  const state = useAsync(() => Promise.all([
    rpc("zella_website_status", { p_business_id: w.id }),
    supabase.from("website_pages").select("id, url, title, first_seen_at").eq("business_id", w.id).eq("status", "pending").order("first_seen_at").limit(50)
      .then(({ data, error }) => { if (error) throw new Error(say(error)); return data ?? []; }),
  ]), [w.id]);
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState("");
  const [msg, setMsg] = useState({ text: "", error: "" });
  const [removing, setRemoving] = useState(null);
  const lead = can(w, LEAD); const manage = can(w, MANAGE);

  async function act(id, fn, done) {
    setBusy(id); setMsg({ text: "", error: "" });
    try { await fn(); setMsg({ text: done, error: "" }); state.reload(); } catch (err) { setMsg({ text: "", error: err.message }); } finally { setBusy(""); }
  }

  return (
    <LoadState state={state}>{([s, pending]) => (
      <>
        {!s.live && <Banner tone="warn">Reading websites isn't switched on for Zella yet (it starts at go-live). You can add and approve your site now; pages are read once it starts.</Banner>}
        <Banner tone="error">{msg.error}</Banner>
        {msg.text && <Banner tone="success">{msg.text}</Banner>}
        <Card title="Your websites" sub="Zella reads approved pages and drafts answers for your receptionist. Drafts wait in Business knowledge until someone approves them.">
          <Facts rows={[["Pages being read", s.pages?.approved ?? 0], ["Found, waiting for a decision", s.pages?.pending ?? 0], ["Broken or missing", (s.pages?.broken ?? 0) + (s.pages?.missing ?? 0)],
            ["Draft answers waiting", s.drafts_waiting], ["Answers to re-check (page changed)", s.needs_check]]} />
          <Table rows={s.sources} empty="No websites added." columns={[["Website", (x) => x.url], ["State", (x) => <Pill tone={x.status === "active" ? "success" : "warning"}>{x.status === "pending_approval" ? "Waiting for approval" : words(x.status)}</Pill>],
            ["Checked", (x) => FREQUENCY.find(([h]) => h === x.frequency_hours)?.[1] ?? `Every ${x.frequency_hours} hours`], ["New pages", (x) => (x.auto_approve_new ? "Read automatically" : "Ask first")],
            ["Last read", (x) => (x.last_error ? <span className="zs-error-text">{x.last_error}</span> : when(x.last_crawl_at))],
            ["", (x) => manage && <SourceActions x={x} busy={busy === x.id} act={act} onRemove={() => setRemoving(x)} />]]} />
          {lead && (
            <form className="zs-actions" style={{ marginTop: 12 }} onSubmit={(e) => { e.preventDefault(); act("add", () => rpc("zella_website_add_source", { p_business_id: w.id, p_url: url }), manage ? "Added. Approve it to start reading." : "Added. An owner or admin needs to approve it."); setUrl(""); }}>
              <input aria-label="Website address" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://www.example.com" style={{ minWidth: 260 }} />
              <button type="submit" className="zs-btn" disabled={!url.trim() || busy === "add"}>Add website</button>
            </form>
          )}
          {!lead && <p className="zs-muted">Owners, admins and managers can add websites.</p>}
        </Card>
        <Card title="Pages waiting for a decision" sub="Found on your site's sitemap. Only approved pages are read.">
          <Table rows={pending} empty="Nothing waiting." columns={[["Page", (p) => <a href={p.url} target="_blank" rel="noreferrer noopener">{p.title || p.url}</a>], ["Found", (p) => when(p.first_seen_at)],
            ["", (p) => lead && <div className="zs-actions">
              <button type="button" className="zs-btn sm primary" disabled={busy === p.id} onClick={() => act(p.id, () => rpc("zella_website_set_page", { p_page_id: p.id, p_approve: true }), "Page approved.")}>Read it</button>
              <button type="button" className="zs-btn sm" disabled={busy === p.id} onClick={() => act(p.id, () => rpc("zella_website_set_page", { p_page_id: p.id, p_approve: false }), "Page ignored.")}>Ignore</button></div>]]} />
        </Card>
        {removing && (
          <Confirm title={`Stop reading ${removing.url}?`} danger confirmLabel="Stop reading" onClose={() => setRemoving(null)}
            onConfirm={async () => { await rpc("zella_website_remove_source", { p_source_id: removing.id }); state.reload(); }}>
            Zella stops reading this site and ignores its pages. Answers already made from it stay in Business knowledge for you to keep or archive.
          </Confirm>
        )}
      </>
    )}</LoadState>
  );
}

function SourceActions({ x, busy, act, onRemove }) {
  const [freq, setFreq] = useState(x.frequency_hours);
  const [auto, setAuto] = useState(x.auto_approve_new);
  if (x.status === "pending_approval") {
    return (
      <div className="zs-actions">
        <select aria-label="How often" value={freq} onChange={(e) => setFreq(Number(e.target.value))}>{FREQUENCY.map(([h, l]) => <option key={h} value={h}>{l}</option>)}</select>
        <label style={{ display: "inline-flex", gap: 6, alignItems: "center" }}><input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} />Read new pages automatically</label>
        <button type="button" className="zs-btn sm primary" disabled={busy} onClick={() => act(x.id, () => rpc("zella_website_approve_source", { p_source_id: x.id, p_auto_approve_new: auto, p_frequency_hours: freq }), "Approved. Zella may read this site.")}>Approve: this is my site</button>
        <button type="button" className="zs-btn sm danger-outline" disabled={busy} onClick={onRemove}>Remove</button>
      </div>
    );
  }
  return (
    <div className="zs-actions">
      <select aria-label="How often" value={x.frequency_hours} disabled={busy} onChange={(e) => act(x.id, () => rpc("zella_website_set_source", { p_source_id: x.id, p_frequency_hours: Number(e.target.value) }), "Saved.")}>
        {FREQUENCY.map(([h, l]) => <option key={h} value={h}>{l}</option>)}
      </select>
      <button type="button" className="zs-btn sm" disabled={busy} onClick={() => act(x.id, () => rpc("zella_website_set_source", { p_source_id: x.id, p_auto_approve_new: !x.auto_approve_new }), "Saved.")}>
        {x.auto_approve_new ? "Ask before new pages" : "Read new pages automatically"}</button>
      <button type="button" className="zs-btn sm" disabled={busy} onClick={() => act(x.id, () => rpc("zella_website_set_source", { p_source_id: x.id, p_paused: x.status !== "paused" }), x.status === "paused" ? "Reading again." : "Paused.")}>
        {x.status === "paused" ? "Resume" : "Pause"}</button>
      <button type="button" className="zs-btn sm danger-outline" disabled={busy} onClick={onRemove}>Stop reading</button>
    </div>
  );
}

/* ---------- Offers ---------- */

export function BusinessOffersSettings({ w }) {
  if (!can(w, MANAGE)) return <Banner tone="warn">Offers from Zella are shown to owners and admins. Ask your business owner.</Banner>;
  return (
    <>
      <OffersPanel workspace={w} />
      <Card title="How offers work">
        <Facts rows={[["Who qualifies", "Zella checks your plan, size and industry when you claim"], ["Claiming", w.role === "owner" ? "You can claim offers and enter promo codes" : "Only the business owner can claim; admins can see offers"],
          ["Price changes", "None until the payment provider confirms the payment"], ["Unpaid claims", "Released after the hold period, so they don't count"]]} />
      </Card>
    </>
  );
}
