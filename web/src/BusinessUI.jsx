import { useEffect } from "react";
import { createPortal } from "react-dom";

// Shared building blocks for the business app (Stitch design).

// Inter and Material Symbols, as in the design. Loaded once.
export function loadBusinessFonts() {
  if (typeof document === "undefined" || document.getElementById("ba-fonts")) return;
  const fonts = [
    "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap",
    "https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@20..48,400,0..1,0&display=block",
  ];
  fonts.forEach((href, index) => {
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    if (index === 0) link.id = "ba-fonts";
    document.head.appendChild(link);
  });
}

export function Icon({ name, size, className = "" }) {
  return (
    <span className={`ba-icon ${size ?? ""} ${className}`} aria-hidden="true">
      {name}
    </span>
  );
}

export function Pill({ tone, dot, pulse, children }) {
  return (
    <span className={`ba-pill ${tone ?? ""}`}>
      {dot && <span className={`ba-dot ${pulse ? "pulse" : ""}`} />}
      {children}
    </span>
  );
}

export function Modal({ title, description, onClose, children, footer, busy, wide }) {
  useEffect(() => {
    const onKey = (event) => event.key === "Escape" && !busy && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, busy]);

  // Stop the page behind from scrolling while the box is open.
  useEffect(() => {
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = previous; };
  }, []);

  const box = (
    <div
      className="ba-modal-backdrop"
      onMouseDown={(event) => event.target === event.currentTarget && !busy && onClose()}
    >
      <section className={`ba-modal ${wide ? "wide" : ""}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="ba-modal-head">
          <div>
            <h2>{title}</h2>
            {description && <p>{description}</p>}
          </div>
          <button type="button" className="ba-btn ghost sm" onClick={onClose} disabled={busy} aria-label="Close">
            <Icon name="close" size="sm" />
          </button>
        </div>
        {children}
        {footer && <div className="ba-modal-foot">{footer}</div>}
      </section>
    </div>
  );

  // Drawn at the top of the app, not inside the page. The sticky header and the
  // page animations create their own layers, and a box opened from inside one of
  // them was trapped there (cut off, behind other cards, or stuck in the header).
  // The app root still carries the colour tokens, so the look is unchanged.
  const host = typeof document !== "undefined" ? document.querySelector(".ba-root, .ba-auth") : null;
  return host ? createPortal(box, host) : box;
}

export function Field({ label, hint, full, bare, children }) {
  const Tag = bare ? "div" : "label";
  return (
    <Tag className={`ba-field ${full ? "full" : ""}`}>
      <span>{label}</span>
      {children}
      {hint && <small>{hint}</small>}
    </Tag>
  );
}

export function personName(person) {
  if (!person) return null;
  return [person.first_name, person.last_name].filter(Boolean).join(" ") || person.company_name || null;
}

export function initials(name) {
  return (name || "?").split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join("");
}
