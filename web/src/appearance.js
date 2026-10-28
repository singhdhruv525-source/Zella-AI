import { useSyncExternalStore } from "react";
import { supabase } from "./supabase";

// Personal look of Zella (both the admin and the CRM): theme, background picture, how much the picture is dimmed,
// and whether the sidebar is a slim dock or the full list. It belongs to the person, not the business, so it is kept
// on their own sign-in account (auth user metadata, `zella_appearance`) and follows them to any device, with a copy
// in this browser so the page opens in the right look before sign-in finishes. Nothing here needs a database table.
//
// Applied as attributes on <html> (data-zella-theme, data-zella-sidebar) and two CSS variables (--zella-wallpaper,
// --zella-wallpaper-dim); styles/glass.css does the rest.

export const BACKGROUNDS = [
  { key: "lounge", label: "Lounge at dusk", src: "/backgrounds/lounge-dusk.svg" },
  { key: "mountains", label: "Mountain morning", src: "/backgrounds/mountain-morning.svg" },
  { key: "aurora", label: "Aurora", src: "/backgrounds/aurora.svg" },
  { key: "plain", label: "Plain", src: null },
];

export const DEFAULT_APPEARANCE = { theme: "classic", background: "lounge", customUrl: null, dim: 35, sidebar: null };
const STORE_KEY = "zella.appearance";
const listeners = new Set();
let current = normalise(readLocal());

function normalise(p) {
  const v = { ...DEFAULT_APPEARANCE, ...(p && typeof p === "object" ? p : {}) };
  if (!["classic", "glass"].includes(v.theme)) v.theme = DEFAULT_APPEARANCE.theme;
  if (v.background !== "custom" && !BACKGROUNDS.some((b) => b.key === v.background)) v.background = DEFAULT_APPEARANCE.background;
  // only a picture uploaded to Zella's own storage is used as a background
  if (typeof v.customUrl !== "string" || !/^https:\/\/[^/]+\.supabase\.co\/storage\/v1\/object\/public\/brand-assets\/user\//.test(v.customUrl)) v.customUrl = null;
  if (v.background === "custom" && !v.customUrl) v.background = DEFAULT_APPEARANCE.background;
  v.dim = Math.min(80, Math.max(0, Math.round(Number(v.dim) || 0)));
  if (!["compact", "full", null].includes(v.sidebar)) v.sidebar = null;
  return { theme: v.theme, background: v.background, customUrl: v.customUrl, dim: v.dim, sidebar: v.sidebar };
}

function readLocal() {
  try { return JSON.parse(window.localStorage.getItem(STORE_KEY) ?? "null"); } catch { return null; }
}
function writeLocal(p) {
  try { window.localStorage.setItem(STORE_KEY, JSON.stringify(p)); } catch { /* private window: the account copy still works */ }
}

// The sidebar follows the theme unless the person chose: a dock with Glass, the full list with Classic.
export const sidebarMode = (p) => p.sidebar ?? (p.theme === "glass" ? "compact" : "full");

export function wallpaperUrl(p) {
  if (p.background === "custom") return p.customUrl;
  return BACKGROUNDS.find((b) => b.key === p.background)?.src ?? null;
}

function apply(p) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  root.dataset.zellaTheme = p.theme;
  root.dataset.zellaSidebar = sidebarMode(p);
  const url = wallpaperUrl(p);
  root.style.setProperty("--zella-wallpaper", url ? `url("${url.replace(/"/g, "%22")}")` : "none");
  root.style.setProperty("--zella-wallpaper-dim", String(p.dim / 100));
}

function set(next, { save = true } = {}) {
  current = normalise(next);
  writeLocal(current);
  apply(current);
  listeners.forEach((l) => l());
  if (save) saveToAccount(current);
}

let saveTimer = null;
function saveToAccount(p) {
  clearTimeout(saveTimer);
  // a slider sends many changes: only the last one is saved
  saveTimer = setTimeout(async () => {
    const { data } = await supabase.auth.getSession();
    if (!data.session) return;
    const { error } = await supabase.auth.updateUser({ data: { zella_appearance: p } });
    if (error) console.warn("Appearance not saved to the account:", error.message);
  }, 600);
}

export function getAppearance() { return current; }
export function updateAppearance(patch) { set({ ...current, ...patch }); }
export function resetAppearance() { set({ ...DEFAULT_APPEARANCE }); }

export function useAppearance() {
  return useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l); }, () => current, () => current);
}

// Called once at start-up: the browser's copy first, then the account's copy whenever someone signs in.
export function startAppearance() {
  apply(current);
  supabase.auth.onAuthStateChange((event, session) => {
    const saved = session?.user?.user_metadata?.zella_appearance;
    if (saved && JSON.stringify(normalise(saved)) !== JSON.stringify(current)) set(saved, { save: false });
    if (event === "SIGNED_OUT") set({ ...DEFAULT_APPEARANCE }, { save: false });
  });
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
  if (m) await supabase.storage.from("brand-assets").remove([decodeURIComponent(m[1])]);
}
