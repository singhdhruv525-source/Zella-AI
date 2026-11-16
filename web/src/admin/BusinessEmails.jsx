import { useCallback, useEffect, useMemo, useState } from "react";
import { EMAILS, GROUPS, renderEmail } from "../emails/businessEmails";
import { DataTable, Drawer, ErrorNote, Facts, Filters, PAGE, Pager, Panel, Pill, ReasonDialog, Search, Select, friendlyError, rpc, useLoad, useOptions, useToast, when } from "./adminOps";

// Admin > Messaging > Emails to businesses: every email Zella Voice sends to a business, previewed with made up
// sample values (web/src/emails/businessEmails.js), and the platform outbox (sql/zella_platform_emails.sql).
// Nothing on this page sends an email.

const STATUS = { queued: ["Waiting", "neutral"], sending: ["Sending", "info"], sent: ["Sent", "success"], dry_run: ["Test mode (not sent)", "neutral"],
  suppressed: ["Switched off by the person", "neutral"], held: ["Held for a person", "warning"],
  // 'failed' is written only when an admin discards a held email (sql/zella_platform_email_actions.sql)
  failed: ["Discarded", "neutral"] };
const statusPill = (s) => { const [l, t] = STATUS[s] ?? [s, "neutral"]; return <Pill tone={t}>{l}</Pill>; };

export default function BusinessEmails({ onOpenBusiness }) {
  const [q, setQ] = useState("");
  const [group, setGroup] = useState(null);
  const [kind, setKind] = useState(null);
  const [code, setCode] = useState(EMAILS[0].code);
  const [view, setView] = useState("desktop");
  const onSearch = useCallback((v) => setQ(v), []);

  const list = useMemo(() => {
    const words = q.trim().toLowerCase();
    return EMAILS.filter((x) => (!group || x.group === group) && (!kind || (kind === "mandatory") === x.mandatory)
      && (!words || `${x.code} ${x.name} ${x.when}`.toLowerCase().includes(words)));
  }, [q, group, kind]);
  const current = list.find((x) => x.code === code) ?? list[0];
  const shown = useMemo(() => (current ? renderEmail(current.code) : null), [current]);

  return (
    <>
      <Panel title="Emails to businesses" description={`All ${EMAILS.length} emails Zella Voice will send to a business's owner, billing contacts and team, shown with made up sample values. Wording lives in web/src/emails/businessEmails.js. No sender is connected yet, so nothing on this page is sent.`}>
        <Filters>
          <Search value={q} onChange={onSearch} placeholder="Code, name or when" />
          <Select label="Group" value={group} onChange={setGroup} options={GROUPS} />
          <Select label="Type" value={kind} onChange={setKind} options={[["mandatory", "Always sent"], ["optional", "Can be switched off"]]} />
        </Filters>
        {!list.length ? <p className="op-muted">No emails match.</p> : (
          <div className="be-layout">
            <nav className="be-list" aria-label="Emails">
              {GROUPS.filter(([g]) => list.some((x) => x.group === g)).map(([g, label]) => (
                <div key={g}>
                  <h3 className="ao-h3">{label}</h3>
                  <ul>
                    {list.filter((x) => x.group === g).map((x) => (
                      <li key={x.code}>
                        <button type="button" className={x.code === current.code ? "active" : ""} aria-current={x.code === current.code ? "true" : undefined} onClick={() => setCode(x.code)}>
                          <code>{x.code}</code> <span>{x.name}</span>
                        </button>
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </nav>
            <section className="be-preview" aria-label="Preview">
              <dl className="be-facts">
                <div><dt>Subject</dt><dd>{shown.subject}</dd></div>
                <div><dt>Preview line</dt><dd>{shown.preheader}</dd></div>
                <div><dt>Sent when</dt><dd>{current.when}</dd></div>
                <div><dt>Type</dt><dd>{current.mandatory ? <Pill tone="info">Always sent</Pill> : <Pill>Can be switched off</Pill>}</dd></div>
              </dl>
              <div className="be-views" role="group" aria-label="Preview size">
                {[["desktop", "Desktop"], ["mobile", "Phone"], ["text", "Plain text"]].map(([k, l]) => (
                  <button key={k} type="button" className={view === k ? "active" : ""} aria-pressed={view === k} onClick={() => setView(k)}>{l}</button>
                ))}
              </div>
              {view === "text" ? <pre className="be-text">{shown.text}</pre> : (
                <iframe title={`Preview of ${current.name}`} className={`be-frame ${view}`} sandbox="" srcDoc={shown.html} />
              )}
            </section>
          </div>
        )}
      </Panel>
      <Outbox onOpenBusiness={onOpenBusiness} />
    </>
  );
}

function Outbox({ onOpenBusiness }) {
  const [f, setF] = useState({ business: null, status: null, code: null, offset: 0 });
  const [open, setOpen] = useState(null);
  const [toast, say] = useToast();
  const options = useOptions();
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const log = useLoad(() => rpc("zella_admin_platform_emails", { p_business: f.business, p_status: f.status, p_code: f.code, p_limit: PAGE, p_offset: f.offset }), [f]);
  const missing = log.errorCode === "PGRST202";   // the function isn't there: the outbox migration isn't applied yet
  return (
    <Panel title="Sent to businesses" description="The platform outbox, once it is installed. No sender is connected yet, so nothing leaves; while email sending is off, queued emails are marked test mode. Once a sender is connected, each email is sent at most once and one that keeps failing is held for a person, who can release it to try again or discard it.">
      {missing ? <p className="op-muted">The outbox isn't installed on this database yet (sql/zella_platform_emails.sql).</p> : (
        <>
          <Filters>
            <Select label="Business" value={f.business} onChange={set("business")} options={(options.data?.businesses ?? []).map((b) => [b.id, b.name])} />
            <Select label="Status" value={f.status} onChange={set("status")} options={Object.entries(STATUS).map(([k, [l]]) => [k, l])} />
            <Select label="Email" value={f.code} onChange={set("code")} options={EMAILS.map((x) => [x.code, `${x.code} ${x.name}`])} />
          </Filters>
          <ErrorNote error={log.error} onRetry={log.reload} />
          {!log.loading && !log.error && !log.data ? <p className="op-muted" role="status">The outbox didn't answer with any data. Not available right now.</p> : (
          <DataTable error={log.error} loading={log.loading} rows={log.data?.rows} empty="No emails to businesses yet." onRow={(r) => setOpen(r.id)}
            columns={[
              ["When", (r) => when(r.created_at)], ["Business", (r) => r.business_name], ["Email", (r) => <span><code>{r.code}</code> {r.subject}</span>],
              ["To", (r) => r.to_email], ["Status", (r) => statusPill(r.status)],
              ["Tries", (r) => r.attempts], ["Problem", (r) => r.last_error ?? ""],
            ]} />)}
          <Pager total={log.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />
        </>
      )}
      {open && <EmailDrawer id={open} onClose={() => setOpen(null)} onChanged={(text) => { say(text); log.reload(); }} onOpenBusiness={onOpenBusiness} />}
      {toast}
    </Panel>
  );
}

// One email in the outbox: what it says, where it stands, and for a held email, Release or Discard (COM-18, COM-22).
function EmailDrawer({ id, onClose, onChanged, onOpenBusiness }) {
  const [e, setE] = useState(null);
  const [error, setError] = useState("");
  const [view, setView] = useState("html");
  const [confirm, setConfirm] = useState(null);   // "release" | "discard"
  useEffect(() => {
    let live = true;
    rpc("zella_admin_platform_email_detail", { p_id: id }).then((d) => live && setE(d), (err) => live && setError(friendlyError(err)));
    return () => { live = false; };
  }, [id]);
  const act = async (kind, reason) => {
    await rpc(`zella_admin_platform_email_${kind}`, { p_id: id, p_reason: reason });
    onChanged(kind === "release" ? "Released. It goes out with the next send, or in test mode while email sending is off." : "Discarded. It won't be sent.");
    onClose();
  };
  return (
    <Drawer title={e ? `Email ${e.code}: ${e.subject}` : "Email"} icon="mail" onClose={onClose}>
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      {!e && !error && <p className="op-muted" role="status">Loading…</p>}
      {e && (
        <>
          <Facts rows={[
            ["Business", e.business_name], ["To", [e.to_email, ...(e.cc ?? [])].join(", ")], ["Status", statusPill(e.status)],
            ["Tries", e.attempts], ["Problem", e.last_error], ["Queued", when(e.created_at)], e.sent_at && ["Sent", when(e.sent_at)],
            ["Type", e.mandatory ? "Always sent" : "Can be switched off"],
          ]} />
          <div className="ic-actions">
            {onOpenBusiness && <button type="button" className="owner-secondary-button" onClick={() => { onClose(); onOpenBusiness(e.business_id); }}>Open business</button>}
            {e.status === "held" && e.can_manage && (
              <>
                <button type="button" className="owner-secondary-button" onClick={() => setConfirm("discard")}>Discard</button>
                <button type="button" className="owner-primary-button" onClick={() => setConfirm("release")}>Release</button>
              </>
            )}
          </div>
          {e.status === "held" && !e.can_manage && <p className="op-muted">Releasing or discarding a held email needs the Messaging manage permission.</p>}
          <section className="be-preview" aria-label="The email">
            <div className="be-views" role="group" aria-label="Show as">
              {[["html", "Email"], ["text", "Plain text"]].map(([k, l]) => (
                <button key={k} type="button" className={view === k ? "active" : ""} aria-pressed={view === k} onClick={() => setView(k)}>{l}</button>
              ))}
            </div>
            {view === "text" ? <pre className="be-text">{e.text_body}</pre> : (
              <iframe title={`Email ${e.code} as sent`} className="be-frame mobile" sandbox="" srcDoc={e.html} />
            )}
          </section>
        </>
      )}
      {confirm && (
        <ReasonDialog title={confirm === "release" ? "Release this email?" : "Discard this email?"} icon={confirm === "release" ? "send" : "delete"}
          danger={confirm === "discard"} confirmLabel={confirm === "release" ? "Release" : "Discard"}
          onConfirm={(reason) => act(confirm, reason)} onClose={() => setConfirm(null)}>
          <p>{confirm === "release"
            ? "It goes back in the queue with its tries reset. Nothing is sent while email sending is off; then it is marked test mode."
            : "It is never sent. The reason is kept with the email and in the audit log."}</p>
        </ReasonDialog>
      )}
    </Drawer>
  );
}
