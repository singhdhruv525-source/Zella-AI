import { useEffect, useRef, useState } from "react";
import "./CrmMotion.css";

// A ripple from where a button is clicked (pointer or touch). One listener for the whole app; skipped for people who
// prefer reduced motion, and for disabled buttons.
const RIPPLE = ".ba-btn, .ba-icon-btn, .ba-segment button, .td-tabs button, .ba-panel-tabs button";
if (typeof document !== "undefined" && !window.__zellaRipple) {
  window.__zellaRipple = true;
  document.addEventListener("pointerdown", (e) => {
    if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
    const el = e.target instanceof Element ? e.target.closest(RIPPLE) : null;
    if (!el || el.disabled || el.getAttribute("aria-disabled") === "true") return;
    const r = el.getBoundingClientRect();
    const size = Math.max(r.width, r.height);
    const dot = document.createElement("span");
    dot.className = "ba-ripple";
    dot.setAttribute("aria-hidden", "true");
    dot.style.width = dot.style.height = `${size}px`;
    dot.style.left = `${e.clientX - r.left - size / 2}px`;
    dot.style.top = `${e.clientY - r.top - size / 2}px`;
    el.appendChild(dot);
    setTimeout(() => dot.remove(), 600);
  }, { passive: true });
}

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
