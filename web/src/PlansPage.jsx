import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import "./OwnerPages.css";
import "./PlansPage.css";
import { Icon } from "./BusinessUI";
import { useDialogFocus } from "./useDialogFocus";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDate } from "./ownerFormat";
import { humanize } from "./copy/labels";
import { Facts, Pager, PAGE, can, friendlyError, rpc } from "./admin/adminOps";
import { planAllowances, planFeatures } from "./copy/planAllowances";
import { allowanceText, balanceText, planFacts, priceText, tierName, tierShort } from "./businessPlans.js";

const SUB_TONE = {
  trial: "info", active: "success", renewal_due: "warning", past_due: "danger",
  grace_period: "warning", cancelled: "neutral", expired: "neutral",
};

const EMPTY_PLAN = { planId: "", name: "", description: "", isActive: true };

// One empty value, in the muted style every table and drawer uses ("None", never a blank cell).
function EmptyValue({ label = "None" }) {
  return <span className="empty-value">{label}</span>;
}

function subscriptionBadge(row) {
  if (row.subscription) return <Pill tone={SUB_TONE[row.subscription.status] ?? "neutral"}>{humanize(row.subscription.status)}</Pill>;
  return row.plan ? <EmptyValue /> : <Pill tone="neutral">No plan</Pill>;
}

// The drawer frame: eyebrow, title and status on top, then the content, then a footer that stays in view.
function PlanDrawerFrame({ eyebrow, title, status, footer, onClose, children }) {
  const dialogRef = useDialogFocus(onClose);
  return createPortal(
    <div className="owner-modal-overlay ao-drawer-overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <aside ref={dialogRef} tabIndex={-1} className="owner-modal ao-drawer pp-drawer" role="dialog" aria-modal="true" aria-label={`${eyebrow}: ${title}`}>
        <header className="pp-drawer-head">
          <div className="pp-drawer-titles">
            <div className="pp-drawer-eyebrow">{eyebrow}</div>
            <h2 className="pp-drawer-title" title={title}>{title}</h2>
          </div>
          {status}
          <button type="button" className="owner-icon-button" aria-label="Close" onClick={onClose}><Icon name="close" size="sm" /></button>
        </header>
        <div className="pp-drawer-body">{children}</div>
        {footer && <footer className="ao-drawer-foot pp-drawer-foot">{footer}</footer>}
      </aside>
    </div>,
    document.body
  );
}

// CFG-14: one business's plan, its saved versions and this period's balances (zella_admin_plan_get and
// zella_billing_overview, both billing.view). Read only: plans are changed in the business's Plan & pricing step.
function PlanDrawer({ row, onClose, onOpenBusiness }) {
  const [state, setState] = useState({ loading: true });
  useEffect(() => {
    let live = true;
    Promise.all([rpc("zella_admin_plan_get", { p_business_id: row.businessId }), rpc("zella_billing_overview", { p_business_id: row.businessId })])
      .then(([plan, overview]) => live && setState({ plan, overview }))
      .catch((e) => live && setState({ error: friendlyError(e) }));
    return () => { live = false; };
  }, [row.businessId]);
  const versions = state.plan?.versions ?? [];
  const balances = state.overview?.balances ?? [];
  const period = state.overview?.period;
  return (
    <PlanDrawerFrame
      eyebrow="Plan"
      title={row.businessName}
      status={row.subscription ? subscriptionBadge(row) : null}
      onClose={onClose}
      footer={<button type="button" className="owner-secondary-button" onClick={() => { onClose(); onOpenBusiness(row.businessId); }}>Open business</button>}
    >
      <Facts rows={[...planFacts(row.plan), ["Subscription", row.subscription ? humanize(row.subscription.status) : <EmptyValue key="none" />]]} />
      {state.loading ? <p className="op-muted pp-drawer-note">Loading balances…</p>
        : state.error ? <div className="owner-form-error" role="alert">{state.error}</div>
        : (
          <>
            <section className="drawer-section">
              <h3>This period</h3>
              {period ? <p className="op-muted pp-drawer-note">{formatDate(period.from)} to {formatDate(period.to)}{period.trial ? " (trial)" : ""}, {period.days_left} days left</p>
                : <p className="op-muted pp-drawer-note">No billing period is open yet.</p>}
              {balances.length ? <Facts rows={balances.map(balanceText)} /> : <p className="op-muted pp-drawer-note">No allowances recorded for this period yet.</p>}
            </section>
            <section className="drawer-section">
              <h3>Saved versions</h3>
              {versions.length ? (
                <div className="pp-versions-wrap">
                  <table className="owner-table pp-versions">
                    <thead><tr><th>Version</th><th>Plan</th><th className="num">Price</th><th>Saved</th></tr></thead>
                    <tbody>
                      {versions.map((v) => (
                        <tr key={v.version}>
                          <td className="pp-tabular">{v.version}</td>
                          <td>{tierName(v.tier)}</td>
                          <td className="num">{priceText({ priceCents: v.price_cents, billingInterval: v.billing_interval, setupFeeCents: 0 })}</td>
                          <td className="pp-nowrap">{formatDate(v.saved_at)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ) : <p className="op-muted pp-drawer-note">No plan saved yet.</p>}
            </section>
          </>
        )}
      <div className="pp-banner" role="note">
        <Icon name="info" />
        <p><strong>Payments aren't connected yet,</strong> so nothing is charged. Change this plan in the business's setup, at the Plan & pricing step.</p>
      </div>
    </PlanDrawerFrame>
  );
}

export default function PlansPage({ onOpenBusiness }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [editing, setEditing] = useState(null);
  const [me, setMe] = useState(null);
  const [list, setList] = useState({ key: null, data: null, error: "" });
  const [reloads, setReloads] = useState(0);
  const [offset, setOffset] = useState(0);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(null);
  const [updatedAt, setUpdatedAt] = useState(null);
  // CFG-19: each editor shows only to roles that may save it (the server checks the same permission)
  const canEditCatalog = can(me, "plans.manage");

  useEffect(() => {
    let live = true;
    callOwnerFunction("me_admin").then((m) => live && setMe(m)).catch(() => live && setMe(null));
    return () => { live = false; };
  }, []);

  // CFG-14, CFG-21: every business with its own plan, a page at a time
  // only the latest request's answer is kept; while it is on its way the list says it is loading
  const listKey = `${offset}|${query}|${reloads}`;
  useEffect(() => {
    let live = true;
    callOwnerFunction("business_plans_list", { offset, limit: PAGE, search: query })
      .then((data) => live && setList({ key: listKey, data, error: "" }))
      .catch((e) => live && setList({ key: listKey, data: null, error: friendlyError(e) }));
    return () => { live = false; };
  }, [offset, query, listKey]);
  const listLoading = list.key !== listKey;

  const loadId = useRef(0);
  const load = useCallback(async () => {
    const id = ++loadId.current;
    setLoading(true);
    setError("");
    try {
      const result = await callOwnerFunction("plans_list");
      if (id === loadId.current) { setData(result); setUpdatedAt(new Date()); }
    } catch (err) {
      if (id === loadId.current) setError(friendlyError(err));
    } finally {
      if (id === loadId.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function save(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      await callOwnerFunction("plan_save", editing);
      setEditing(null);
      await load();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="owner-page pp-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Configuration</div>
          <h1>Plans & subscriptions</h1>
          <p>Each business's own plan: tier, version, price, allowances and this period's balances.</p>
        </div>
        <div className="op-heading-actions pp-heading-actions">
          {updatedAt && <span className="pp-updated">Updated {updatedAt.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })}</span>}
          <button type="button" className="owner-secondary-button op-small sm pp-refresh" onClick={() => { load(); setReloads((n) => n + 1); }} disabled={loading}>
            <Icon name="refresh" size="sm" />{loading ? "Loading" : "Refresh"}
          </button>
        </div>
      </div>

      <div className="wiz-note op-gap">
        <strong>Prices are set per business</strong> in Create Business, at the Plan & pricing step. Payments aren't
        connected yet, so nothing here charges anyone.
      </div>

      <section className="owner-panel op-gap">
        <div className="owner-panel-heading ag-toolbar">
          <div>
            <h2>Business plans</h2>
            <p>{list.data ? `${list.data.withPlan} of ${list.data.total} businesses have a plan saved.` : "Every business and the plan saved for it."}</p>
          </div>
          <form onSubmit={(e) => { e.preventDefault(); setOffset(0); setQuery(search.trim()); }}>
            <input className="ag-search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search business" aria-label="Search business" />
          </form>
        </div>
        {list.error && <div className="owner-form-error" role="alert">{list.error}</div>}
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table pp-table">
            <thead><tr><th>Business</th><th>Plan</th><th className="num">Price</th><th>Allowances</th><th>Subscription</th><th className="col-actions"><span className="pp-sr-only">Actions</span></th></tr></thead>
            <tbody>
              {(list.data?.businesses ?? []).map((b) => (
                <tr key={b.businessId}>
                  <td className="pp-business">
                    <button type="button" className="op-name pp-name" title={b.businessName} onClick={() => onOpenBusiness(b.businessId)}>{b.businessName}</button>
                    {b.plan && <span className="pp-phone-line">{tierShort(b.plan)}, {priceText(b.plan)}</span>}
                  </td>
                  <td className="pp-nowrap" data-label="Plan">{b.plan ? tierShort(b.plan) : <EmptyValue />}</td>
                  <td className="num" data-label="Price">{b.plan ? priceText(b.plan) : <EmptyValue />}</td>
                  <td className="pp-nowrap" data-label="Allowances">{b.plan ? allowanceText(b.plan) : <EmptyValue />}</td>
                  <td className="pp-sub" data-label="Subscription">{subscriptionBadge(b)}</td>
                  <td className="col-actions">
                    {b.plan
                      ? <button type="button" className="owner-secondary-button op-small sm" onClick={() => setOpen(b)} aria-label={`Plan details for ${b.businessName}`}>Details</button>
                      : <button type="button" className="owner-secondary-button op-small sm" onClick={() => onOpenBusiness(b.businessId)} aria-label={`Set up a plan for ${b.businessName}`}>Set up plan</button>}
                  </td>
                </tr>
              ))}
              {!list.data?.businesses?.length && (
                <tr className="pp-empty-row"><td colSpan={6}><div className="op-empty">{listLoading ? "Loading..." : list.error ? "Couldn't load this list. Try again with Refresh." : query ? "No business matches this search." : "No businesses yet."}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
        {list.data && <Pager total={list.data.total} offset={offset} onChange={setOffset} />}
      </section>
      {open && <PlanDrawer row={open} onClose={() => setOpen(null)} onOpenBusiness={onOpenBusiness} />}

      <section className="owner-panel op-gap">
        <div className="owner-panel-heading">
          <div>
            <h2>Fallback limits</h2>
            <p>Shared plans whose limits apply only to a business with no plan of its own. Their prices aren't used: each business's price is on its own plan.</p>
          </div>
          {canEditCatalog && (
            <button type="button" className="owner-secondary-button" onClick={() => setEditing({ ...EMPTY_PLAN })} disabled={busy}>＋ New shared plan</button>
          )}
        </div>
      </section>

      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}

      {editing && (
        <form className="wiz-section op-gap" onSubmit={save}>
          <div className="wiz-section-head"><div><h3>{editing.planId ? "Edit plan" : "New plan"}</h3></div></div>
          <div className="owner-form-grid">
            <label className="owner-field">
              <span>Plan name *</span>
              <input required value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} />
            </label>
            <label className="owner-field">
              <span>Accepted from the payment provider</span>
              <select value={editing.isActive ? "yes" : "no"} onChange={(e) => setEditing({ ...editing, isActive: e.target.value === "yes" })}>
                <option value="yes">Yes</option>
                <option value="no">No</option>
              </select>
            </label>
            <label className="owner-field wiz-field-full">
              <span>Description</span>
              <input value={editing.description} onChange={(e) => setEditing({ ...editing, description: e.target.value })} />
            </label>
          </div>
          <div className="ic-actions">
            <button type="button" className="owner-secondary-button" onClick={() => setEditing(null)} disabled={busy}>Cancel</button>
            <button type="submit" className="owner-primary-button" disabled={busy || !editing.name.trim()}>{busy ? "Saving..." : "Save plan"}</button>
          </div>
        </form>
      )}

      <div className="pl-grid op-gap">
        {(data?.plans ?? []).map((p) => {
          const features = planFeatures(p.features);
          const allowances = planAllowances(p.limits);
          return (
            <section key={p.id} className={`owner-panel pl-card ${p.is_active ? "" : "off"}`}>
              <div className="pl-head">
                <div>
                  <h2>{p.name}</h2>
                  {p.description && <p>{p.description}</p>}
                </div>
                <Pill tone={p.is_active ? "success" : "neutral"}>{p.is_active ? "Accepted" : "Not accepted"}</Pill>
              </div>
              <div className="op-muted">Payment provider name: {p.slug}</div>
              {features.length > 0 && (
                <div className="op-rule-block"><h4>Features</h4><ul className="op-bullets">{features.map(([label, value]) => <li key={label}>{label}: <strong>{value}</strong></li>)}</ul></div>
              )}
              <div className="op-rule-block"><h4>Allowances</h4><ul className="op-bullets">{allowances.map(([label, value]) => <li key={label}>{label}: <strong>{value}</strong></li>)}</ul></div>
              <div className="pl-foot">
                <span className="op-muted">{p.subscriptions} {p.subscriptions === 1 ? "business" : "businesses"} linked</span>
                {canEditCatalog && (
                  <button
                    type="button"
                    className="op-link"
                    onClick={() => setEditing({ planId: p.id, name: p.name, description: p.description || "", isActive: p.is_active })}
                  >
                    Edit
                  </button>
                )}
              </div>
            </section>
          );
        })}
        {!data?.plans?.length && (
          <div className="owner-panel"><div className="op-empty">{loading ? "Loading plans..." : !data ? "Couldn't load this list. Try again with Refresh, or reload the page." : "No plans yet."}</div></div>
        )}
      </div>

    </section>
  );
}
