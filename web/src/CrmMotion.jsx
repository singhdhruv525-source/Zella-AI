import { useEffect, useRef, useState } from "react";
import "./CrmMotion.css";

// Numbers count up to their value when a card appears, unless the person prefers less motion.
export function CountUp({ value, duration = 900 }) {
  const target = typeof value === "number" && Number.isFinite(value) ? value : null;
  const [shown, setShown] = useState(target === null ? value : 0);
  const from = useRef(0);
  useEffect(() => {
    if (target === null) { setShown(value); return undefined; }
    const calm = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (calm || target === from.current) { setShown(target); from.current = target; return undefined; }
    const start = performance.now();
    const begin = from.current;
    let frame;
    const tick = (now) => {
      const t = Math.min(1, (now - start) / duration);
      const eased = 1 - Math.pow(1 - t, 3);
      setShown(Math.round(begin + (target - begin) * eased));
      if (t < 1) frame = requestAnimationFrame(tick);
      else from.current = target;
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [target, value, duration]);
  return <>{shown}</>;
}
