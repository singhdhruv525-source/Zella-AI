import { useEffect, useState } from "react";
import "../BusinessApp.css";
import "../onboarding/onboarding.css";
import { BusinessSignIn } from "../BusinessAuth";
import { ErrorBoundary, Icon, loadBusinessFonts } from "../BusinessUI";
import { SidebarBrand } from "../navigation/SidebarBrand";
import { getBillingApi } from "./billingApi";
import PaymentsPanel, { InvoiceCheckout } from "./PaymentsPanel";
import { useCardUpdate } from "./useCardUpdate";

// The owner's Payments page (owner decision, 27 Nov 2026: "auto charge plus Pay now"):
//   /pay/invoice/<invoice id>   the emailed Pay now link: sign in, then the glass checkout for that one invoice. The id
//                               alone grants nothing: the server answers only the active owner of the invoice's business.
//   /pay?business=<id>          the same Payments panel as Settings, Billing and subscription, Invoices and payments;
//                               Stripe's card update page returns here (&card=updated).
// Paid shows only when the server confirms it.

loadBusinessFonts();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default function PayPage() {
  const [api, setApi] = useState(null);
  const [session, setSession] = useState(undefined);
  useEffect(() => {
    let active = true, stop = () => {};
    getBillingApi().then(async (a) => {
      if (!active) return;
      setApi(a);
      stop = a.onAuthChange((s) => active && setSession(s));
      const s = await a.getSession().catch(() => null);
      if (active) setSession(s);
    });
    return () => { active = false; stop(); };
  }, []);
  if (!api || session === undefined) return <Frame><p className="zpay-loading" role="status">One moment…</p></Frame>;
  if (!session) return <BusinessSignIn />;
  const path = window.location.pathname;
  const params = new URLSearchParams(window.location.search);
  const invoice = path.match(/^\/pay\/invoice\/([^/]+)\/?$/)?.[1] ?? "";
  if (/^\/pay\/invoice\//.test(path)) return <InvoicePage api={api} invoiceId={UUID.test(invoice) ? invoice.toLowerCase() : null} />;
  const business = params.get("business") ?? "";
  return <PaymentsPage api={api} businessId={UUID.test(business) ? business.toLowerCase() : null} cardReturned={params.get("card") === "updated"} />;
}

function InvoicePage({ api, invoiceId }) {
  const [biz, setBiz] = useState(null);
  useEffect(() => { if (invoiceId) api.invoiceStatus(invoiceId).then((i) => setBiz({ id: i.business_id, name: i.business_name }), () => {}); }, [api, invoiceId]);
  const update = useCardUpdate(api, biz?.id);
  if (!invoiceId) return <Frame title="This link isn't complete"><p className="zob-lead">Open the Pay now link from your email again, or go to Payments in your CRM.</p></Frame>;
  const all = biz ? () => window.location.assign(`/pay?business=${encodeURIComponent(biz.id)}${keepScenario()}`) : null;
  return (
    <Frame title="Pay your invoice" name={biz?.name}>
      <InvoiceCheckout api={api} invoiceId={invoiceId} onBack={all} backLabel="All invoices" onUpdateCard={biz ? update.run : undefined} />
      {update.error && <p className="ba-error" role="alert">{update.error}</p>}
    </Frame>
  );
}

function PaymentsPage({ api, businessId, cardReturned }) {
  useEffect(() => {   // back from Stripe's card page: the flag is shown once, then tidied from the address bar
    if (!cardReturned) return;
    const u = new URL(window.location.href); u.searchParams.delete("card");
    window.history.replaceState(null, "", u.pathname + u.search);
  }, [cardReturned]);
  if (!businessId) return <Frame title="Payments"><p className="zob-lead">Open Payments from Settings, Billing and subscription in your CRM.</p><div className="zob-actions"><a className="ba-btn primary" href="/app">Open my CRM</a></div></Frame>;
  return <Frame title="Payments"><PaymentsPanel api={api} businessId={businessId} cardReturned={cardReturned} /></Frame>;
}

// local previews keep their stand in scenario across pages
const keepScenario = () => { const s = new URLSearchParams(window.location.search).get("scenario"); return s != null ? `&scenario=${encodeURIComponent(s)}` : ""; };

function Frame({ title, name, children }) {
  return (
    <div className="ba-root zob">
      <header className="zob-top">
        <div className="zob-brand"><SidebarBrand caption={name} /></div>
        <a className="ba-btn sm ghost zob-later" href="/app">Open my CRM</a>
      </header>
      <main className="zob-main">
        <div className="zob-card zob-page zpay-page">
          {title && <h1 tabIndex={-1}>{title}</h1>}
          <ErrorBoundary resetKey={title} fallback={(retry) => (
            <div className="zob-state zob-state-box error" role="alert"><Icon name="error" /><div><strong>This page couldn't be shown</strong><p>Nothing was charged.</p><button type="button" className="ba-btn sm" onClick={retry}>Try again</button></div></div>
          )}>{children}</ErrorBoundary>
        </div>
      </main>
    </div>
  );
}
