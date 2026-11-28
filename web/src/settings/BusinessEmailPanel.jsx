import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { Banner, Card, Confirm, Facts, Field, LoadState, Pill, Table, useAsync } from "./SettingsKit";
import { mailboxLimits, mailboxReturn, reasonWords, recordRows, senderSummary } from "../businessEmailSetup";

// Settings > SMS, email and messages > Business email address (docs/ARCHITECTURE.md §14.4). The business's customer
// emails come from its own address: a connected Gmail or Outlook mailbox (only the business's owner or an admin signs
// in, on the provider's own page; Zella Voice never sees the password), or a verified domain (often set up with the
// Zella Voice team in Create Business). Everything is checked again on the server (business-email,
// sql/zella_business_email.sql); a button hidden here is also refused there (UX-3).

async function callEmail(body) {
  const { data, error } = await supabase.functions.invoke("business-email", { body });
  if (!error) return data;
  try { return (await error.context?.json?.()) ?? { ok: false, error: "try_again" }; } catch { return { ok: false, error: "try_again" }; }
}

// Back from the provider: the code and state arrive in the address fragment. The sign in is finished here, once, with
// this person's own sign in; business-email checks they started it.
let finishing;
function startMailboxFinish() {
  const frag = new URLSearchParams(typeof window === "undefined" ? "" : window.location.hash.slice(1));
  const code = frag.get("mailbox_code"), state = frag.get("mailbox_state");
  if (!code || !state) return null;
  window.history.replaceState(null, "", window.location.pathname + window.location.search);   // used once; kept out of history
  return callEmail({ action: "mailbox_finish", code, state });
}

// The owner's "Connect your mailbox" link (an email from the Zella Voice team, owner, 27 Nov 2026): its one time token
// arrives in the address fragment. It is used up once, here, with the owner's own sign in; business-email checks the
// link is theirs and that they are still the owner, then this page offers the usual Connect Gmail and Connect Outlook.
let opening;
function startLinkOpen() {
  const frag = new URLSearchParams(typeof window === "undefined" ? "" : window.location.hash.slice(1));
  const token = frag.get("mailbox_link");
  if (!token) return null;
  window.history.replaceState(null, "", window.location.pathname + window.location.search);   // used once; kept out of history
  return callEmail({ action: "mailbox_link_open", token: token.slice(0, 100) });
}

const BOX = { gmail: "Gmail", outlook: "Outlook" };
const TONE = { success: "success", danger: "danger", neutral: "" };

export function BusinessEmailPanel({ w }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_business_email_status", { p_business_id: w.id });
    if (error) throw new Error(/zella_business_email_status|PGRST202|schema cache/i.test(`${error.code} ${error.message}`) ? "business email setup isn't installed on the server yet" : "the server didn't answer");
    return data;
  }, [w.id]);
  const canManage = ["owner", "admin"].includes(w.role);
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState(() => mailboxReturn(typeof window === "undefined" ? "" : window.location.search));
  const [asking, setAsking] = useState(false);
  const [address, setAddress] = useState("");

  useEffect(() => {
    // started once per page load; every run of this effect waits for the same answer
    finishing ??= startMailboxFinish();
    if (!finishing) return;
    let live = true;
    setBusy("finish");
    finishing.then((answer) => {
      if (!live) return;
      finishing = undefined;
      setBusy("");
      setMessage(answer?.ok ? { tone: "success", text: `Connected. Customer emails can now come from ${answer.account}.` } : { tone: "error", text: reasonWords(answer?.error) });
      if (answer?.ok) state.reload();
    });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    opening ??= startLinkOpen();
    if (!opening) return;
    let live = true;
    setBusy("link");
    opening.then((answer) => {
      if (!live) return;
      opening = undefined;
      setBusy("");
      if (!answer?.ok) return setMessage({ tone: "error", text: reasonWords(answer?.error) });
      setMessage(answer.business_id === w.id
        ? { tone: "success", text: "Your link is open. Choose Connect Gmail or Connect Outlook below, then sign in with Google or Microsoft on their own page. Zella Voice never sees your password." }
        : { tone: "warning", text: `This link is for ${answer.business_name || "another business"}. Switch to it, then connect its mailbox here in Settings.` });
    });
    return () => { live = false; };
  }, [w.id]);

  async function connect(provider) {
    setMessage(null); setBusy(provider);
    const answer = await callEmail({ action: "mailbox_start", business_id: w.id, provider });
    if (!answer?.ok || !answer.url) {
      setBusy("");
      return setMessage({ tone: "error", text: answer?.error === "provider_not_configured" ? `${BOX[provider]} can't be connected yet: Zella Voice's connection with ${provider === "gmail" ? "Google" : "Microsoft"} isn't set up. Contact Zella Voice support.`
        : answer?.error === "not_allowed" ? "Only the business's owner and admins can connect its mailbox." : reasonWords(answer?.error) });
    }
    window.location.assign(answer.url);   // the provider's own sign in page; Zella Voice never sees the password
  }
  async function act(kind, body, done) {
    setMessage(null); setBusy(kind);
    const answer = await callEmail({ business_id: w.id, ...body });
    setBusy("");
    if (!answer?.ok) { setMessage({ tone: "error", text: reasonWords(answer?.error) }); return false; }
    setMessage({ tone: "success", text: done(answer) });
    state.reload();
    return true;
  }

  return (
    <LoadState state={state}>{(s) => {
      const summary = senderSummary(s);
      const rows = recordRows(s.dns_records);
      return (
        <>
          {message && <Banner tone={message.tone}>{message.text}</Banner>}
          <Card title="Who sends your customer emails" sub="Reminders, confirmations, follow ups and marketing come from your business's name and address, on every plan.">
            <Facts rows={[["Now", summary.text], ["Status", <Pill key="s" tone={TONE[summary.tone]}>{summary.badge}</Pill>]]} />
          </Card>

          <Card title="Connect Gmail or Outlook" sub="Sign in on Google's or Microsoft's own page and allow sending. Zella Voice only sends; it never reads your mailbox. It sends at most 80% of the provider's daily limit and 20 emails a minute. Past the daily limit, the rest of that day goes from Zella Voice's address with your business name, and you are told."
            actions={canManage && (
              <>
                <button type="button" className="zs-btn sm" disabled={!!busy} onClick={() => connect("gmail")}>{busy === "finish" ? "Connecting…" : busy === "link" ? "Opening your link…" : busy === "gmail" ? "Opening Google…" : s.mailbox_provider === "gmail" ? "Reconnect Gmail" : "Connect Gmail"}</button>
                <button type="button" className="zs-btn sm" disabled={!!busy} onClick={() => connect("outlook")}>{busy === "outlook" ? "Opening Microsoft…" : s.mailbox_provider === "outlook" ? "Reconnect Outlook" : "Connect Outlook"}</button>
              </>
            )}>
            {s.route === "mailbox"
              ? <Facts rows={[["Mailbox", `${BOX[s.mailbox_provider] ?? "Mailbox"}: ${s.mailbox_account}`], ["Connection", s.mailbox_status === "connected" ? "Connected" : "Reconnect needed"],
                  ...(mailboxLimits(s) ? [["Limits", mailboxLimits(s)]] : [])]} />
              : <p className="zs-muted">{canManage ? "No mailbox connected. Connecting one replaces a business domain set up before." : "No mailbox connected. The owner or an admin can connect one."}</p>}
          </Card>

          <Card title="Your own domain" sub="The business adds a few DNS records where its domain is managed. Works with any mail service and has no daily limit.">
            {s.route === "domain" && rows.length > 0 && (
              <>
                <Facts rows={[["Address", s.address], ["Domain", s.domain], ["Verified", s.domain_status === "verified" ? "Yes" : "Not yet"]]} />
                <Table rowKey={(r) => r.key} rows={rows} columns={[["Type", (r) => r.type], ["Name", (r) => r.name],
                  ["Value", (r) => <span className="owner-cell-truncate" title={r.value}>{r.value}</span>], ["Priority", (r) => r.priority || "None"],
                  ["Checked", (r) => <Pill tone={r.ok ? "success" : ""}>{r.ok ? "Found" : "Not yet"}</Pill>]]} />
                {canManage && (
                  <div className="zs-actions">
                    <button type="button" className="zs-btn sm" disabled={!!busy} onClick={() => act("verify", { action: "domain_verify" }, (a) => a.domain_status === "verified" ? "Verified." : "Not verified yet. DNS changes can take up to a day to be seen; try again later.")}>
                      {busy === "verify" ? "Checking…" : "Verify"}
                    </button>
                  </div>
                )}
              </>
            )}
            {s.route !== "domain" && canManage && (
              <form className="zs-actions" onSubmit={(e) => { e.preventDefault(); act("start", { action: "domain_start", address: address.trim() }, () => "DNS records ready. Add them where your domain is managed, then press Verify."); }}>
                <Field label="Business email address" hint="An address on your own domain. Gmail and Outlook addresses connect above instead.">
                  <input type="email" value={address} maxLength={254} autoComplete="off" onChange={(e) => setAddress(e.target.value)} placeholder="hello@yourbusiness.com" />
                </Field>
                <button type="submit" className="zs-btn sm" disabled={!!busy || !address.trim()}>{busy === "start" ? "Getting the records…" : "Show the DNS records"}</button>
              </form>
            )}
            {s.route !== "domain" && !canManage && <p className="zs-muted">No business domain set up.</p>}
          </Card>

          {canManage && s.route && (
            <Card title="Stop using your own address" sub="Customer emails go back to your business name at Zella Voice's address, with replies to your business email."
              actions={<button type="button" className="zs-btn sm danger" disabled={!!busy} onClick={() => setAsking(true)}>Stop using it</button>} />
          )}
          {asking && (
            <Confirm title="Stop sending from your own address?" confirmLabel="Stop using it" danger onClose={() => setAsking(false)}
              onConfirm={async () => { if (!(await act("disconnect", { action: "disconnect" }, () => "Stopped. Customer emails use Zella Voice's address again."))) throw new Error("Nothing was changed. Try again."); }}>
              {s.route === "mailbox" ? "Zella Voice's access to the mailbox is deleted. You can also remove it in your Google or Microsoft account." : "The domain is removed from Zella Voice's email provider. You can remove its DNS records."}
            </Confirm>
          )}
        </>
      );
    }}</LoadState>
  );
}
