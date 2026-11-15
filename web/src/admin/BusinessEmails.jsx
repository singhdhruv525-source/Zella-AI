import { useCallback, useMemo, useState } from "react";
import { EMAILS, GROUPS, renderEmail } from "../emails/businessEmails";
import { DataTable, ErrorNote, Filters, PAGE, Pager, Panel, Pill, Search, Select, rpc, useLoad, when } from "./adminOps";

// Admin > Messaging > Emails to businesses: every email Zella Voice sends to a business, previewed with made up
// sample values (web/src/emails/businessEmails.js), and the platform outbox (sql/zella_platform_emails.sql).
// Nothing on this page sends an email.

const STATUS = { queued: ["Waiting", "neutral"], sending: ["Sending", "info"], sent: ["Sent", "success"], dry_run: ["Test mode (not sent)", "neutral"],
  suppressed: ["Switched off by the person", "neutral"], failed: ["Failed", "danger"], held: ["Held for a person", "warning"] };

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
      <Panel title="Emails to businesses" description={`All ${EMAILS.length} emails Zella Voice sends to a business's owner, billing contacts and team, shown with made up sample values. Wording lives in web/src/emails/businessEmails.js; the server sends from the same file.`}>
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
  const [f, setF] = useState({ status: null, code: null, offset: 0 });
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const log = useLoad(() => rpc("zella_admin_platform_emails", { p_status: f.status, p_code: f.code, p_limit: PAGE, p_offset: f.offset }), [f]);
  const missing = /zella_admin_platform_emails|PGRST202|does not exist/i.test(String(log.error?.message ?? log.error ?? ""));
  return (
    <Panel title="Sent to businesses" description="The platform outbox. While email sending is off, emails are marked test mode and nothing leaves. Each email is sent once; one that keeps failing is held for a person.">
      {missing ? <p className="op-muted">The outbox isn't installed on this database yet (sql/zella_platform_emails.sql).</p> : (
        <>
          <Filters>
            <Select label="Status" value={f.status} onChange={set("status")} options={Object.entries(STATUS).map(([k, [l]]) => [k, l])} />
            <Select label="Email" value={f.code} onChange={set("code")} options={EMAILS.map((x) => [x.code, `${x.code} ${x.name}`])} />
          </Filters>
          <ErrorNote error={log.error} onRetry={log.reload} />
          <DataTable error={log.error} loading={log.loading} rows={log.data?.rows} empty="No emails to businesses yet." onRow={(r) => onOpenBusiness?.(r.business_id)}
            columns={[
              ["When", (r) => when(r.created_at)], ["Business", (r) => r.business_name], ["Email", (r) => <span><code>{r.code}</code> {r.subject}</span>],
              ["To", (r) => r.to_email], ["Status", (r) => { const [l, t] = STATUS[r.status] ?? [r.status, "neutral"]; return <Pill tone={t}>{l}</Pill>; }],
              ["Tries", (r) => r.attempts], ["Problem", (r) => r.last_error ?? ""],
            ]} />
          <Pager total={log.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />
        </>
      )}
    </Panel>
  );
}
