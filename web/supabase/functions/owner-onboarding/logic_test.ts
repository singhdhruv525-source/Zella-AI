// The pure parts of owner-onboarding: input checks, the paths handed out, database codes and the owner's words.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { dbCode, ERRORS, failure, pathBelongs, readUpload, tokenFrom, uploadPath } from "./logic.ts";

const BIZ = "6f1c0c1e-0000-4000-8000-000000000001";
const good = { businessId: BIZ.toUpperCase(), kind: "business_registration", fileName: " licence.pdf ", mimeType: "APPLICATION/PDF", size: 5 };

Deno.test("readUpload keeps clean values only", () => {
  const r = readUpload(good);
  assert(r.ok);
  assertEquals(r.value, { businessId: BIZ, kind: "business_registration", fileName: "licence.pdf", mimeType: "application/pdf", size: 5, ext: "pdf" });
  for (const bad of [{ fileName: "a/b.pdf" }, { fileName: "x".repeat(201) }, { size: 1.5 }, { size: "5" }, { kind: "OWNER_IDENTITY" }, { businessId: `${BIZ}0` }]) {
    assertEquals(readUpload({ ...good, ...bad }).ok, false, JSON.stringify(bad));
  }
});

Deno.test("paths: only this business, kind and file type, with a random name", () => {
  const r = readUpload(good);
  assert(r.ok);
  const p = uploadPath(r.value, crypto.randomUUID());
  assert(pathBelongs(p, r.value), p);
  assertEquals(pathBelongs(p.replace(".pdf", ".jpg"), r.value), false);
  assertEquals(pathBelongs(p.replace("business_registration", "owner_identity"), r.value), false);
  assertEquals(pathBelongs(`${p}/x`, r.value), false);
  assertEquals(pathBelongs(null, r.value), false);
});

Deno.test("database codes and the words shown: no dashes, no raw messages", () => {
  assertEquals(dbCode(400, { code: "P0001", message: "STEP_LOCKED" }), "STEP_LOCKED");
  assertEquals(dbCode(401, { message: "JWT expired" }), "NOT_SIGNED_IN");
  assertEquals(dbCode(400, { message: "permission denied for function x" }), null);
  assertEquals(failure("PLAN_MISSING"), { status: 500, body: { error: ERRORS.SERVER_ERROR.words, code: "SERVER_ERROR" } });
  for (const [code, e] of Object.entries(ERRORS)) assert(!/[-–—]/.test(e.words), `${code}: ${e.words}`);
  assert(Object.values(ERRORS).every((e) => !/zella voice/i.test(e.words) || e.words.includes("Zella Voice")));
});

Deno.test("the upload token comes from the signed link", () => {
  assertEquals(tokenFrom("/object/upload/sign/business-documents/a/b.jpg?token=abc.def"), "abc.def");
  assertEquals(tokenFrom("/object/upload/sign/business-documents/a/b.jpg"), null);
  assertEquals(tokenFrom(42), null);
});
