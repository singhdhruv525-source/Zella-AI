import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { endSessionsAfterChange, endsSessions, SESSIONS_NOT_ENDED } from "./access.ts";

const owner = { role: "zella_owner", is_active: true };
const support = { role: "support_admin", is_active: true };
const fake = (reply: { data: unknown; error: unknown }) => {
  const calls: unknown[] = [];
  const admin = { rpc: async (name: string, args: unknown) => { calls.push([name, args]); return reply; } } as unknown as SupabaseClient;
  return { admin, calls };
};

Deno.test("sessions end on removal and on a role change, never otherwise", () => {
  assertEquals(endsSessions(support, { ...support, is_active: false }), true);    // removed
  assertEquals(endsSessions(owner, support), true);                                // role changed
  assertEquals(endsSessions(support, support), false);                             // nothing changed
  assertEquals(endsSessions({ ...support, is_active: false }, support), false);    // reactivated: nothing to end
  assertEquals(endsSessions({ ...support, is_active: false }, { ...owner, is_active: false }), false); // inactive stays inactive
});

Deno.test("a removal or role change ends the target's sessions through the server only function", async () => {
  const { admin, calls } = fake({ data: 2, error: null });
  assertEquals(await endSessionsAfterChange(admin, "target", owner, support), { sessionsEnded: 2 });
  assertEquals(calls, [["zella_end_user_sessions", { p_user_id: "target" }]]);
});

Deno.test("no change, no call", async () => {
  const { admin, calls } = fake({ data: 2, error: null });
  assertEquals(await endSessionsAfterChange(admin, "target", support, support), { sessionsEnded: 0 });
  assertEquals(calls, []);
});

Deno.test("a database failure keeps the change and says the devices weren't signed out", async () => {
  for (const reply of [{ data: null, error: { message: "function does not exist" } }, { data: "x", error: null }]) {
    const { admin } = fake(reply);
    assertEquals(await endSessionsAfterChange(admin, "target", support, { ...support, is_active: false }), { sessionsEnded: null, sessionsWarning: SESSIONS_NOT_ENDED });
  }
});
