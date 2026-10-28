// How new notifications announce themselves on this device: a pop-up in the corner (on by default), a soft sound
// and a desktop notification (both off until the person switches them on). Kept in this browser only; these are
// per-device conveniences, not account settings. Storage can be unavailable (private windows): defaults are used.

const KEY = "zella.alerts.device";
export const DEVICE_DEFAULTS = { popups: true, sound: false, desktop: false };

export function deviceAlerts() {
  try { return { ...DEVICE_DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) || "{}") }; } catch { return { ...DEVICE_DEFAULTS }; }
}
export function setDeviceAlerts(next) {
  const value = { ...deviceAlerts(), ...next };
  try { localStorage.setItem(KEY, JSON.stringify(value)); } catch { /* not saved; still applies this session */ }
  return value;
}

// A short chime made in the browser (no sound file). Urgent: two firm notes. Celebration: a little rising run.
let audio = null;
export function chime(tone = "info") {
  try {
    audio = audio || new (window.AudioContext || window.webkitAudioContext)();
    const notes = tone === "urgent" ? [[880, 0], [880, 0.22]] : tone === "celebrate" ? [[523, 0], [659, 0.1], [784, 0.2], [1047, 0.3]] : [[660, 0], [880, 0.12]];
    for (const [freq, at] of notes) {
      const osc = audio.createOscillator();
      const gain = audio.createGain();
      osc.type = "sine";
      osc.frequency.value = freq;
      const start = audio.currentTime + at;
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(tone === "urgent" ? 0.18 : 0.1, start + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.28);
      osc.connect(gain).connect(audio.destination);
      osc.start(start);
      osc.stop(start + 0.3);
    }
  } catch { /* sound is optional */ }
}

export function desktopSupported() {
  return typeof window !== "undefined" && "Notification" in window;
}
export async function askDesktopPermission() {
  if (!desktopSupported()) return "unsupported";
  if (Notification.permission !== "default") return Notification.permission;
  try { return await Notification.requestPermission(); } catch { return "denied"; }
}
// Only when the tab is in the background; clicking it brings Zella forward.
export function desktopAlert(title, body, onClick) {
  if (!desktopSupported() || Notification.permission !== "granted" || !document.hidden) return;
  try {
    const n = new Notification(title, { body: body || "", tag: "zella-" + title.slice(0, 40), silent: true });
    n.onclick = () => { window.focus(); onClick?.(); n.close(); };
  } catch { /* some browsers only allow this from a service worker */ }
}

// "(3) Zella AI": the unread count in the browser tab.
let baseTitle = null;
export function tabCount(count) {
  if (typeof document === "undefined") return;
  if (baseTitle === null) baseTitle = document.title.replace(/^\(\d+\+?\)\s*/, "");
  document.title = count > 0 ? `(${count > 9 ? "9+" : count}) ${baseTitle}` : baseTitle;
}
