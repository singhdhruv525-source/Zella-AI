// Runs one edge function locally for browser tests (see local-backend.mjs): `deno run -A run-function.ts <name> <port>`.
// Deno.serve is pointed at the given port; the function's own code is unchanged.
const [name, port] = Deno.args;
const serve = Deno.serve.bind(Deno);
Object.defineProperty(Deno, "serve", { value: (handler: Deno.ServeHandler) => serve({ port: Number(port), hostname: "127.0.0.1", onListen() {} }, handler) });
await import(new URL(`../../web/supabase/functions/${name}/index.ts`, import.meta.url).href);
console.log(`${name} on ${port}`);
