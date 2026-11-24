// The play button's state on the voice cards (pure, voicePlayback.test.mjs). One sample plays at a time: pressing
// another voice stops the first; pressing the same one again stops it. A voice with no sample yet keeps a quiet note.
//   status: "idle" | "loading" | "playing"; voiceId: the voice it is about (null when idle); notes: { [voiceId]: word }

export const initialPlayback = { status: "idle", voiceId: null, notes: {} };

const NOTE = { not_available: "Sample not available yet", try_again: "Sample didn't load. Try again." };
export const noteText = (kind) => NOTE[kind] ?? NOTE.try_again;

export function playbackReducer(state, action) {
  const s = state ?? initialPlayback;
  const id = action?.voiceId ?? null;
  switch (action?.type) {
    case "press": {
      if (s.voiceId === id && s.status !== "idle") return { ...s, status: "idle", voiceId: null };   // pressed again: stop
      const notes = { ...s.notes }; delete notes[id];
      return { status: "loading", voiceId: id, notes };
    }
    case "playing": return s.voiceId === id && s.status === "loading" ? { ...s, status: "playing" } : s;
    case "ended": return s.voiceId === id ? { ...s, status: "idle", voiceId: null } : s;   // this sample finished
    case "stop": return { ...s, status: "idle", voiceId: null };                             // stop whatever plays
    case "failed": {
      if (s.voiceId !== id) return s;   // a late answer for a voice no longer asked for
      return { status: "idle", voiceId: null, notes: { ...s.notes, [id]: action.kind === "not_available" ? "not_available" : "try_again" } };
    }
    default: return s;
  }
}

// What one card's button shows: "play", "loading" or "stop", its label, and its note (if any)
export function buttonFor(state, voiceId, name) {
  const mine = state.voiceId === voiceId && state.status !== "idle";
  const mode = mine ? (state.status === "loading" ? "loading" : "stop") : "play";
  const label = mode === "play" ? `Play sample of ${name}` : mode === "loading" ? `Loading sample of ${name}` : `Stop sample of ${name}`;
  const note = state.notes[voiceId] ? noteText(state.notes[voiceId]) : null;
  return { mode, label, note };
}

// The function's answer as an action: a link to play, or why there isn't one
export function answerToAction(voiceId, data, error) {
  if (!error && data?.ok && typeof data.url === "string") return { type: "url", voiceId, url: data.url };
  return { type: "failed", voiceId, kind: !error && data?.state === "not_available" ? "not_available" : "try_again" };
}
