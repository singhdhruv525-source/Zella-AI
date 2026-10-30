// Shows how ONE Vapi assistant reaches Zella: its server URL and credential, and each tool's. Read-only.
// Usage: VAPI_KEY=... node tests/vapi/check-test-assistant.mjs <assistant id>
// Prints no secrets: only URLs, credential ids and names.

const [assistantId] = process.argv.slice(2);
const key = (process.env.VAPI_KEY ?? "").trim();
if (!/^[0-9a-f-]{36}$/.test(assistantId ?? "")) { console.log("Give the test assistant's id (the long code in its address)."); process.exit(1); }
if (!key) { console.log("No Vapi key given."); process.exit(1); }

const res = await fetch(`https://api.vapi.ai/assistant/${assistantId}`, { headers: { Authorization: `Bearer ${key}` } });
const a = await res.json().catch(() => ({}));
if (!res.ok) { console.log(`Vapi said ${res.status}: ${JSON.stringify(a.message ?? a)}`); process.exit(1); }

const where = (s) => s ? `${s.url ?? "(no url)"} | credential: ${s.credentialId ?? "NONE"}` : "(none)";
console.log(`Assistant "${a.name}"`);
console.log(`  server: ${where(a.server)}`);
console.log(`  serverUrl (old field): ${a.serverUrl ?? "(none)"}`);
console.log(`  credentialIds: ${JSON.stringify(a.credentialIds ?? null)}`);
console.log(`  serverMessages: ${JSON.stringify(a.serverMessages ?? null)}`);
const tools = a.model?.tools ?? [];
console.log(`  inline tools: ${tools.length}; toolIds: ${JSON.stringify(a.model?.toolIds ?? null)}`);
for (const t of tools) console.log(`    ${t.function?.name ?? t.type}: ${where(t.server)}`);
