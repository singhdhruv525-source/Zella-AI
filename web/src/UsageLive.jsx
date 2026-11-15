import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "./supabase";
import { Icon } from "./BusinessUI";
import { fmt as n, usageBanner } from "./usageBanner";

// Live usage on the Today page (owners only; zella_billing_overview refuses everyone else, and then nothing shows).
// Refreshes every minute while the page is visible, when the window gets focus, and straight away when an 80% or 100%
// notice arrives in the bell (BusinessWork dispatches "zella:usage"). Banners follow docs/DESIGN_SYSTEM.md,
// Notifications: a ring that fills to the percentage, a short label, a warm headline, the facts, one action.

const RES = [["minutes", "Minutes", "minutes"], ["texts", "Texts", "texts"], ["emails", "Emails", "emails"]];
const REFRESH_MS = 60000;
function Ring({ pct, tone }) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  return (
    <svg className={`ul-ring ${tone}`} viewBox="0 0 36 36" aria-hidden="true">
      <circle cx="18" cy="18" r="15.5" className="ul-ring-track" />
      <circle cx="18" cy="18" r="15.5" className="ul-ring-fill" pathLength="100" strokeDasharray={`${p} 100`} transform="rotate(-90 18 18)" />
    </svg>
  );
}

const seenKey = (w, res, level, from) => `zella:usage-banner:${w}:${res}:${level}:${from}`;
const wasDismissed = (k) => { try { return localStorage.getItem(k) === "1"; } catch { return false; } };
const dismiss = (k) => { try { localStorage.setItem(k, "1"); } catch { /* private mode: it shows again next time */ } };

export default function UsageLive({ workspace, onGo }) {
  const [data, setData] = useState(null);
  const [state, setState] = useState("loading");   // loading | ready | hidden | failed
  const [at, setAt] = useState(null);
  const [, setTick] = useState(0);
  const latest = useRef(0);   // only the newest request may change what is shown

  const load = useCallback(async () => {
    const mine = ++latest.current;
    const { data: d, error } = await supabase.rpc("zella_billing_overview", { p_business_id: workspace.id });
    if (mine !== latest.current) return;   // a newer refresh started (or the page left): this answer is out of date
    if (error) {
      // not the owner, or billing not installed: show nothing; any other error is shown (stale numbers stay, marked)
      if (/NOT_ALLOWED|PGRST202|zella_billing_overview[^\n]*does not exist/i.test(`${error.code ?? ""} ${error.message ?? ""}`)) setState("hidden");
      else setState("failed");
      return;
    }
    setData(d); setAt(new Date()); setState("ready");
  }, [workspace.id]);

  useEffect(() => {
    load();
    const timer = setInterval(() => { if (document.visibilityState === "visible") load(); }, REFRESH_MS);
    const now = () => load();
    window.addEventListener("focus", now);
    window.addEventListener("zella:usage", now);
    return () => { latest.current += 1; clearInterval(timer); window.removeEventListener("focus", now); window.removeEventListener("zella:usage", now); };
  }, [load]);

  if (state === "hidden" || state === "loading") return null;
  if (state === "failed" && !data) {
    return <section className="ul-wrap" aria-label="Usage this period"><div className="ul-card"><small className="ul-updated" role="status">Usage isn't available right now. It will try again in a minute.</small></div></section>;
  }
  const usage = data?.usage ?? {};
  if (!RES.some(([k]) => usage[k]?.configured)) return null;
  const days = data?.period?.days_left;
  const from = data?.period?.from ?? "";
  const banners = RES.map(([k]) => [k, usageBanner(k, usage[k], days)])
    .filter(([, b]) => b)
    .map(([k, b]) => ({ ...b, key: seenKey(workspace.id, k, b.tone === "urgent" || b.kicker === "Limit reached" ? 100 : 80, from) }))
    .filter((b) => b.tone === "urgent" || !wasDismissed(b.key));
  const ago = at ? Math.round((Date.now() - at.getTime()) / 60000) : null;

  return (
    <section className="ul-wrap" aria-label="Usage this period">
      {banners.map((b) => (
        <div key={b.key} className={`ul-banner tone-${b.tone}`} role={b.tone === "urgent" ? "alert" : "status"}>
          <span className="ul-banner-icon"><Icon name={b.tone === "urgent" ? "error" : "timer"} size="sm" /></span>
          <div className="ul-banner-text">
            <span className="ba-kicker">{b.kicker}</span>
            <strong>{b.title}</strong>
            <p>{b.body}</p>
          </div>
          <div className="ul-banner-actions">
            <button type="button" className="ba-btn sm primary" onClick={() => onGo?.("settings")}>{b.action}</button>
            {b.tone !== "urgent" && <button type="button" className="ba-btn sm ghost" aria-label="Dismiss" onClick={() => { dismiss(b.key); setTick((t) => t + 1); }}><Icon name="close" size="sm" /></button>}
          </div>
        </div>
      ))}
      <div className="ul-card">
        {RES.map(([k, label, unit]) => {
          const u = usage[k];
          if (!u?.configured) return <div key={k} className="ul-item"><div className="ul-item-text"><strong>{label}</strong><small>Starts with your first billing period</small></div></div>;
          const pct = Number(u.percent_used ?? 0);
          const tone = u.exhausted || pct >= 100 ? "urgent" : pct >= 80 ? "heads" : "good";
          return (
            <div key={k} className="ul-item">
              <div className="ul-ring-box"><Ring pct={pct} tone={tone} /><span>{Math.round(pct)}%</span></div>
              <div className="ul-item-text"><strong>{label}</strong><small>{n(u.used)} of {n(u.included)} {unit} used</small></div>
            </div>
          );
        })}
        <small className="ul-updated" aria-live="polite">{state === "failed" ? "Couldn't refresh just now; showing the last numbers" : ago === 0 ? "Updated just now" : `Updated ${ago} min ago`}</small>
      </div>
    </section>
  );
}
