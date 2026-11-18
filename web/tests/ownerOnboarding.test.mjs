// Owner onboarding journey: the step logic (src/onboarding/steps.js) against the answers the contract describes
// (docs/OWNER_ONBOARDING_CONTRACT.md, version 1), and the stand in api (src/onboarding/fakeApi.js) that follows the
// same rules: where an owner resumes, the progress bar, how server answers map to what the screens show, error words,
// and graceful degradation when a call isn't deployed yet.
//   cd web && node --test tests/ownerOnboarding.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import {
  ERROR_WORDS, SCREENS, STEP_KEYS, allowance, canLeave, canOpen, detailsDone, errorCode, errorWords, identityPassed,
  identityState, isNotReady, languageWords, money, nextOpenSection, nextStep, paymentPassed, paymentState, phoneWords,
  UNAVAILABLE, afterCompleteError, createAnswerQueue, previousStep, progressFor, resumeStep, rpcError, sectionRows, sectionState, securityPart, stateAfterResume, uploadKinds,
} from "../src/onboarding/steps.js";
import { createFakeApi } from "../src/onboarding/fakeApi.js";

const memory = () => { const m = new Map(); return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) }; };
const DASH = /[—–]|[A-Za-z]-[A-Za-z]/;
const steps = (current) => STEP_KEYS.map((key, i) => ({ key, state: i < STEP_KEYS.indexOf(current) ? "done" : key === current ? "current" : "locked" }));

test("the seven steps, in the contract's order", () => {
  assert.deepEqual(SCREENS.map((s) => s.key), ["welcome", "security", "details", "identity", "plan", "payment", "done"]);
  assert.equal(nextStep("welcome"), "security");
  assert.equal(nextStep("done"), "done");
  assert.equal(previousStep("plan"), "identity");
  assert.equal(previousStep("welcome"), null);
});

test("resume: the server's current step, which is also where Finish later comes back to", () => {
  assert.equal(resumeStep(null), "welcome");
  assert.equal(resumeStep({ current_step: "welcome" }), "welcome");
  assert.equal(resumeStep({ current_step: "details", paused_at: "2026-11-16T15:00:00Z" }), "details");
  assert.equal(resumeStep({ current_step: "payment" }), "payment");
  assert.equal(resumeStep({ current_step: "admin_panel" }), "welcome", "an unknown step is never trusted");
  assert.equal(resumeStep({ current_step: "done", completed_at: "2026-11-16T16:00:00Z" }), "done");
});

test("only done steps and the current one can be opened", () => {
  const s = { current_step: "identity", steps: steps("identity") };
  assert.equal(canOpen(s, "details"), true);
  assert.equal(canOpen(s, "identity"), true);
  assert.equal(canOpen(s, "plan"), false);
  assert.equal(canOpen({ current_step: "plan" }, "plan"), true);
  assert.equal(canOpen({ current_step: "plan" }, "payment"), false);
});

test("progress bar: step n of 7", () => {
  assert.deepEqual(progressFor("welcome"), { screen: 1, total: 7, label: "Welcome", percent: 0, text: "Step 1 of 7" });
  assert.equal(progressFor("security").label, "Password and two step sign in");
  assert.equal(progressFor("details").screen, 3);
  assert.equal(progressFor("payment").label, "Pay");
  assert.equal(progressFor("done").percent, 100);
  assert.equal(progressFor("nonsense").screen, 1);
});

test("password and two step sign in: the parts follow state.security", () => {
  assert.equal(securityPart(null), "password");
  assert.equal(securityPart({ password_set: true }), "authenticator");
  assert.equal(securityPart({ password_set: true, authenticator: true }), "code");
  assert.equal(securityPart({ password_set: true, authenticator: true, session_verified: true }), "ready");
  assert.equal(canLeave("security", { security: { password_set: true, authenticator: true } }), false);
});

test("check your details: only Looks right counts, Changed sections come back to the owner", () => {
  assert.equal(sectionState({ status: "looks_right" }).done, true);
  assert.equal(sectionState({ status: "change_requested" }).done, false);
  assert.equal(sectionState({ status: "change_requested" }).open, false, "waiting for Zella Voice, nothing for the owner to do");
  assert.equal(sectionState({ status: "change_requested" }).label, "Waiting for Zella Voice");
  assert.equal(sectionState({ status: "updated" }).open, true);
  assert.equal(sectionState({ status: "to_review" }).label, "To check");
  assert.equal(sectionState({ status: "anything_new" }).done, false);
  const list = [{ key: "business", status: "looks_right" }, { key: "hours_services", status: "to_review" }, { key: "team", status: "change_requested" }, { key: "receptionist_phone", status: "updated" }];
  assert.equal(nextOpenSection(list), "hours_services");
  assert.equal(nextOpenSection(list, "hours_services"), "receptionist_phone");
  assert.equal(nextOpenSection(list, "receptionist_phone"), "hours_services", "wraps round");
  assert.equal(detailsDone({ sections: list }), false);
  assert.equal(detailsDone({ sections: [] }), false, "nothing to check is not the same as checked");
  assert.equal(detailsDone({ sections: list.map((s) => ({ ...s, status: "looks_right" })) }), true);
});

test("check your details: the admin's entries in plain words, no dashes", () => {
  const biz = sectionRows("business", { name: "A", phone: "+15555550100", address: { line_1: "1 Main Street", city: "Austin", state: "TX", postal_code: "78701", country: "US" }, timezone: "America/New_York", website: null });
  assert.deepEqual(Object.fromEntries(biz).Phone, "(555) 555 0100");
  assert.equal(Object.fromEntries(biz).Address, "1 Main Street, Austin, TX 78701, US");
  assert.equal(Object.fromEntries(biz).Website, "Not set");
  assert.equal(Object.fromEntries(biz)["Time zone"], "America/New York");
  const hours = Object.fromEntries(sectionRows("hours_services", { hours: [{ weekday: 1, opens: "09:00:00", closes: "17:00" }], services: [], takes_bookings: false }));
  assert.deepEqual(hours["Opening hours"], ["Monday: 09:00 to 17:00"]);
  const week = Object.fromEntries(sectionRows("hours_services", { hours: [{ weekday: 0, opens: "10:00", closes: "12:00" }, { weekday: 1, opens: "09:00", closes: "17:00" }] }));
  assert.deepEqual(week["Opening hours"], ["Monday: 09:00 to 17:00", "Sunday: 10:00 to 12:00"], "0 is Sunday, listed after Saturday");
  assert.equal(hours.Services, "No services yet");
  assert.equal(hours["Takes bookings"], "No");
  const rp = Object.fromEntries(sectionRows("receptionist_phone", { language: "en-US", transfer_to: { type: "owner" }, phone_setup: { mode: "call_forwarding", forward_from: "+15555550100" }, numbers: [{ e164: "+15555550102", status: "pending" }] }));
  assert.equal(rp.Language, "English");
  assert.equal(rp["Calls are transferred to"], "You, the owner");
  assert.equal(rp["Phone setup"], "Calls forwarded from (555) 555 0100");
  assert.deepEqual(rp["Zella Voice numbers"], ["(555) 555 0102 (not active yet)"]);
  assert.equal(Object.fromEntries(sectionRows("team", { members: [] }))["Team members"], "No team members yet");
  // a missing list is never shown as an empty one
  assert.equal(Object.fromEntries(sectionRows("team", {}))["Team members"], UNAVAILABLE);
  assert.equal(Object.fromEntries(sectionRows("team", null))["Team members"], UNAVAILABLE);
  assert.equal(Object.fromEntries(sectionRows("hours_services", { hours: [] })).Services, UNAVAILABLE);
  assert.equal(Object.fromEntries(sectionRows("receptionist_phone", {}))["Zella Voice numbers"], UNAVAILABLE);
  assert.equal(Object.fromEntries(sectionRows("receptionist_phone", { numbers: [] }))["Zella Voice numbers"], "No numbers yet");
  assert.equal(sectionRows("unknown", {}).length, 0);
  for (const k of ["business", "hours_services", "team", "receptionist_phone"]) for (const [l, v] of sectionRows(k, null)) assert.doesNotMatch(`${l} ${v}`, DASH);
  assert.equal(phoneWords("+44-20-7946-0000"), "+44 20 7946 0000");
  assert.equal(languageWords(["en", "es"]), "English and Spanish");
});

test("verify your identity: the five server states, never verified by accident", () => {
  assert.equal(identityState({ status: "needed" }).label, "Documents needed");
  assert.equal(identityState({ status: "checking" }).label, "Checking");
  assert.equal(identityState({ status: "verified" }).label, "Verified");
  assert.equal(identityState({ status: "try_again" }).label, "Try again");
  assert.equal(identityState({ status: "in_review" }).label, "In review");
  assert.equal(identityState({ status: "approved_maybe" }).label, "Checking");
  assert.equal(identityState(null).label, "Checking");
  assert.equal(identityPassed({ status: "VERIFIED" }), false, "only the exact server word counts");
  assert.deepEqual(uploadKinds({ can_upload: true, upload_kinds: ["owner_identity"] }), ["owner_identity"]);
  assert.deepEqual(uploadKinds({ can_upload: false, upload_kinds: ["owner_identity"] }), [], "never offer an upload the server refuses");
  assert.equal(canLeave("identity", { identity: { status: "in_review" } }), false);
});

test("pay: Payment received only when the server says confirmed", () => {
  assert.equal(paymentState(null).label, "Payment opens here soon");
  assert.equal(paymentState({ status: "waiting", reason: "payments_not_connected" }).label, "Payment opens here soon");
  assert.equal(paymentState({ status: "locked", reason: "identity_first" }).key, "locked");
  assert.equal(paymentState({ status: "paid" }).key, "waiting", "an unknown word is not a confirmation");
  assert.equal(paymentState({ status: "confirmed" }).label, "Payment received");
  assert.equal(paymentPassed({ status: "waiting", confirmed_at: "2026-11-16T00:00:00Z" }), false);
  assert.equal(canLeave("payment", { payment: { status: "waiting" } }), false);
  assert.equal(canLeave("plan", { plan: { available: false } }), false);
});

test("error codes become the contract's words; raw codes never show", () => {
  assert.equal(errorWords({ code: "P0001", message: "NOT_ALLOWED" }), "Only the business owner can do this.");
  assert.equal(errorWords(Object.assign(new Error("STEP_LOCKED"), { code: "STEP_LOCKED" })), "Finish the earlier steps first.");
  assert.equal(errorWords({ code: "UPLOAD_NOT_ALLOWED", message: "We already have your documents." }), "We already have your documents.");
  assert.equal(errorWords({ code: "NOTE_REQUIRED", message: "NOTE_REQUIRED", details: "too_long" }), "Keep the note under 1000 characters.");
  assert.equal(errorWords({ message: "SOME_NEW_CODE" }), "Something went wrong. Please try again.");
  assert.equal(errorWords({ message: "Failed to fetch" }), "We couldn't reach Zella Voice. Check your connection and try again.");
  assert.equal(errorCode({ message: "PLAN_CHANGED" }), "PLAN_CHANGED");
  for (const w of Object.values(ERROR_WORDS)) assert.doesNotMatch(w, DASH);
});

test("graceful degradation: calls that aren't deployed read as not ready", () => {
  assert.equal(isNotReady({ code: "PGRST202", message: "Could not find the function public.zella_owner_onboarding_get" }), true);
  assert.equal(isNotReady({ message: "Could not find the function public.x(p_business_id) in the schema cache" }), true);
  assert.equal(isNotReady({ status: 404, message: "Requested function was not found" }), true);
  assert.equal(isNotReady({ status: 404, code: "NOT_FOUND" }), false, "the server's own NOT_FOUND is a real answer");
  assert.equal(isNotReady({ code: "P0001", message: "NOT_ALLOWED" }), false, "a refusal is never hidden as not ready");
  assert.equal(isNotReady(new Error("Failed to fetch")), false, "a network failure is an error with a retry");
  assert.equal(isNotReady(null), false);
});

test("words: money in cents and allowances", () => {
  assert.equal(money(9900), "$99");
  assert.equal(money(1950), "$19.50");
  assert.equal(money(null), "Not set");
  assert.equal(allowance(1000, "minute"), "1,000 minutes");
  assert.equal(allowance(1, "person", "people"), "1 person");
  assert.equal(allowance(undefined, "text"), "Not set");
});

test("stand in: the whole journey, with the server's gates", async () => {
  const api = createFakeApi({ storage: memory(), delay: 0 });
  const { businesses } = await api.listBusinesses();
  const id = businesses[0].business_id;
  let s = await api.getState(id);
  assert.equal(resumeStep(s), "welcome");
  await assert.rejects(api.completeStep(id, "details"), (e) => errorCode(e) === "STEP_LOCKED");
  s = (await api.completeStep(id, "welcome")).state;
  assert.equal(resumeStep(s), "security");
  await assert.rejects(api.completeStep(id, "security"), (e) => errorCode(e) === "SECURITY_INCOMPLETE" && /password/.test(e.details));
  await api.setPassword("A good pass 1!");
  assert.equal(securityPart((await api.getState(id)).security), "authenticator");
  await assert.rejects(api.finishMfa("x", "000000"), /didn't work/);
  await api.finishMfa("x", "123456");
  s = (await api.completeStep(id, "security")).state;
  assert.equal(resumeStep(s), "details");
  await assert.rejects(api.answerSection(id, "team", "change", "  "), (e) => errorCode(e) === "NOTE_REQUIRED");
  s = (await api.answerSection(id, "team", "change", "Add Maya.")).state;
  assert.equal(sectionState(s.details.sections.find((x) => x.key === "team")).label, "Waiting for Zella Voice");
  const seen = (st, k) => st.details.sections.find((x) => x.key === k).data_hash;
  await assert.rejects(api.answerSection(id, "business", "looks_right"), (e) => errorCode(e) === "INVALID_INPUT", "Looks right needs what was shown");
  await assert.rejects(api.answerSection(id, "business", "looks_right", null, "h0"), (e) => errorCode(e) === "DETAILS_CHANGED");
  for (const k of ["business", "hours_services", "receptionist_phone"]) s = (await api.answerSection(id, k, "looks_right", null, seen(s, k))).state;
  await assert.rejects(api.completeStep(id, "details"), (e) => errorCode(e) === "SECTIONS_NOT_CONFIRMED" && e.details === "team");
  api.adminChangeDone("team", "Added Maya.");
  s = await api.getState(id);
  assert.equal(nextOpenSection(s.details.sections), "team");
  s = (await api.answerSection(id, "team", "looks_right", null, seen(s, "team"))).state;
  assert.equal(detailsDone(s.details), true);
  s = (await api.completeStep(id, "details")).state;
  assert.equal(resumeStep(s), "identity");
  assert.equal(identityState(s.identity).key, "needed");
  assert.equal(paymentState(s.payment).key, "locked");
  for (const kind of ["owner_identity", "business_registration"]) {
    const meta = { businessId: id, kind, fileName: `${kind}.pdf`, mimeType: "application/pdf", size: 1000 };
    const up = await api.identityUploadUrl(meta);
    await api.uploadFile(up.path, up.token, {});
    await api.identityUploadConfirm({ ...meta, path: up.path });
  }
  assert.equal(identityState(await api.identityStatus(id)).key, "checking");
  await assert.rejects(api.identityUploadUrl({ businessId: id, kind: "owner_identity" }), (e) => errorCode(e) === "UPLOAD_NOT_ALLOWED");
  api.rejectIdentity("The photo is blurred.");
  let identity = await api.identityStatus(id);
  assert.equal(identityState(identity).key, "try_again");
  assert.deepEqual(uploadKinds(identity), ["owner_identity"]);
  assert.equal(identity.documents.find((d) => d.kind === "owner_identity").review_note, "The photo is blurred.");
  await assert.rejects(api.completeStep(id, "identity"), (e) => errorCode(e) === "IDENTITY_NOT_VERIFIED");
  api.approveIdentity();
  s = (await api.completeStep(id, "identity")).state;
  assert.equal(paymentState(s.payment).key, "waiting");
  await assert.rejects(api.acceptPlan(id, s.plan.current.version + 1), (e) => errorCode(e) === "PLAN_CHANGED");
  s = (await api.acceptPlan(id, s.plan.current.version)).state;
  assert.equal(resumeStep(s), "payment");
  await assert.rejects(api.completeStep(id, "payment"), (e) => errorCode(e) === "PAYMENT_NOT_CONFIRMED");
  assert.equal(paymentPassed(await api.paymentStatus(id)), false, "never confirmed by itself");
  api.confirmPayment();
  s = (await api.completeStep(id, "payment")).state;
  assert.equal(resumeStep(s), "done");
  s = (await api.completeStep(id, "done")).state;
  assert.ok(s.completed_at);
  assert.equal((await api.listBusinesses()).businesses[0].completed, true);
});

test("stand in: try again twice goes to In review, with no upload", async () => {
  const api = createFakeApi({ scenario: "returning", storage: memory(), delay: 0 });
  api.rejectIdentity(); api.rejectIdentity();
  const identity = await api.identityStatus("00000000-0000-4000-8000-0000000000b1");
  assert.equal(identityState(identity).key, "in_review");
  assert.deepEqual(uploadKinds(identity), []);
});

test("stand in: Finish later and a new page load resume at the same step", async () => {
  const storage = memory();
  const a = createFakeApi({ storage, delay: 0 });
  const id = (await a.listBusinesses()).businesses[0].business_id;
  await a.completeStep(id, "welcome");
  await a.finishLater(id);
  const b = createFakeApi({ storage, delay: 0 });   // a new page load
  const s = await b.getState(id);
  assert.ok(s.paused_at);
  assert.equal(resumeStep(s), "security");
  assert.equal((await b.resume(id)).state.paused_at, null);
});

test("stand in: not deployed, upload not deployed, a failed load, and nothing waiting", async () => {
  const none = createFakeApi({ scenario: "notready", storage: memory(), delay: 0 });
  await assert.rejects(none.listBusinesses(), (e) => isNotReady(e));
  const partial = createFakeApi({ scenario: "partial", storage: memory(), delay: 0 });
  const id = (await partial.listBusinesses()).businesses[0].business_id;
  assert.ok(await partial.getState(id));
  await assert.rejects(partial.identityUploadUrl({ businessId: id, kind: "owner_identity" }), (e) => isNotReady(e));
  const flaky = createFakeApi({ scenario: "flaky", storage: memory(), delay: 0 });
  await assert.rejects(flaky.getState(id), (e) => !isNotReady(e));
  assert.ok((await flaky.getState(id)).business_name, "a retry works");
  const empty = createFakeApi({ scenario: "none", storage: memory(), delay: 0 });
  assert.deepEqual((await empty.listBusinesses()).businesses, []);
});

test("contract version 2: MFA_REQUIRED from the request check, and the upload function's own words", () => {
  assert.equal(errorCode({ code: "MFA_REQUIRED", message: "MFA_REQUIRED", status: 403 }), "MFA_REQUIRED");
  assert.equal(errorCode({ code: "42501", message: "MFA_REQUIRED" }), "MFA_REQUIRED");
  assert.equal(errorWords({ code: "42501", message: "MFA_REQUIRED" }), "Enter the code from your authenticator app to continue.");
  assert.equal(errorWords({ code: "INVALID_INPUT", words: "The file is over 10 MB. Upload a smaller copy." }), "The file is over 10 MB. Upload a smaller copy.");
  assert.equal(errorWords({ code: "INVALID_INPUT", words: "A well-meant reply" }), "That didn't work. Reload the page and try again.", "words with a hyphen fall back to the table");
  assert.equal(errorWords({ code: "INVALID_INPUT" }), "That didn't work. Reload the page and try again.");
  assert.equal(isNotReady({ status: 404, notReady: true }), true);
});

// Finish later, then Carry on now, after the password saved but reading the next step failed: the screen must show the
// server's state (password set), never the stale one, so the password form isn't shown and saved a second time.
test("Carry on now shows the server's state, never the stale one", async () => {
  const stale = { business_id: "b1", security: { password_set: false } };
  const fresh = { business_id: "b1", security: { password_set: true } };
  const calls = [];
  const api = (resume, getState) => ({
    resume: async (id) => { calls.push(`resume:${id}`); return resume(); },
    getState: async (id) => { calls.push(`get:${id}`); return getState(); },
  });
  const ok = await stateAfterResume(api(() => ({ changed: true, state: fresh }), () => stale), "b1");
  assert.equal(securityPart(ok.security), "authenticator");
  assert.deepEqual(calls.splice(0), ["resume:b1"]);
  const failedResume = await stateAfterResume(api(() => { throw new Error("down"); }, () => fresh), "b1");
  assert.equal(failedResume, fresh);
  assert.deepEqual(calls.splice(0), ["resume:b1", "get:b1"]);
  // neither answers: null, so the paused screen stays (with a retry message) and the stale password form isn't shown
  const bothFail = await stateAfterResume(api(() => { throw new Error("down"); }, () => { throw new Error("down"); }), "b1");
  assert.equal(bothFail, null);
  assert.equal(await stateAfterResume(api(() => ({ changed: false }), () => null), "b1"), null);
});

// Contract version 3: a plan version saved after acceptance sends the owner back to the plan; database errors that
// aren't the contract's never reach the screen as raw text, and an ended session asks to sign in again.
test("a newer plan after acceptance: the journey shows the plan again", () => {
  const st = { current_step: "payment", plan: { available: true, accepted: false } };
  assert.equal(resumeStep(st), "plan");
  assert.equal(resumeStep({ ...st, plan: { available: true, accepted: true } }), "payment");
  assert.equal(resumeStep({ ...st, completed_at: "2026-11-17T00:00:00Z" }), "done");
  assert.equal(resumeStep({ current_step: "identity", plan: { available: true, accepted: false } }), "identity");
});

test("database errors: contract codes kept, raw text replaced, an ended session asks to sign in", () => {
  const known = rpcError({ code: "P0001", message: "DETAILS_CHANGED", details: null });
  assert.equal(errorCode(known), "DETAILS_CHANGED");
  assert.equal(errorWords(known), "These details were just updated. Please check them again.");
  const raw = rpcError({ code: "42501", message: "permission denied for function zella_owner_onboarding_get" });
  assert.equal(raw.message, "Something went wrong. Please try again.");
  assert.equal(raw.rawMessage, "permission denied for function zella_owner_onboarding_get");
  assert.doesNotMatch(errorWords(raw), /zella|permission/);
  const ended = rpcError({ code: "PGRST301", message: "JWT expired" });
  assert.equal(errorWords(ended), "Please sign in again.");
  assert.equal(isNotReady(rpcError({ code: "PGRST202", message: "Could not find the function public.x" })), true);
  assert.match(errorWords(rpcError({ message: "TypeError: Failed to fetch" })), /couldn't reach Zella Voice/);
  assert.equal(errorCode(rpcError({ code: "42501", message: "MFA_REQUIRED" })), "MFA_REQUIRED");
});

// Overlapping answers on the details step: an older reply, or an older read again, never hides a newer answer.
test("details answers: a delayed reply and a delayed read again never apply an older snapshot", async () => {
  const later = () => { let done; const p = new Promise((r) => { done = r; }); return { p, done }; };
  const applied = []; const reads = []; const problems = [];
  const q = createAnswerQueue({ read: () => { const d = later(); reads.push(d); return d.p; }, apply: (s) => applied.push(s), onReadError: (e) => problems.push(e.message) });
  const a = later(), b = later();
  const first = q.answer(() => a.p), second = q.answer(() => b.p);
  b.done("state after B"); assert.equal(await second, "state after B", "the latest answer's reply is used");
  a.done("state after A only"); assert.equal(await first, null, "the older reply is dropped");
  assert.equal(reads.length, 1, "and the state is read again");
  const third = later(); const answerC = q.answer(() => third.p);   // the owner answers again while that read is on its way
  reads[0].done("old snapshot"); await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(applied, [], "the older read is not applied over the newer answer");
  third.done("state after C"); assert.equal(await answerC, "state after C");
  // a failed read is reported, never silent
  const q2 = createAnswerQueue({ read: async () => { throw new Error("offline"); }, apply: () => {}, onReadError: (e) => problems.push(e.message) });
  await q2.reread(); assert.deepEqual(problems, ["offline"]);
  // a read that answers nothing is a failed read too, never a silent stale screen
  const q3 = createAnswerQueue({ read: async () => null, apply: () => { throw new Error("must not apply"); }, onReadError: (e) => problems.push(e.message) });
  await q3.reread(); assert.deepEqual(problems, ["offline", "Your setup didn't load."]);
});

test("a new plan version while payment or the last step is open: the journey shows the plan", () => {
  const changed = { code: "P0001", message: "PLAN_CHANGED" };
  assert.equal(afterCompleteError("payment", changed), "plan");
  assert.equal(afterCompleteError("done", changed), "plan");
  assert.equal(afterCompleteError("plan", changed), null, "on the plan step the plan screen reloads itself");
  assert.equal(afterCompleteError("payment", { message: "STEP_LOCKED" }), "reload");
  assert.equal(afterCompleteError("payment", { message: "PAYMENT_NOT_CONFIRMED" }), null);
});
