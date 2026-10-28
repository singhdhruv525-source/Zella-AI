import { useRef, useState } from "react";
import { supabase } from "../supabase";
import {
  BACKGROUNDS, DEFAULT_APPEARANCE, prepareBackground, removeUploadedBackground, resetAppearance, sidebarMode, updateAppearance, useAppearance,
} from "../appearance";
import { uploadImage } from "./PersonalPanels";
import { Banner, Card, Field } from "./SettingsKit";

// Settings > Personal > Appearance (admin and CRM). Personal only: it changes how Zella looks for the person signed
// in, on every device, and never for anyone else. Every change applies at once and is saved to their account.

const THEMES = [
  { key: "classic", label: "Classic", text: "Light and calm. The standard Zella look." },
  { key: "glass", label: "Glass", text: "Frosted panels over a background picture of your choice." },
];
const SIDEBAR = [
  { key: null, label: "Automatic", text: "A slim dock with Glass, the full list with Classic." },
  { key: "full", label: "Always full", text: "Icons with their names." },
  { key: "compact", label: "Always a dock", text: "Icons only; names appear when you point at one." },
];

export function AppearancePanel() {
  const look = useAppearance();
  const fileInput = useRef(null);
  const [pic, setPic] = useState({ busy: false, error: "" });

  async function upload(file) {
    if (!file) return;
    setPic({ busy: true, error: "" });
    try {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) throw new Error("Your session has ended. Please sign in again.");
      const small = await prepareBackground(file);
      const url = await uploadImage(`user/${user.id}/background`, small);
      const old = look.customUrl;
      updateAppearance({ theme: "glass", background: "custom", customUrl: url });
      if (old && old !== url) removeUploadedBackground(old).catch(() => {});
      setPic({ busy: false, error: "" });
    } catch (err) {
      setPic({ busy: false, error: err.message });
    }
  }
  async function removePicture() {
    const old = look.customUrl;
    updateAppearance({ background: DEFAULT_APPEARANCE.background, customUrl: null });
    if (old) removeUploadedBackground(old).catch(() => {});
  }

  return (
    <>
      <Banner>These settings change how Zella looks for you only, on every device you sign in on. Changes apply straight away.</Banner>

      <Card title="Theme">
        <div className="zs-look-grid" role="radiogroup" aria-label="Theme">
          {THEMES.map((t) => (
            <button key={t.key} type="button" role="radio" aria-checked={look.theme === t.key}
              className={`zs-look ${look.theme === t.key ? "on" : ""}`} onClick={() => updateAppearance({ theme: t.key })}>
              <span className={`zs-look-preview ${t.key}`} aria-hidden="true"><i /><i /><i /></span>
              <strong>{t.label}</strong>
              <small>{t.text}</small>
            </button>
          ))}
        </div>
      </Card>

      <Card title="Background picture" sub="Shown behind the Glass theme.">
        {look.theme !== "glass" && (
          <Banner>The picture appears with the Glass theme. <button type="button" className="zs-link" onClick={() => updateAppearance({ theme: "glass" })}>Switch to Glass</button></Banner>
        )}
        <div className="zs-bg-grid" role="radiogroup" aria-label="Background picture">
          {BACKGROUNDS.map((b) => (
            <button key={b.key} type="button" role="radio" aria-checked={look.background === b.key}
              className={`zs-bg ${look.background === b.key ? "on" : ""}`} onClick={() => updateAppearance({ background: b.key })}>
              <span className="zs-bg-thumb" style={b.src ? { backgroundImage: `url("${b.src}")` } : undefined} aria-hidden="true" />
              <span>{b.label}{b.key === DEFAULT_APPEARANCE.background ? " (default)" : ""}</span>
            </button>
          ))}
          {look.customUrl && (
            <button type="button" role="radio" aria-checked={look.background === "custom"}
              className={`zs-bg ${look.background === "custom" ? "on" : ""}`} onClick={() => updateAppearance({ background: "custom" })}>
              <span className="zs-bg-thumb" style={{ backgroundImage: `url("${look.customUrl}")` }} aria-hidden="true" />
              <span>Your picture</span>
            </button>
          )}
        </div>
        <div className="zs-bg-actions">
          <input ref={fileInput} type="file" accept="image/png,image/jpeg,image/webp" hidden
            onChange={(e) => { upload(e.target.files?.[0]); e.target.value = ""; }} />
          <button type="button" className="zs-btn" disabled={pic.busy} onClick={() => fileInput.current?.click()}>
            {pic.busy ? "Uploading…" : look.customUrl ? "Upload a different picture" : "Upload your own picture"}
          </button>
          {look.customUrl && <button type="button" className="zs-btn" disabled={pic.busy} onClick={removePicture}>Remove my picture</button>}
        </div>
        {pic.error && <Banner tone="error">{pic.error}</Banner>}
        <p className="zs-hint">PNG, JPEG or WebP. Large photos are made smaller automatically. Stored with your Zella account; anyone with its
          exact link could open it, so don't use a private photo.</p>
        <Field label={`Dim the picture: ${look.dim}%`} hint="More dimming makes text easier to read.">
          <input type="range" min="0" max="80" step="5" value={look.dim} onChange={(e) => updateAppearance({ dim: Number(e.target.value) })} />
        </Field>
      </Card>

      <Card title="Sidebar" sub={`Now: ${sidebarMode(look) === "compact" ? "a slim dock" : "the full list"}. The button at the bottom of the sidebar switches it too.`}>
        <div className="zs-look-grid" role="radiogroup" aria-label="Sidebar">
          {SIDEBAR.map((o) => (
            <button key={String(o.key)} type="button" role="radio" aria-checked={look.sidebar === o.key}
              className={`zs-look ${look.sidebar === o.key ? "on" : ""}`} onClick={() => updateAppearance({ sidebar: o.key })}>
              <strong>{o.label}</strong>
              <small>{o.text}</small>
            </button>
          ))}
        </div>
      </Card>

      <Card title="Start again">
        <div className="zs-bg-actions">
          <button type="button" className="zs-btn" onClick={() => { const old = look.customUrl; resetAppearance(); if (old) removeUploadedBackground(old).catch(() => {}); }}>
            Back to the default look
          </button>
          <small className="zs-hint">Classic theme, the default picture for Glass, automatic sidebar. Removes your uploaded picture.</small>
        </div>
      </Card>
    </>
  );
}
