import { useEffect, useState } from "react";
import { navigate } from "../router";
import { ErrorBoundary, Icon } from "../BusinessUI";
import { getBillingApi } from "./billingApi";
import { InvoiceCheckout, PackCheckout } from "./PaymentsPanel";
import { useCardUpdate } from "./useCardUpdate";
import "../onboarding/onboarding.css";
import "./payments.css";

// Paying inside the CRM (owner, 27 Nov 2026): a payment opens its own page in the CRM shell (sidebar, top bar and look
// kept), not inline in the Payments panel and not on a separate page.
//   <base>/settings/billing/pay/<invoice id>   one open invoice, with the glass checkout filling the page
//   <base>/settings/billing/pack/<pack code>   buying a pack on the saved card
// The address grants nothing: the server answers only the active owner of the invoice's business, and an invoice of
// another business than this workspace gets the same "couldn't open" page as a made up id. Paying early, before
// Stripe has made the renewal invoice, is not offered (owner decision, 27 Nov 2026).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Back from the bank (3D Secure) or a stale copy of that address: Stripe's query is never trusted. It is removed at once,
// and the page asks our server (double payment case 9).
const STRIPE_RETURN = ["payment_intent", "payment_intent_client_secret", "redirect_status", "setup_intent", "setup_intent_client_secret", "session_id"];
function takeStripeReturn() {
  const u = new URL(window.location.href);
  const had = STRIPE_RETURN.some((k) => u.searchParams.has(k));
  if (had) { STRIPE_RETURN.forEach((k) => u.searchParams.delete(k)); window.history.replaceState(window.history.state, "", u.pathname + u.search + u.hash); }
  return had;
}
const CODE = /^[a-z0-9_]{1,40}$/;
const RES = { minutes: "AI minutes", texts: "texts", emails: "emails" };

export default function BillingPayRoute({ workspace, kind, id, base = "/app" }) {
  const [api, setApi] = useState(null);
  const [returned] = useState(takeStripeReturn);
  const [title, setTitle] = useState(kind === "pack" ? "Buy a pack" : "Pay for your plan");
  useEffect(() => { let alive = true; getBillingApi().then((a) => { if (alive) setApi(a); }); return () => { alive = false; }; }, []);
  const overview = `${base}/settings/billing/invoices`;
  const back = () => navigate(overview);
  const link = (e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); back(); };
  return (
    <section className="zpay-route" aria-labelledby="zpay-route-title">
      <nav className="zpay-route-crumbs" aria-label="Breadcrumb">
        <a href={overview} onClick={link}><Icon name="arrow_back" size="sm" /> Billing and subscription</a>
      </nav>
      <h1 id="zpay-route-title" className="zpay-route-title" tabIndex={-1}>{title}</h1>
      <ErrorBoundary resetKey={`${kind}:${id}`} fallback={(retry) => (
        <div className="zob-state zob-state-box error" role="alert"><Icon name="error" /><div><strong>This page couldn't be shown</strong><p>You weren't charged.</p><button type="button" className="ba-btn sm" onClick={retry}>Try again</button></div></div>
      )}>
        {workspace.role !== "owner" ? <NotFound what={kind === "pack" ? "pack" : "invoice"} />   /* the server refuses too; the same page either way */
          : !api ? <p className="zpay-loading" role="status">Loading…</p>
          // keyed by the address's id: another invoice or pack is a fresh page, never the last one's state (review)
          : kind === "pay" ? <PayInvoice key={`pay:${id}`} api={api} workspace={workspace} id={id} onTitle={setTitle} onDone={back} returned={returned} base={base} />
          : <BuyPack key={`pack:${id}`} api={api} workspace={workspace} code={id} onTitle={setTitle} onDone={back} returned={returned} />}
      </ErrorBoundary>
    </section>
  );
}

function DoneLink({ onDone }) {
  return <div className="zpay-actions zpay-route-done"><button type="button" className="ba-btn primary" onClick={onDone}><Icon name="arrow_back" size="sm" /> Back to Billing and subscription</button></div>;
}

// an add on whose card was declined after the plan payment: its own pack page, on THAT purchase (full navigation: the
// payment pages carry their own security policy)
function openPackPurchase(base, code, purchaseId) {
  const q = new URLSearchParams(window.location.search);
  const keep = new URLSearchParams({ purchase: purchaseId });
  if (q.get("scenario") != null) keep.set("scenario", q.get("scenario"));
  window.location.assign(`${base}/settings/billing/pack/${encodeURIComponent(code)}?${keep}`);
}
function PayInvoice({ api, workspace, id, onTitle, onDone, returned, base = "/app" }) {
  const update = useCardUpdate(api, workspace.id);
  const [done, setDone] = useState(false);
  const valid = UUID.test(id);
  return (
    <>
      {valid
        ? <InvoiceCheckout api={api} invoiceId={id.toLowerCase()} businessId={workspace.id} onUpdateCard={update.run}
            onOpenPack={(code, purchaseId) => (CODE.test(code) && UUID.test(String(purchaseId)) ? openPackPurchase(base, code, purchaseId) : null)}
            onInvoice={() => onTitle("Pay for your plan")} onSettled={() => setDone(true)} returned={returned} />
        : <NotFound />}
      {update.error && <p className="ba-error" role="alert">{update.error}</p>}
      {done && <DoneLink onDone={onDone} />}
    </>
  );
}

// the purchase is named in the address once made (replaceState): a reload, Back and Forward show THAT purchase from the
// server, never a second Pay; the id grants nothing (the server answers only the business's owner)
const purchaseInUrl = () => { const p = new URLSearchParams(window.location.search).get("purchase"); return p && UUID.test(p) ? p.toLowerCase() : null; };
function namePurchase(purchaseId) {
  const u = new URL(window.location.href); u.searchParams.set("purchase", purchaseId);
  window.history.replaceState(window.history.state, "", u.pathname + u.search + u.hash);
}
function BuyPack({ api, workspace, code, onTitle, onDone, returned }) {
  const [state, setState] = useState({ status: "loading" });
  const [purchaseId] = useState(purchaseInUrl);
  const [done, setDone] = useState(false);
  const update = useCardUpdate(api, workspace.id);
  const validCode = CODE.test(code);
  useEffect(() => {
    let alive = true;
    if (!validCode) return undefined;
    Promise.all([api.overview(workspace.id), api.cardSummary(workspace.id).catch(() => null)]).then(([o, card]) => {
      if (!alive) return;
      const pack = Array.isArray(o?.packs) ? o.packs.find((p) => p.code === code) : null;
      if (pack) onTitle(`Buy ${Number(pack.quantity).toLocaleString("en-US")} ${RES[pack.resource] ?? pack.resource}`);
      setState(pack ? { status: "ok", pack, card } : { status: "missing" });
    }, () => { if (alive) setState({ status: "missing" }); });
    return () => { alive = false; };
  }, [api, workspace.id, code, validCode]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!validCode) return <NotFound what="pack" />;
  if (state.status === "loading") return <p className="zpay-loading" role="status">Loading…</p>;
  if (state.status === "missing") return <NotFound what="pack" />;
  return (
    <>
      <PackCheckout api={api} businessId={workspace.id} pack={state.pack} card={state.card} onUpdateCard={update.run} onSettled={() => setDone(true)}
        purchaseId={purchaseId} onPurchase={namePurchase} returned={returned || Boolean(purchaseId)} />
      {update.error && <p className="ba-error" role="alert">{update.error}</p>}
      {done && <DoneLink onDone={onDone} />}
    </>
  );
}

export function NotFound({ what = "invoice" }) {
  return (
    <div className="zob-state zob-state-box error" role="alert"><Icon name="error" /><div>
      <strong>{what === "pack" ? "We couldn't open this pack" : "We couldn't open this invoice"}</strong>
      <p>We couldn't find that for your account. Check you're signed in as the business owner.</p>
    </div></div>
  );
}
