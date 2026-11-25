import { supabase, supabaseConfig } from "../supabase";
import { keepaliveRequest } from "./phoneHelpers.js";

// Sends a quick change while the tab closes (deferChange's beacon): fetch with keepalive, to the same endpoint the
// Supabase client would use, with the signed in person's current access token. The token is kept up to date from
// the auth client; nothing here is logged. Best effort: the browser decides whether the request completes.
let token = null;
supabase.auth.getSession().then(({ data }) => { token = data?.session?.access_token ?? null; }, () => {});
supabase.auth.onAuthStateChange((_event, session) => { token = session?.access_token ?? null; });

// Whether a keepalive send could start now: the address and key, a current access token, and fetch. No side effects.
export function keepaliveReady() {
  return Boolean(supabaseConfig.url && supabaseConfig.key && token && typeof fetch === "function");
}

export function sendKeepalive(kind, name, body) {
  const req = keepaliveRequest({ ...supabaseConfig, token }, kind, name, body);
  if (!req || typeof fetch !== "function") return false;
  try { fetch(req.url, req.init).catch(() => {}); return true; } catch { return false; }
}
