// Runs one edge function locally for browser tests (see local-backend.mjs): `deno run -A run-function.ts <name> <port>`.
// Deno.serve is pointed at the given port; the function's own code is unchanged.
const [name, port] = Deno.args;
const serve = Deno.serve.bind(Deno);
let served = false;
const start = (handler: Deno.ServeHandler) => { served = true; return serve({ port: Number(port), hostname: "127.0.0.1", onListen() {} }, handler); };
Object.defineProperty(Deno, "serve", { value: start });
const mod = await import(new URL(`../../web/supabase/functions/${name}/index.ts`, import.meta.url).href);
// functions that export their handler (and serve only when run directly, so tests can import them)
if (!served && typeof mod.handle === "function") start(mod.handle);
console.log(`${name} on ${port}`);
