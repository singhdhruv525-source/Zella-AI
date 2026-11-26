import { PLACEHOLDER_BUSINESS_ID, previewActive, supabase, supabaseConfig } from "../supabase";
import { createKeepaliveSender } from "./phoneHelpers.js";

// Sends a quick change while the tab closes (deferChange's beacon): fetch with keepalive, to the same endpoint the
// Supabase client would use, with the signed in person's current access token. The token is kept up to date from
// the auth client; nothing here is logged. Best effort: the browser decides whether the request completes. The
// development preview and its placeholder business never send anything (phoneHelpers createKeepaliveSender).
let token = null;
supabase.auth.getSession().then(({ data }) => { token = data?.session?.access_token ?? null; }, () => {});
supabase.auth.onAuthStateChange((_event, session) => { token = session?.access_token ?? null; });

const sender = createKeepaliveSender({
  getConfig: () => supabaseConfig,
  getToken: () => token,
  isPreview: previewActive,
  placeholderId: PLACEHOLDER_BUSINESS_ID,
  fetchImpl: () => (typeof fetch === "function" ? fetch : null),
});

// Whether a keepalive send could start now (no side effects).
export const keepaliveReady = () => sender.ready();
export const sendKeepalive = (kind, name, body) => sender.send(kind, name, body);
