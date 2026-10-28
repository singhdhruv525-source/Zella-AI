import { useEffect, useRef, useState } from "react";
import { Icon } from "./BusinessUI";
import { supabase } from "./supabase";
import { chime, deviceAlerts, desktopAlert, tabCount, unlockAlerts } from "./liveAlerts";

// The Zella admin dashboard's bell: open platform alerts (provider down, queues stuck, failed jobs...), newest and most
// severe first. Acknowledge takes one off the list (zella_admin_acknowledge_alert); Monitoring has the full picture.
// Platform alerts are readable by Zella admins only (row level security on platform_alerts).
const RANK = { urgent: 0, warning: 1, info: 2 };
const LABEL = { urgent: "Urgent", warning: "Heads up", info: "Info" };
const ICON = {
  provider_down: "cloud_off", provider_recovered: "cloud_done", queue_backlog: "hourglass_bottom", automation_heartbeat: "monitor_heart",
  automation_stalled: "sync_problem", scheduler_failed: "event_busy", engine_stuck_work: "build", repeated_transfer_failures: "phone_disabled",
};
const ago = (v) => {
  const m = Math.round((Date.now() - new Date(v).getTime()) / 60000);
  return m < 1 ? "just now" : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`;
};

export default function AdminAlertsBell({ onOpenMonitoring }) {
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const seen = useRef(null);
  const box = useRef(null);

  async function load() {
    const { data, error: e } = await supabase.from("platform_alerts").select("id, kind, severity, title, detail, occurrences, last_seen_at, business_id")
      .eq("status", "open").order("last_seen_at", { ascending: false }).limit(40);
    if (e) { setRows([]); return; }
    const list = (data ?? []).sort((a, b) => (RANK[a.severity] ?? 3) - (RANK[b.severity] ?? 3) || new Date(b.last_seen_at) - new Date(a.last_seen_at));
    if (seen.current) {
      const fresh = list.filter((a) => !seen.current.has(a.id));
      if (fresh.length) {
        const prefs = deviceAlerts();
        const top = fresh.find((a) => a.severity === "urgent") ?? fresh[0];
        if (prefs.sound) chime(top.severity === "urgent" ? "urgent" : "info");
        if (prefs.desktop) desktopAlert(top.title, top.detail, () => setOpen(true));
      }
    }
    seen.current = new Set(list.map((a) => a.id));
    setRows(list);
  }
  useEffect(() => {
    unlockAlerts();
    load();
    const timer = setInterval(load, 30000);
    return () => { clearInterval(timer); tabCount(0); };
  }, []);
  useEffect(() => { tabCount((rows ?? []).filter((a) => a.severity !== "info").length); }, [rows]);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (box.current && !box.current.contains(e.target)) setOpen(false); };
    const key = (e) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", key);
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", key); };
  }, [open]);

  async function acknowledge(alert) {
    setBusy(true);
    setError("");
    const { error: e } = await supabase.rpc("zella_admin_acknowledge_alert", { p_alert_id: alert.id });
    setBusy(false);
    if (e) { setError(/does not exist|schema cache|Could not find/i.test(e.message) ? "Acknowledging needs the latest database update." : e.message); return; }
    load();
  }

  const list = rows ?? [];
  const loud = list.filter((a) => a.severity !== "info").length;
  const urgent = list.some((a) => a.severity === "urgent");
  return (
    <div className="owner-bell" ref={box}>
      <button type="button" className="owner-icon-button" aria-label={loud ? `${loud} platform alerts` : "Platform alerts"} aria-expanded={open} title="Platform alerts" onClick={() => setOpen(!open)}>
        <Icon name="notifications" />
        {loud > 0 && <span className={`owner-bell-count ${urgent ? "urgent" : ""}`}>{loud > 9 ? "9+" : loud}</span>}
      </button>
      {open && (
        <div className="owner-bell-panel" role="dialog" aria-label="Platform alerts">
          <div className="owner-bell-head"><strong>Platform alerts</strong><span>{list.length ? `${list.length} open` : ""}</span></div>
          {error && <p className="owner-bell-error" role="alert">{error}</p>}
          {!list.length ? (
            <p className="owner-bell-empty"><Icon name="verified" /> All systems calm. Nothing needs you right now.</p>
          ) : (
            <ul>
              {list.map((a) => (
                <li key={a.id} className={a.severity}>
                  <span className="owner-bell-icon"><Icon name={ICON[a.kind] ?? (a.severity === "urgent" ? "error" : "info")} size="sm" /></span>
                  <div>
                    <strong>{a.title}</strong>
                    {a.detail && <small>{a.detail}</small>}
                    <small>{LABEL[a.severity] ?? a.severity} · {ago(a.last_seen_at)}{a.occurrences > 1 ? ` · ${a.occurrences} times` : ""}</small>
                  </div>
                  <button type="button" className="owner-bell-ack" disabled={busy} onClick={() => acknowledge(a)} title="Acknowledge">Got it</button>
                </li>
              ))}
            </ul>
          )}
          <div className="owner-bell-foot"><button type="button" onClick={() => { setOpen(false); onOpenMonitoring(); }}>Open monitoring</button></div>
        </div>
      )}
    </div>
  );
}
