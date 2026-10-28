import { useSyncExternalStore } from "react";
import { supabase } from "./supabase";

// Personal look of Zella: theme, background picture, how much the picture is dimmed, whether the colours follow the
// picture, and whether the sidebar is a slim dock or the full list. Each person has their own, and the admin dashboard
// and the CRM each have their own (changing one never changes the other). It is kept on the person's sign-in account
// (auth user metadata, `zella_appearance: { admin, crm }`) so it follows them to any device, with a copy in this
// browser, tagged with who it belongs to, so the page opens in the right look before sign-in finishes; when someone
// else signs in on the same browser they get their own look (or the default), never the previous person's.
// Nothing here needs a database table.
//
// Applied as attributes on <html> (data-zella-theme, data-zella-sidebar), two CSS variables (--zella-wallpaper,
// --zella-wallpaper-dim) and, with Glass and "match colours to the picture", the picture's palette as the shared
// colour tokens. styles/glass.css does the rest. The Zella logo keeps its own colours.

export const BACKGROUNDS = [
  { key: "lounge", label: "Lounge at dusk", src: "/backgrounds/lounge-dusk.svg" },
  { key: "mountains", label: "Mountain morning", src: "/backgrounds/mountain-morning.svg" },
  { key: "aurora", label: "Aurora", src: "/backgrounds/aurora.svg" },
  { key: "plain", label: "Plain", src: null },
];

export const DEFAULT_APPEARANCE = { theme: "classic", background: "lounge", customUrl: null, dim: 35, sidebar: null, matchPicture: true, palette: null };
// Which app this page is: the CRM lives under /app (and /welcome); everything else is the admin dashboard.
export const APP_SCOPE = typeof window !== "undefined" && /^\/(app|welcome)(\/|$)/.test(window.location.pathname) ? "crm" : "admin";
const STORE_KEY = `zella.appearance.${APP_SCOPE}`;
// The colour tokens a picture's palette may set (everything else stays as glass.css has it).
const PALETTE_VARS = ["--zella-primary", "--zella-primary-hover", "--zella-primary-soft", "--zella-primary-border", "--zella-primary-ring",
  "--zella-on-primary", "--zella-nav-active", "--zella-card", "--zella-sidebar", "--zella-subtle", "--glass-solid", "--zella-glass-base",
  "--zella-text", "--zella-text-2", "--zella-text-secondary", "--zella-text-faint", "--zella-border", "--zella-border-strong"];
const COLOUR = /^hsla?\(\s*[0-9.]+(deg)?\s*,\s*[0-9.]+%\s*,\s*[0-9.]+%\s*(,\s*[0-9.]+\s*)?\)$/;
const listeners = new Set();
const local = readLocal();
let owner = local?.user ?? null;   // whose look this is (a user id), once sign-in is known
let current = normalise(local?.pref);

function normalisePalette(p) {
  if (!p || typeof p !== "object" || typeof p.for !== "string") return null;
  // a picture with almost no colour: remembered, so it isn't measured again, and the standard colours stay
  if (p.none === true) return { for: p.for.slice(0, 500), none: true, vars: null, swatches: [] };
  if (!p.vars || typeof p.vars !== "object") return null;
  const vars = {};
  for (const k of PALETTE_VARS) if (typeof p.vars[k] === "string" && COLOUR.test(p.vars[k])) vars[k] = p.vars[k];
  if (Object.keys(vars).length !== PALETTE_VARS.length) return null;
  const swatches = Array.isArray(p.swatches) ? p.swatches.filter((s) => typeof s === "string" && COLOUR.test(s)).slice(0, 6) : [];
  return { for: p.for.slice(0, 500), vars, swatches };
}

function normalise(p) {
  const v = { ...DEFAULT_APPEARANCE, ...(p && typeof p === "object" ? p : {}) };
  if (!["classic", "glass"].includes(v.theme)) v.theme = DEFAULT_APPEARANCE.theme;
  if (v.background !== "custom" && !BACKGROUNDS.some((b) => b.key === v.background)) v.background = DEFAULT_APPEARANCE.background;
  // only a picture uploaded to Zella's own storage is used as a background
  if (typeof v.customUrl !== "string" || !/^https:\/\/[^/]+\.supabase\.co\/storage\/v1\/object\/public\/brand-assets\/user\//.test(v.customUrl)) v.customUrl = null;
  if (v.background === "custom" && !v.customUrl) v.background = DEFAULT_APPEARANCE.background;
  v.dim = Math.min(80, Math.max(0, Math.round(Number(v.dim) || 0)));
  if (!["compact", "full", null].includes(v.sidebar)) v.sidebar = null;
  return { theme: v.theme, background: v.background, customUrl: v.customUrl, dim: v.dim, sidebar: v.sidebar,
    matchPicture: v.matchPicture !== false, palette: normalisePalette(v.palette) };
}

function readLocal() {
  try {
    window.localStorage.removeItem("zella.appearance");   // the first version's copy, shared by both apps and every person
    const v = JSON.parse(window.localStorage.getItem(STORE_KEY) ?? "null");
    return v && typeof v === "object" && "pref" in v ? v : null;
  } catch { return null; }
}
function writeLocal(p) {
  try { window.localStorage.setItem(STORE_KEY, JSON.stringify({ user: owner, pref: p })); } catch { /* private window: the account copy still works */ }
}

// This app's part of what the account holds. The first version kept one look for both apps: it is the starting point
// for each until the person changes that app's look.
function scopedFromAccount(saved) {
  if (!saved || typeof saved !== "object") return null;
  if ("admin" in saved || "crm" in saved) return saved[APP_SCOPE] ?? null;
  return "theme" in saved ? saved : null;
}

// The sidebar follows the theme unless the person chose: a dock with Glass, the full list with Classic.
export const sidebarMode = (p) => p.sidebar ?? (p.theme === "glass" ? "compact" : "full");

export function wallpaperUrl(p) {
  if (p.background === "custom") return p.customUrl;
  return BACKGROUNDS.find((b) => b.key === p.background)?.src ?? null;
}

// The palette in use right now: Glass, a picture, colours set to follow it, and a palette made from that picture.
export function activePalette(p) {
  const url = wallpaperUrl(p);
  return p.theme === "glass" && p.matchPicture && url && p.palette?.for === url && p.palette.vars ? p.palette : null;
}

function apply(p) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  root.dataset.zellaTheme = p.theme;
  root.dataset.zellaSidebar = sidebarMode(p);
  const url = wallpaperUrl(p);
  root.style.setProperty("--zella-wallpaper", url ? `url("${url.replace(/"/g, "%22")}")` : "none");
  root.style.setProperty("--zella-wallpaper-dim", String(p.dim / 100));
  // the picture's colours, as a rule scoped like the rest of the Glass theme (only inside the signed-in apps)
  const pal = activePalette(p);
  let tag = document.getElementById("zella-palette");
  if (!tag) { tag = document.createElement("style"); tag.id = "zella-palette"; document.head.appendChild(tag); }
  tag.textContent = pal
    ? `html[data-zella-theme="glass"]:has(.ba-root, .owner-app) {\n${PALETTE_VARS.map((k) => `  ${k}: ${pal.vars[k]};`).join("\n")}\n}`
    : "";
  root.dataset.zellaPalette = pal ? "picture" : "standard";
}

function set(next, { save = true } = {}) {
  current = normalise(next);
  writeLocal(current);
  apply(current);
  listeners.forEach((l) => l());
  if (save) saveToAccount(current);
  ensurePalette();
}

let saveTimer = null;
// The account keeps the choices only. The palette is worked out again on each device (it is kept in this browser),
// because everything in the account copy travels inside the sign-in token with every request.
function saveToAccount(full) {
  const p = { ...full };
  delete p.palette;
  clearTimeout(saveTimer);
  // a slider sends many changes: only the last one is saved
  saveTimer = setTimeout(async () => {
    const { data } = await supabase.auth.getSession();
    const user = data.session?.user;
    if (!user || user.id !== owner) return;   // only ever the signed-in person's own look
    const saved = user.user_metadata?.zella_appearance;
    const strip = (v) => { const c = { ...v }; delete c.palette; return c; };
    // the other app's look is written back unchanged (from the first version's single look if that is all there is)
    const both = saved && ("admin" in saved || "crm" in saved) ? { ...saved }
      : saved && "theme" in saved ? { admin: strip(saved), crm: strip(saved) } : {};
    both[APP_SCOPE] = p;
    const { error } = await supabase.auth.updateUser({ data: { zella_appearance: both } });
    if (error) console.warn("Appearance not saved to the account:", error.message);
  }, 600);
}

// Works out the palette of the picture in use when there isn't one yet (once per picture; it is then saved).
let working = null;
function ensurePalette() {
  const p = current;
  const url = wallpaperUrl(p);
  if (p.theme !== "glass" || !p.matchPicture || !url || p.palette?.for === url || working === url) return;
  working = url;
  pictureColours(url).then((palette) => {
    working = null;
    // still the same picture, and the person didn't switch the colours off meanwhile
    if (wallpaperUrl(current) === url && current.matchPicture) set({ ...current, palette: palette ?? { for: url, none: true } });
  }).catch(() => { working = null; });
}

export function getAppearance() { return current; }
export function updateAppearance(patch) { set({ ...current, ...patch }); }
export function resetAppearance() { set({ ...DEFAULT_APPEARANCE }); }

export function useAppearance() {
  return useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l); }, () => current, () => current);
}

// Called once at start-up: the browser's copy first, then the signed-in person's own look from their account.
export function startAppearance() {
  apply(current);
  ensurePalette();
  supabase.auth.onAuthStateChange((event, session) => {
    if (event === "SIGNED_OUT") { owner = null; set({ ...DEFAULT_APPEARANCE }, { save: false }); return; }
    const user = session?.user;
    if (!user) return;
    const mine = scopedFromAccount(user.user_metadata?.zella_appearance);
    if (user.id !== owner) {
      // someone else (or the first time this browser learns who it is): their own look, or the default
      owner = user.id;
      set(mine ?? { ...DEFAULT_APPEARANCE }, { save: false });
      return;
    }
    // the same person, maybe changed on another device: the account's choices, with this browser's palette
    const next = mine && normalise({ ...mine, palette: current.palette });
    if (next && JSON.stringify(next) !== JSON.stringify(current)) set(next, { save: false });
  });
}

// A picture the other app (or the first version's shared look) still shows is never deleted.
async function pictureUsedElsewhere(url) {
  const { data } = await supabase.auth.getSession();
  const saved = data.session?.user?.user_metadata?.zella_appearance;
  if (!saved || typeof saved !== "object") return false;
  const other = "admin" in saved || "crm" in saved ? saved[APP_SCOPE === "crm" ? "admin" : "crm"] : saved;
  return other?.customUrl === url;
}

// ---------- The picture's palette ----------
// The picture is shrunk to 48 x 48 and its colours are sorted into 10-degree hue bands. The accent is the strongest
// band of clearly coloured pixels (vivid, neither near-black nor near-white); the base tint is the picture's overall
// hue. Lightness is fixed by role so text stays readable whatever the picture: the accent is light (it is used as
// text on the dark glass, with dark text on accent buttons), panels are dark and only lightly tinted.
// A picture with almost no colour (black and white) keeps the standard Zella colours.
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const r1 = (v) => Math.round(v * 10) / 10;
const hsl = (h, s, l, a) => (a === undefined ? `hsl(${r1(h)}, ${r1(s)}%, ${r1(l)}%)` : `hsla(${r1(h)}, ${r1(s)}%, ${r1(l)}%, ${a})`);

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min, s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  const h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h * 60, s, l];
}

export function paletteFromPixels(data) {
  const bands = Array.from({ length: 36 }, () => ({ w: 0, x: 0, y: 0, s: 0 }));
  let tx = 0, ty = 0, tw = 0, satSum = 0, n = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] < 128) continue;
    const [h, s, l] = rgbToHsl(data[i], data[i + 1], data[i + 2]);
    const rad = (h * Math.PI) / 180, mid = 1 - Math.abs(2 * l - 1);
    const wb = s * mid;                      // overall tint: every pixel, by how coloured it looks
    tx += Math.cos(rad) * wb; ty += Math.sin(rad) * wb; tw += wb; satSum += s * mid; n++;
    if (s > 0.22 && l > 0.18 && l < 0.85) {   // accent candidates: clearly coloured pixels only
      const b = bands[Math.floor(h / 10) % 36], w = s * s * mid;
      b.w += w; b.x += Math.cos(rad) * w; b.y += Math.sin(rad) * w; b.s += s * w;
    }
  }
  if (!n || satSum / n < 0.04) return null;  // black and white picture: keep the standard colours
  let best = -1, bestW = 0;
  for (let i = 0; i < 36; i++) {
    const w = bands[i].w + 0.5 * (bands[(i + 35) % 36].w + bands[(i + 1) % 36].w);
    if (w > bestW) { bestW = w; best = i; }
  }
  const baseH = (((Math.atan2(ty, tx) * 180) / Math.PI) + 360) % 360;
  const baseS = clamp(((tw / n) * 100) * 1.4, 8, 26);
  let accH = baseH, accS = 55;
  if (best >= 0 && bestW > 0) {
    const ids = [(best + 35) % 36, best, (best + 1) % 36];
    const x = ids.reduce((v, i) => v + bands[i].x, 0), y = ids.reduce((v, i) => v + bands[i].y, 0), w = ids.reduce((v, i) => v + bands[i].w, 0);
    accH = (((Math.atan2(y, x) * 180) / Math.PI) + 360) % 360;
    accS = clamp((ids.reduce((v, i) => v + bands[i].s, 0) / w) * 100, 45, 82);
  }
  // blues and purples look darker at the same lightness: lift them a little so they still read as text on dark glass
  const accL = accH > 200 && accH < 290 ? 76 : 72;
  const vars = {
    "--zella-primary": hsl(accH, accS, accL),
    "--zella-primary-hover": hsl(accH, accS, accL + 8),
    "--zella-primary-soft": hsl(accH, accS, 65, 0.18),
    "--zella-primary-border": hsl(accH, accS, 70, 0.45),
    "--zella-primary-ring": hsl(accH, accS, 70, 0.3),
    "--zella-on-primary": hsl(accH, 45, 11),
    "--zella-nav-active": hsl(accH, accS, 70, 0.16),
    "--zella-card": hsl(baseH, baseS, 13, 0.52),
    "--zella-sidebar": hsl(baseH, baseS, 10, 0.46),
    "--zella-subtle": hsl(baseH, baseS, 85, 0.07),
    "--glass-solid": hsl(baseH, baseS * 0.8, 11, 0.94),
    "--zella-glass-base": hsl(baseH, baseS, 8),
    "--zella-text": hsl(baseH, 18, 96),
    "--zella-text-2": hsl(baseH, 14, 88),
    "--zella-text-secondary": hsl(baseH, 12, 76),
    "--zella-text-faint": hsl(baseH, 10, 60),
    "--zella-border": hsl(baseH, baseS, 85, 0.14),
    "--zella-border-strong": hsl(baseH, baseS, 85, 0.25),
  };
  return { vars, swatches: [vars["--zella-primary"], hsl(accH, accS, 55), hsl(baseH, baseS + 10, 30), hsl(baseH, baseS, 13), vars["--zella-text"]] };
}

async function pictureColours(url) {
  const img = new Image();
  img.crossOrigin = "anonymous";   // pictures in Zella's storage allow this; without it the pixels can't be read
  img.decoding = "async";
  img.src = url;
  await img.decode();
  const canvas = document.createElement("canvas");
  canvas.width = 48; canvas.height = 48;
  const g = canvas.getContext("2d", { willReadFrequently: true });
  g.drawImage(img, 0, 0, 48, 48);
  const result = paletteFromPixels(g.getImageData(0, 0, 48, 48).data);
  return result ? { for: url, ...result } : null;
}

// A picture the person chose, made small enough for storage (2 MB) and fast to load: at most 2400 px wide, WebP.
export async function prepareBackground(file) {
  if (!file || !/^image\/(png|jpeg|webp)$/.test(file.type)) throw new Error("Choose a PNG, JPEG or WebP picture.");
  if (file.size > 25 * 1024 * 1024) throw new Error("That picture is larger than 25 MB. Choose a smaller one.");
  const bitmap = await createImageBitmap(file).catch(() => { throw new Error("That picture couldn't be opened."); });
  const scale = Math.min(1, 2400 / bitmap.width, 1600 / bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close?.();
  for (const q of [0.85, 0.75, 0.6, 0.45]) {
    const blob = await new Promise((r) => canvas.toBlob(r, "image/webp", q));
    if (blob && blob.size <= 1.9 * 1024 * 1024) return new File([blob], "background.webp", { type: blob.type || "image/webp" });
  }
  throw new Error("That picture is still too large after shrinking it. Choose a simpler one.");
}

// Removes an earlier uploaded background from storage (best effort: an orphaned file is harmless).
export async function removeUploadedBackground(url) {
  const m = /\/storage\/v1\/object\/public\/brand-assets\/(user\/.+)$/.exec(url ?? "");
  if (!m || await pictureUsedElsewhere(url)) return;
  const { error } = await supabase.storage.from("brand-assets").remove([decodeURIComponent(m[1])]);
  if (error) console.warn("Old background picture not removed:", error.message);
}
