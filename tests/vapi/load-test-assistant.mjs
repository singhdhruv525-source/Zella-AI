// Loads a Zella receptionist setup (made by zella_assistant_config) into ONE Vapi assistant, for testing.
// Usage: VAPI_KEY=... [ZELLA_VAPI_TOKEN=...] node tests/vapi/load-test-assistant.mjs <assistant id> [file]
// Changes only that assistant. No phone number is touched. Keys are read from the environment and never printed.
// ZELLA_VAPI_TOKEN (the vault secret zella_vapi_bearer_token): sent as "Authorization: Bearer ..." on the assistant's
// server and every tool's server, in place of the linked credential (Vapi did not apply the credential on real calls,
// but it sends a server's own headers).
import { readFileSync } from "node:fs";

const [assistantId, file = new URL("./test-saloon-assistant.json", import.meta.url)] = process.argv.slice(2);
const key = (process.env.VAPI_KEY ?? "").trim();
const token = (process.env.ZELLA_VAPI_TOKEN ?? "").trim();
if (!/^[0-9a-f-]{36}$/.test(assistantId ?? "")) { console.log("Give the test assistant's id (the long code in its address)."); process.exit(1); }
if (!key) { console.log("No Vapi key given."); process.exit(1); }
if (token && !/^[0-9a-f]{64}$/.test(token)) { console.log("That Zella token doesn't look right (64 letters and numbers)."); process.exit(1); }

const config = JSON.parse(readFileSync(file, "utf8"));
if (token) {
  // the token replaces the linked credential: with a credential present Vapi sent no header on the assistant's own
  // messages (call status, end-of-call report)
  const withHeader = (server) => {
    if (!server) return server;
    const { credentialId: _unused, ...rest } = server;
    return { ...rest, headers: { ...(server.headers ?? {}), Authorization: `Bearer ${token}` } };
  };
  config.server = withHeader(config.server);
  for (const tool of config.model?.tools ?? []) if (tool.server) tool.server = withHeader(tool.server);
}
// Verify the existing remote identity before changing it; the input fixture is not proof.
const targetUrl = `https://api.vapi.ai/assistant/${assistantId}`;
const current = await fetch(targetUrl, { headers: { Authorization: `Bearer ${key}` } });
const assistant = await current.json().catch(() => null);
// Dedicated test assistant documented in docs/PROJECT_STATE.md; do not infer safety from a partial name.
if (!current.ok || !assistant || assistant.name !== "test saloon receptionist") {
  console.error("Refused: the target assistant is not marked as a test assistant.");
  process.exit(1);
}
const res = await fetch(`https://api.vapi.ai/assistant/${assistantId}`, {
  method: "PATCH",
  headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
  body: JSON.stringify(config),
});
const body = await res.json().catch(() => ({}));
const headed = [body.server, ...(body.model?.tools ?? []).map((t) => t.server)].filter((s) => s?.headers?.Authorization || s?.headers?.authorization).length;
if (res.ok) console.log(`Loaded "${body.name}" into assistant ${body.id}. Voice: ${body.voice?.voiceId}. Tools: ${body.model?.tools?.length ?? 0}. With Zella token: ${headed}.`);
else console.log(`Vapi said ${res.status}: ${JSON.stringify(body.message ?? body)}`);
