import { useState } from "react";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Field, useAsync } from "../SettingsKit";

// Choose any business by name: the server searches every business (tenants_search, 25 matches at a time), so an older
// business is found by typing its name. A failed or stale search can't be picked from, and a refused search (a role
// without businesses.view) affects only this field.
export default function BusinessPicker({ value, onChange, label = "Business" }) {
  const [q, setQ] = useState("");
  const found = useAsync(async () => ({ q, result: await callOwnerFunction("tenants_search", { q }) }), [q]);
  const current = found.data?.q === q ? found.data.result : null;
  const rows = !found.loading && !found.error && Array.isArray(current?.rows) ? current.rows : null;
  const status = found.error ? `The business search didn't answer: ${found.error}`
    : found.loading || !current ? "Searching…"
    : !rows ? "The business search isn't available right now."
    : !rows.length ? "No business matches that name."
    : current.total > rows.length ? `Showing ${rows.length} of ${current.total}. Type more of the name to narrow it.` : "";
  return (
    <>
      <Field label={`Find a ${label.toLowerCase()}`} hint="Type part of the name.">
        <input value={q} onChange={(e) => { setQ(e.target.value); onChange(""); }} placeholder="Business name" maxLength={80} />
      </Field>
      <Field label={label} hint={status || undefined}>
        <select value={value} onChange={(e) => onChange(e.target.value)} disabled={!rows?.length}>
          <option value="">Choose…</option>{(rows ?? []).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
        </select>
      </Field>
    </>
  );
}
