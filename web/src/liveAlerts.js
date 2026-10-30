// How new notifications announce themselves: a pop-up in the corner, a soft chime and a desktop notification when Zella
// is in a background tab. All on by default. Browsers only allow sound and the desktop-notification question after the
// person clicks something, so both are unlocked on the first click (unlockAlerts). A stored per-browser choice is
// still honoured if one exists; the sound is switched in Settings > Appearance > Notification sound. Storage can be unavailable (private windows): defaults are used.

const KEY = "zella.alerts.device";
export const DEVICE_DEFAULTS = { popups: true, sound: true, desktop: true };

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

// On the first click anywhere: wake the audio (so later chimes can play) and, once, ask whether Zella may show
// desktop notifications. Nothing is asked again after the person answers.
let unlocked = false;
export function unlockAlerts() {
  if (unlocked || typeof document === "undefined") return;
  unlocked = true;
  const once = () => {
    document.removeEventListener("pointerdown", once, true);
    document.removeEventListener("keydown", once, true);
    try { audio = audio || new (window.AudioContext || window.webkitAudioContext)(); if (audio.state === "suspended") audio.resume(); } catch { /* no sound */ }
    if (deviceAlerts().desktop && desktopSupported() && Notification.permission === "default") {
      try { Notification.requestPermission().catch(() => {}); } catch { /* older browsers */ }
    }
  };
  document.addEventListener("pointerdown", once, true);
  document.addEventListener("keydown", once, true);
}

export function desktopSupported() {
  return typeof window !== "undefined" && "Notification" in window;
}
// Only when the tab is in the background; clicking it brings Zella forward.
export function desktopAlert(title, body, onClick) {
  if (!desktopSupported() || Notification.permission !== "granted" || !document.hidden) return;
  try {
    const n = new Notification(title, { body: body || "", tag: "zella-" + title.slice(0, 40), silent: true });
    n.onclick = () => { window.focus(); onClick?.(); n.close(); };
  } catch { /* some browsers only allow this from a service worker */ }
}

// "(3) Zella Voice": the unread count in the browser tab.
let baseTitle = null;
export function tabCount(count) {
  if (typeof document === "undefined") return;
  if (baseTitle === null) baseTitle = document.title.replace(/^\(\d+\+?\)\s*/, "");
  document.title = count > 0 ? `(${count > 9 ? "9+" : count}) ${baseTitle}` : baseTitle;
}
