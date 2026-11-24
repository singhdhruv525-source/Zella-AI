// The shared rate limit for edge functions (SEC-12): the database counter zella_rate_limit (sql/zella_staff_ops.sql),
// server only, so it is called with the server key. Each limit is a key, a maximum and a window in seconds; every
// limit is counted in order and the first one over its maximum stops the request. A counter that can't be checked
// answers "unavailable", and the caller refuses (fails closed, like reschedule-appointment, security audit M10).
export const TOO_MANY_ATTEMPTS = "Too many attempts. Wait a minute and try again.";

export type Limit = readonly [key: string, max: number, windowSeconds: number];
export type LimitAnswer = "ok" | "limited" | "unavailable";

export async function checkLimits(base: string, serverKey: string, limits: readonly Limit[]): Promise<LimitAnswer> {
  for (const [key, max, windowSeconds] of limits) {
    let allowed: unknown = null;
    try {
      const r = await fetch(`${base}/rest/v1/rpc/zella_rate_limit`, {
        method: "POST",
        headers: { "Content-Type": "application/json", apikey: serverKey, Authorization: `Bearer ${serverKey}` },
        body: JSON.stringify({ p_key: key, p_max: max, p_window_seconds: windowSeconds }),
        signal: AbortSignal.timeout(10_000),   // BE-3
      });
      allowed = r.ok ? await r.json() : null;
    } catch (error) {
      console.error("rate limit check failed", error instanceof Error ? error.name : "unknown");
      return "unavailable";
    }
    if (typeof allowed !== "boolean") return "unavailable";
    if (!allowed) return "limited";
  }
  return "ok";
}
