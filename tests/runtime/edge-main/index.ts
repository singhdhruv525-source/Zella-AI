// Local router for the Supabase edge runtime: /<function>/... is served by a user worker for that function folder,
// the way the hosted platform does (one isolate per function, its own memory and CPU limits).
const ENV = ["SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEY", "ZELLA_SERVER_SECRET_KEY", "ZELLA_APP_URL", "ZELLA_LINK_SECRET", "STRIPE_WEBHOOK_SECRET", "ZELLA_VOICE_BUDGET_MS", "ZELLA_VOICE_RPC_MS",
  "GOOGLE_CALENDAR_CLIENT_ID", "GOOGLE_CALENDAR_CLIENT_SECRET", "MICROSOFT_CALENDAR_CLIENT_ID", "MICROSOFT_CALENDAR_CLIENT_SECRET", "CALENDAR_REDIRECT_URL"];
Deno.serve(async (req: Request) => {
  const name = new URL(req.url).pathname.split("/")[1];
  if (!/^[a-z0-9-]+$/.test(name ?? "")) return new Response(JSON.stringify({ error: "no function" }), { status: 404 });
  try {
    // @ts-ignore EdgeRuntime is provided by the runtime
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: `/home/deno/functions/${name}`, memoryLimitMb: 150, workerTimeoutMs: 60_000, noModuleCache: false,
      envVars: ENV.filter((k) => Deno.env.get(k)).map((k) => [k, Deno.env.get(k)!]), forceCreate: false, netAccessDisabled: false,
      cpuTimeSoftLimitMs: 2000, cpuTimeHardLimitMs: 4000,
    });
    return await worker.fetch(req);
  } catch (e) {
    console.error(`worker ${name}:`, e);
    return new Response(JSON.stringify({ error: "worker_failed", detail: String(e).slice(0, 300) }), { status: 500 });
  }
});
