// One business's page, Calls tab (UI-10 part a): every call, paged and masked, from zella_admin_calls (the same list
// as Voice & numbers, which masks the caller in the database). No search box here: searching by digits would let
// anyone with businesses.view confirm a caller's full number (critic, BIZ-22). "See all" opens Voice & numbers.
import { useState } from "react";
import { Pill } from "../OwnerOverview";
import { navigate } from "../router";
import { DataTable, ErrorNote, PAGE, Pager, duration, rpc, useLoad, words } from "../admin/adminOps";
import { formatDateTime } from "../ownerFormat";
import { Card } from "./shared";

const since = (days) => new Date(Date.now() - days * 864e5).toISOString();
const tone = (s) => (s === "completed" || s === "answered" ? "success" : s === "missed" || s === "failed" ? "danger" : "neutral");

export default function CallsTab({ data, businessId }) {
  const [offset, setOffset] = useState(0);
  const list = useLoad(() => rpc("zella_admin_calls", {
    p_from: since(365), p_to: null, p_business: businessId, p_direction: null, p_status: null, p_outcome: null,
    p_failed_only: false, p_q: null, p_limit: PAGE, p_offset: offset,
  }), [businessId, offset]);
  // to_number is often not recorded; the business's own number is what callers dialled
  const own = data.numbers?.rows?.[0]?.e164 ?? null;
  return (
    <Card title="Calls" description={`${data.callCount} calls recorded. Callers' numbers are masked.`}
      action={<button type="button" className="owner-secondary-button op-small" onClick={() => navigate("/voice/calls")}>See all in Voice &amp; numbers</button>}>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable error={list.error} loading={list.loading} rows={list.data?.rows}
        empty="No calls yet. Calls appear once the phone number and AI receptionist are connected."
        columns={[
          ["When", (r) => formatDateTime(r.started_at ?? r.created_at)],
          ["Direction", (r) => words(r.direction)],
          ["Caller", (r) => r.caller ?? "Unknown"],
          ["Number", (r) => r.number ?? own ?? "Not recorded"],
          ["Status", (r) => <Pill tone={tone(r.status)}>{words(r.status)}</Pill>],
          ["Length", (r) => duration(r.duration_seconds)],
          ["Outcome", (r) => (r.outcome ? words(r.outcome) : "Not set")],
        ]} />
      <Pager total={list.data?.total} offset={offset} onChange={setOffset} />
    </Card>
  );
}
