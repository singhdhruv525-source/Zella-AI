// Loads a Zella receptionist setup (made by zella_assistant_config) into ONE Vapi assistant, for testing.
// Usage: VAPI_KEY=... node tests/vapi/load-test-assistant.mjs <assistant id> [file]
// Changes only that assistant. No phone number is touched. The key is read from the environment and never printed.
import { readFileSync } from "node:fs";

const [assistantId, file = new URL("./test-saloon-assistant.json", import.meta.url)] = process.argv.slice(2);
const key = (process.env.VAPI_KEY ?? "").trim();
if (!/^[0-9a-f-]{36}$/.test(assistantId ?? "")) { console.log("Give the test assistant's id (the long code in its address)."); process.exit(1); }
if (!key) { console.log("No Vapi key given."); process.exit(1); }

const config = JSON.parse(readFileSync(file, "utf8"));
const res = await fetch(`https://api.vapi.ai/assistant/${assistantId}`, {
  method: "PATCH",
  headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
  body: JSON.stringify(config),
});
const body = await res.json().catch(() => ({}));
if (res.ok) console.log(`Loaded "${body.name}" into assistant ${body.id}. Voice: ${body.voice?.voiceId}. Tools: ${body.model?.tools?.length ?? 0}.`);
else console.log(`Vapi said ${res.status}: ${JSON.stringify(body.message ?? body)}`);
