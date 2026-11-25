// One business's page, Overview tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { useEffect, useState } from "react";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { friendlyError } from "../admin/adminOps";
import { navigate } from "../router";
import { formatDate } from "../ownerFormat";
import { Card, Facts, Empty, Check, label } from "./shared";
import { AlertsCard, GoLiveCard, GrantPack, NumbersCard, PlanCard, ReadinessCard, UsageCard } from "./OverviewCards";

// Small, Medium or Large: set by a Zella Voice admin, never guessed from the industry. Offers can target it.
// Saved through the admin function (business_size_save: businesses.manage, two step checked, audited; BIZ-08, UI-05).
function BusinessSizeCard({ businessId, size, onSaved, canEdit }) {
  const [value, setValue] = useState(size ?? "");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  useEffect(() => setValue(size ?? ""), [size]);
  async function save() {
    setBusy(true);
    setNotice("");
    setError("");
    try {
      // expectedSize: the size this page showed, so a save from a stale page never overwrites someone else's
      const r = await callOwnerFunction("business_size_save", { businessId, size: value || null, expectedSize: size ?? null });
      setNotice(r?.changed === false ? "Nothing changed." : "Business size saved.");
      onSaved();
    } catch (err) {
      setError(/Unknown action/i.test(err?.message ?? "") ? "Not available yet. The Zella Voice update with this change isn't live." : friendlyError(err));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Card title="Business size" description="Used to decide which offers this business can get.">
      <label className="owner-field">
        <span>Size</span>
        <select value={value} onChange={(e) => setValue(e.target.value)} disabled={!canEdit || busy}>
          <option value="">Not set</option>
          <option value="small">Small</option>
          <option value="medium">Medium</option>
          <option value="large">Large</option>
        </select>
      </label>
      {canEdit && (
        <div className="ic-actions">
          <button type="button" className="owner-primary-button" onClick={save} disabled={busy || value === (size ?? "")}>
            {busy ? "Saving…" : "Save size"}
          </button>
        </div>
      )}
      {notice && <div className="ic-notice op-gap-top" role="status">{notice}</div>}
      {error && <div className="owner-form-error op-gap-top" role="alert">{error}</div>}
    </Card>
  );
}

export default function OverviewTab({ can, data, b, r, kb, term, invitation, phone, enabledModules, isCancelled, isSuspended, canManage, canLifecycle, busy, setPending, onOpenSetup, businessId, load, telnyx, hoursSet, address }) {
  return (
    <div className="op-grid">
      <Card title="Verification" description="The business's registration and the owner's photo ID."
        action={canManage && !isCancelled && (data.documents?.length
          // BIZ-31: Review opens the verification queue for this business; Upload keeps the wizard's step
          ? <button type="button" className="owner-secondary-button" onClick={() => navigate(`/verification?business=${businessId}`)}>Review</button>
          : <button type="button" className="owner-secondary-button" onClick={() => onOpenSetup(businessId)}>Upload</button>)}>
        {data.documentsAvailable === false ? (
          <Empty>Document storage isn't set up yet. Ask the Zella Voice team to finish it.</Empty>
        ) : (
          <ul className="op-checks">
            {[["business_registration", "Business registration"], ["owner_identity", "Owner's photo ID"]].map(([kind, label]) => {
              const doc = (data.documents ?? []).find((d) => d.kind === kind);
              const state = !doc ? "Not uploaded" : doc.status === "verified" ? "Verified" : doc.status === "rejected" ? `Rejected: ${doc.review_note ?? "no reason given"}` : "Waiting for review";
              return <Check key={kind} ok={doc?.status === "verified"} title={label} detail={state} />;
            })}
          </ul>
        )}
      </Card>
      {data.readiness ? <ReadinessCard readiness={data.readiness} /> : (
      <Card title="Setup progress" description="What's done and what's left before this business goes live.">
        <ul className="op-checks">
          <Check ok title="Business details" detail={`${data.industryName}, ${b.timezone}`} />
          <Check
            ok={Boolean(invitation)}
            title="Owner"
            detail={invitation ? `${invitation.owner_name} · invitation ${invitation.status}` : "Owner not added"}
          />
          <Check ok={enabledModules.length > 0} title="Modules" detail={`${enabledModules.length} of ${data.modules.length} enabled`} />
          <Check
            ok={(kb.services?.length || 0) + (kb.faqs?.length || 0) > 0}
            later
            title="AI receptionist knowledge"
            detail={`${kb.services?.length || 0} ${term("services").toLowerCase()} · ${kb.faqs?.length || 0} FAQs · hours ${hoursSet ? "set" : "not set"}`}
          />
          <Check ok={Boolean(phone)} later title="Phone setup choice" detail={phone ? label(phone.mode) : "Not chosen"} />
          <Check
            ok={Boolean(telnyx)}
            later
            title="Phone number connected"
            detail={telnyx ? `Connected${telnyx.account_email ? ` · ${telnyx.account_email}` : ""}` : "Not connected yet"}
          />
          <Check ok={r.status === "active"} later title="AI receptionist live" detail={r.status === "active" ? "Answering calls" : "Off until phone and voice agent are connected"} />
          <Check ok={invitation?.status === "accepted"} later title="Owner accepted invitation" detail={invitation?.status === "accepted" ? `Accepted ${formatDate(invitation.accepted_at)}` : "Not yet"} />
        </ul>
      </Card>
      )}
      <GoLiveCard activation={data.activation} />

      <PlanCard plan={data.plan} />
      <UsageCard usage={data.usage} action={can?.("billing.manage") && <GrantPack businessId={businessId} onGranted={() => load()} />} />
      <NumbersCard numbers={data.numbers} />
      <AlertsCard alerts={data.alerts} />
      <Card title="Business information">
        <Facts items={[
          ["Business name", b.name],
          ["Legal name", b.legal_name],
          ["Industry", data.industryName],
          ["Timezone", b.timezone],
          ["Business email", b.email],
          ["Business phone", b.phone],
          ["Website", b.website],
          ["Address", address],
          ["Created", formatDate(b.created_at)],
          ["Calls recorded", String(data.callCount)],
          ["Support tickets", String(data.tickets.length)],
        ]} />
      </Card>

      <BusinessSizeCard businessId={businessId} size={b.business_size} onSaved={load} canEdit={canManage} />

      {!isCancelled && canLifecycle && (
        <Card title="Manage business" description="Stop a business now, or end its membership when its month is over.">
          <div className="bd-manage">
            {isSuspended ? (
              <div>
                <strong>Reactivate</strong>
                <span>Start everything that was running before the suspension.</span>
                <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("reactivate")} disabled={busy}>Reactivate</button>
              </div>
            ) : (
              <div>
                <strong>Suspend now</strong>
                <span>Stops the workspace, receptionist and automations immediately. For example, a payment problem.</span>
                <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("suspend")} disabled={busy}>Suspend</button>
              </div>
            )}
            {b.cancel_at ? (
              <div>
                <strong>Undo cancellation</strong>
                <span>Currently cancels on {formatDate(b.cancel_at)}.</span>
                <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("undo")} disabled={busy}>Undo</button>
              </div>
            ) : (
              <div>
                <strong>Cancel membership</strong>
                <span>Keeps working until the end of their current month, then stops automatically.</span>
                <button type="button" className="wiz-link-danger bd-inline" onClick={() => setPending("cancel")} disabled={busy}>Cancel at end of month</button>
              </div>
            )}
          </div>
        </Card>
      )}
    </div>
  );
}
