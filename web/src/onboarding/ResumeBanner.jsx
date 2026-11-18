import { useEffect, useState } from "react";
import { getApi } from "./api";
import { SCREENS } from "./steps";

// In the CRM, for a business owner who left the onboarding journey part way: "Finish setting up", back to the same
// step. It asks the server (contract §5.1) and shows nothing if the journey is finished, not deployed yet, or the
// question fails, so the CRM is never held up by it.
export default function ResumeBanner({ businessId }) {
  const [row, setRow] = useState(null);
  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const list = await (await getApi()).listBusinesses();
        const mine = (Array.isArray(list?.businesses) ? list.businesses : []).find((b) => b.business_id === businessId && b.completed === false);
        if (active) setRow(mine ?? null);
      } catch { /* not deployed yet, or not reachable: nothing to show */ }
    })();
    return () => { active = false; };
  }, [businessId]);
  if (!row) return null;
  const at = SCREENS.findIndex((s) => s.key === row.current_step);
  return (
    <div className="ba-banner" role="status">
      <span>Your setup isn't finished yet.{at >= 0 ? ` You're on step ${at + 1} of ${SCREENS.length}: ${SCREENS[at].label.toLowerCase()}.` : ""}</span>
      <a className="ba-btn primary sm" href={`/welcome/setup?business=${encodeURIComponent(row.business_id)}`}>Finish setting up</a>
    </div>
  );
}
