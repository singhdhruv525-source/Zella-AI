import { useEffect, useState } from "react";
import { supabase } from "./supabase";

// Zella's public details (name, support contacts, logo, sign-in headline) and
// any maintenance notice, set by admins in Settings. Safe for anyone to read.
let cached = null;

export function usePlatformInfo() {
  const [info, setInfo] = useState(cached);
  useEffect(() => {
    let live = true;
    supabase.rpc("zella_platform_public_info").then(({ data, error }) => {
      if (error || !live) return;
      cached = data ?? {};
      setInfo(cached);
    });
    return () => { live = false; };
  }, []);
  return info ?? {};
}

const when = (v) => new Date(v).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

// Text for the maintenance banner, or "" when there is none.
export function maintenanceText(info) {
  const m = info?.maintenance;
  if (!m) return "";
  const window = m.starts_at || m.ends_at
    ? ` (${m.starts_at ? when(m.starts_at) : "now"}${m.ends_at ? ` to ${when(m.ends_at)}` : ""})`
    : "";
  return `${m.state === "scheduled" ? "Scheduled maintenance" : "Maintenance"}${window}: ${m.message ?? ""}`;
}
