// Loads a Zella receptionist setup (made by zella_assistant_config) into ONE Vapi assistant, for testing.
// Usage: VAPI_KEY=... [ZELLA_VAPI_TOKEN=...] node tests/vapi/load-test-assistant.mjs <assistant id> [file]
// Changes only that assistant. No phone number is touched. Keys are read from the environment and never printed.
// ZELLA_VAPI_TOKEN (the vault secret zella_vapi_bearer_token): sent as "Authorization: Bearer ..." on the assistant's
// server and every tool's server. Vapi did not apply the linked credential on real calls, but it always sends a
// server's own headers.
import { readFileSync } from "node:fs";

const [assistantId, file = new URL("./test-saloon-assistant.json", import.meta.url)] = process.argv.slice(2);
const key = (process.env.VAPI_KEY ?? "").trim();
const token = (process.env.ZELLA_VAPI_TOKEN ?? "").trim();
if (!/^[0-9a-f-]{36}$/.test(assistantId ?? "")) { console.log("Give the test assistant's id (the long code in its address)."); process.exit(1); }
if (!key) { console.log("No Vapi key given."); process.exit(1); }
if (token && !/^[0-9a-f]{64}$/.test(token)) { console.log("That Zella token doesn't look right (64 letters and numbers)."); process.exit(1); }

const config = JSON.parse(readFileSync(file, "utf8"));
if (token) {
  const withHeader = (server) => server && { ...server, headers: { ...(server.headers ?? {}), Authorization: `Bearer ${token}` } };
  config.server = withHeader(config.server);
  for (const tool of config.model?.tools ?? []) if (tool.server) tool.server = withHeader(tool.server);
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
