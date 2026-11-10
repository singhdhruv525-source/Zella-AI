// Switches Zella's Vapi credential from HMAC signing to a Bearer token (Vapi sent no HMAC signature on real calls).
// Usage: VAPI_KEY=... node tests/vapi/switch-credential-to-bearer.mjs <credential id>
// Makes a new random token, puts it in the Vapi credential (same id, so every tool that uses it keeps working), then
// prints the one line to run in the Supabase SQL editor so Zella knows the same token. The token is shown only on
// this screen: don't send it to anyone. Zella keeps checking HMAC until the vapi_auth_mode setting is switched to bearer.
import { randomBytes } from "node:crypto";

const [credentialId] = process.argv.slice(2);
const key = (process.env.VAPI_KEY ?? "").trim();
if (!/^[0-9a-f-]{36}$/.test(credentialId ?? "")) { console.log("Give the credential id."); process.exit(1); }
if (!key) { console.log("No Vapi key given."); process.exit(1); }

const token = randomBytes(32).toString("hex");
const res = await fetch(`https://api.vapi.ai/credential/${credentialId}`, {
  method: "PATCH",
  headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
  body: JSON.stringify({ authenticationPlan: { type: "bearer", token, headerName: "Authorization", bearerPrefixEnabled: true } }),
});
const body = await res.json().catch(() => ({}));
if (!res.ok) { console.log(`Vapi said ${res.status}: ${JSON.stringify(body.message ?? body)}`); process.exit(1); }
console.log(`Vapi credential ${body.id} now uses: ${body.authenticationPlan?.type}`);
console.log("\nRun this ONE line in Supabase > SQL Editor (don't send it to anyone):\n");
console.log(`select vault.create_secret('${token}', 'zella_vapi_bearer_token', 'Vapi Bearer token');`);
