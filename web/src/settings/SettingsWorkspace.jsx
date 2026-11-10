import { useMemo, useState } from "react";
import "./settings.css";

// The Settings workspace shared by the admin dashboard and the business app.
// Categories and their subsettings come from a registry, so new settings only
// need a registry entry. Address: <base>/<category>/<subsetting>.
//
// registry: [{ key, label, icon, items: [{ key, label, keywords?, render(ctx) }] }]

function matches(text, words) {
  const hay = text.toLowerCase();
  return words.every((w) => hay.includes(w));
}

export default function SettingsWorkspace({ title = "Settings", description, registry, category, item, base, go, Icon, context }) {
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(() => new Set(category ? [category] : []));

  const cat = registry.find((c) => c.key === category) ?? registry[0];
  const sub = cat.items.find((i) => i.key === item) ?? cat.items[0];
  const wrongAddress = (category && !registry.some((c) => c.key === category)) || (item && !cat.items.some((i) => i.key === item));
  const href = (c, i) => `${base}/${c.key}/${i.key}`;
  const pick = (c, i) => { setQuery(""); go(href(c, i)); };

  const results = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return null;
    return registry.flatMap((c) => c.items
      .filter((i) => matches(`${c.label} ${i.label} ${i.keywords ?? ""}`, words))
      .map((i) => ({ c, i })));
  }, [query, registry]);

  const toggle = (key) => setOpen((s) => {
    const next = new Set(s);
    if (next.has(key)) next.delete(key); else next.add(key);
    return next;
  });
  const isOpen = (key) => open.has(key) || key === cat.key;

  return (
    <section className="zs">
      <header className="zs-head">
        <div>
          <h1>{title}</h1>
          {description && <p>{description}</p>}
        </div>
      </header>

      <div className="zs-layout">
        <nav className="zs-nav" aria-label="Settings">
          <label className="zs-search">
            <Icon name="search" />
            <input type="search" value={query} placeholder="Search settings" aria-label="Search settings"
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter" && results?.[0]) pick(results[0].c, results[0].i); if (e.key === "Escape") setQuery(""); }} />
          </label>

          {/* Small screens: one menu instead of the tree. */}
          <select className="zs-mobile" aria-label="Choose a setting" value={`${cat.key}/${sub.key}`}
            onChange={(e) => { const [c, i] = e.target.value.split("/"); go(`${base}/${c}/${i}`); }}>
            {registry.map((c) => (
              <optgroup key={c.key} label={c.label}>
                {c.items.map((i) => <option key={i.key} value={`${c.key}/${i.key}`}>{i.label}</option>)}
              </optgroup>
            ))}
          </select>

          {results ? (
            <ul className="zs-results" aria-label="Search results">
              {!results.length && <li className="zs-empty">No settings match "{query.trim()}".</li>}
              {results.map(({ c, i }) => (
                <li key={`${c.key}/${i.key}`}>
                  <button type="button" onClick={() => pick(c, i)}>
                    <strong>{i.label}</strong><small>{c.label}</small>
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <ul className="zs-tree">
              {registry.map((c) => (
                <li key={c.key} className={c.key === cat.key ? "current" : ""}>
                  <button type="button" className="zs-cat" aria-expanded={isOpen(c.key)} onClick={() => toggle(c.key)}>
                    <Icon name={c.icon} />
                    <span className="zs-cat-label">{c.label}</span>
                    <span className="zs-chev" aria-hidden="true">{isOpen(c.key) ? "▾" : "▸"}</span>
                  </button>
                  {isOpen(c.key) && (
                    <ul>
                      {c.items.map((i) => {
                        const active = c.key === cat.key && i.key === sub.key;
                        return (
                          <li key={i.key}>
                            <a href={href(c, i)} className={active ? "active" : ""} aria-current={active ? "page" : undefined}
                              onClick={(e) => { e.preventDefault(); pick(c, i); }}>{i.label}</a>
                          </li>
                        );
                      })}
                    </ul>
                  )}
                </li>
              ))}
            </ul>
          )}
        </nav>

        <div className="zs-body">
          <div className="zs-crumbs" aria-label="Breadcrumb">
            <a href={base} onClick={(e) => { e.preventDefault(); go(href(registry[0], registry[0].items[0])); }}>{title}</a>
            <span>/</span>
            <a href={href(cat, cat.items[0])} onClick={(e) => { e.preventDefault(); go(href(cat, cat.items[0])); }}>{cat.label}</a>
            <span>/</span>
            <strong>{sub.label}</strong>
          </div>
          {wrongAddress && <div className="zs-banner warn" role="status">That settings page doesn't exist, so here is {sub.label}.</div>}
          <div key={`${cat.key}/${sub.key}`} className="zs-page">
            <h2 className="zs-title">{sub.label}</h2>
            {sub.description && <p className="zs-desc">{sub.description}</p>}
            {sub.render(context)}
          </div>
        </div>
      </div>
    </section>
  );
}
