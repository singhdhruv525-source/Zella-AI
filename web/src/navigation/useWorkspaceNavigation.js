import { useEffect, useState } from "react";
import { supabase } from "../supabase";

// Loads one business's navigation configuration from the database (zella_workspace_navigation): its industry, the
// modules that industry supports and which are switched on, the operations label, location, logo and live number.
// The workspace component is keyed by business id, so switching businesses starts this again from "loading" and
// nothing from the previous business can remain.
//
// Until zella_navigation.sql is applied the function doesn't exist; then the same facts come from the workspace list
// the app already loaded (zella_my_workspaces). That is still this business's real configuration, never a default
// industry. Any other failure shows an error with Try again.
export function useWorkspaceNavigation(workspace, preview) {
  const [attempt, setAttempt] = useState(0);
  const [result, setResult] = useState({ key: null, status: "loading", data: null, error: "" });
  const key = `${workspace.id}:${attempt}`;

  useEffect(() => {
    if (preview) return undefined;
    let live = true;
    supabase.rpc("zella_workspace_navigation", { p_business_id: workspace.id }).then(({ data, error }) => {
      if (!live) return;
      if (!error && data) setResult({ key, status: "ready", data, error: "" });
      else if (error?.code === "PGRST202" || /could not find the function/i.test(error?.message ?? "")) {
        setResult({ key, status: "ready", data: fromWorkspace(workspace), error: "" });
      } else setResult({ key, status: "error", data: null, error: error?.message || "No configuration returned" });
    });
    return () => { live = false; };
    // workspace is fixed for this component (keyed by id); key changes on retry.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, preview]);

  if (preview) return { status: "ready", data: preview, retry: () => {} };
  const current = result.key === key ? result : { status: "loading", data: null, error: "" };
  return { ...current, retry: () => setAttempt((n) => n + 1) };
}

function fromWorkspace(workspace) {
  return {
    business_id: workspace.id,
    role: workspace.role,
    industry: workspace.industry ? { name: workspace.industry } : null,
    configured: Boolean(workspace.industry),
    operations_label: workspace.industry ? `${workspace.industry} operations` : null,
    modules: (workspace.modules ?? []).map((slug) => ({ slug, enabled: true, available: true })),
    location: null,
    logo_url: null,
    phone: null,
  };
}
