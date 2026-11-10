// The signed-in platform admin's permissions, for the admin dashboard. Fails closed: nothing protected is offered
// until the server has said what this admin may do, and a failed lookup grants nothing. The server
// (owner-provision-business) checks the same permission on every action, so this only decides what is shown.
import { useCallback, useEffect, useRef, useState } from "react";

export const ACCESS = Object.freeze({ LOADING: "loading", AUTHORIZED: "authorized", UNAUTHORIZED: "unauthorized", FAILED: "failed" });

// The answer to me_admin, or the error it threw, as one access state.
export function accessFrom(result, error) {
  if (error) {
    // 401 / 403 from the admin function: signed out, MFA needed, or not (or no longer) a platform admin.
    const denied = error.status === 401 || error.status === 403 || ["NOT_PERMITTED", "MFA_REQUIRED"].includes(error.code);
    return { state: denied ? ACCESS.UNAUTHORIZED : ACCESS.FAILED, me: null, reason: denied ? error.code ?? "denied" : "lookup_failed" };
  }
  if (!result || typeof result !== "object" || !Array.isArray(result.permissions)) {
    return { state: ACCESS.FAILED, me: null, reason: "bad_answer" };
  }
  return { state: ACCESS.AUTHORIZED, me: { ...result, permissions: result.permissions.filter((p) => typeof p === "string") }, reason: null };
}

// May this admin use something needing `perm`? Only once authorized; `null` means "any authorized admin".
export function hasPermission(access, perm) {
  if (!access || access.state !== ACCESS.AUTHORIZED || !access.me) return false;
  return perm == null || access.me.permissions.includes(perm);
}

// Loads me_admin for the signed-in user and reloads it whenever the signed-in user changes, so one person's
// permissions are never shown to the next. A late answer for an earlier user (or an earlier attempt) is ignored.
export function useAdminAccess(load, auth) {
  const [access, setAccess] = useState({ state: ACCESS.LOADING, me: null, reason: null });
  const attempt = useRef(0);
  const userId = useRef(undefined);

  const fetchAccess = useCallback(async ({ quiet = false } = {}) => {
    const mine = ++attempt.current;
    if (!quiet) setAccess({ state: ACCESS.LOADING, me: null, reason: null });
    let next;
    try { next = accessFrom(await load(), null); } catch (error) { next = accessFrom(null, error); }
    if (mine !== attempt.current) return;
    // A background refresh that merely failed to reach the server keeps what was shown; a refusal always applies.
    if (quiet && next.state === ACCESS.FAILED) return;
    setAccess((prev) => (JSON.stringify(prev) === JSON.stringify(next) ? prev : next));
  }, [load]);

  useEffect(() => {
    let live = true;
    // The listener's first event (INITIAL_SESSION) usually names the user; this is only the fallback if it hasn't.
    auth.getUser().then(({ data }) => {
      if (!live || userId.current !== undefined) return;
      userId.current = data?.user?.id ?? null;
      fetchAccess();
    }).catch(() => { if (live && userId.current === undefined) { userId.current = null; fetchAccess(); } });
    const { data: listener } = auth.onAuthStateChange((event, session) => {
      const id = session?.user?.id ?? null;
      if (event === "SIGNED_OUT" || !id) {
        attempt.current++;
        userId.current = null;
        setAccess({ state: ACCESS.UNAUTHORIZED, me: null, reason: "signed_out" });
        return;
      }
      if (id !== userId.current) { userId.current = id; fetchAccess(); }
    });
    // Coming back to the tab picks up role changes made meanwhile.
    const onVisible = () => { if (document.visibilityState === "visible" && userId.current) fetchAccess({ quiet: true }); };
    document.addEventListener("visibilitychange", onVisible);
    const attempts = attempt;
    return () => {
      live = false;
      attempts.current++;
      listener?.subscription?.unsubscribe();
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [auth, fetchAccess]);

  return { access, retry: () => fetchAccess() };
}
