// Credential rotation requires coordinated secret storage and must be performed outside tests.
// This former rotation entrypoint refuses all targets, including when VAPI_KEY is set.
console.error("Refused: credential rotation is disabled in tests. Use a controlled rotation and secret-storage process.");
process.exit(1);
