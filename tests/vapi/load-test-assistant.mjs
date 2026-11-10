// Loading assistant configuration through this test entrypoint is disabled.
// A remote name check cannot prove that an assistant is safe to modify.
console.error("Refused: assistant updates are disabled in tests. Use a controlled assistant deployment process.");
process.exit(1);
