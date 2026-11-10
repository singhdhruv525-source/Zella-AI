// The click ripple for every button in both apps (styled in styles/motion.css).
// A ripple from where a button is clicked (pointer or touch). One listener for the whole app; skipped for people who
// prefer reduced motion, and for disabled buttons.
const RIPPLE = ".ba-btn, .zs-btn, .owner-button, .owner-primary-button, .owner-secondary-button, .cp-button, .bd-danger-button, .ba-icon-btn, .owner-icon-button, .ba-segment button, .td-tabs button, .ba-panel-tabs button, .op-tabs button";
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
