// The pure parts of owner-onboarding: input checks, the paths handed out, database codes and the owner's words.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { dbCode, ERRORS, failure, matchesType, pathBelongs, readUpload, tokenFrom, uploadPath } from "./logic.ts";

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

Deno.test("a file's first bytes must be those of its type", () => {
  const b = (...x: number[]) => new Uint8Array([...x, ...new Array(16).fill(0)].slice(0, 16));
  const t = (s: string, at = 0) => { const a = new Uint8Array(16); [...s].forEach((c, i) => { a[at + i] = c.charCodeAt(0); }); return a; };
  assert(matchesType(t("%PDF-1.7"), "application/pdf"));
  assert(matchesType(b(0xff, 0xd8, 0xff, 0xe1), "image/jpeg"));
  assert(matchesType(b(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a), "image/png"));
  const webp = t("RIFF"); webp.set(t("WEBP").slice(0, 4), 8); assert(matchesType(webp, "image/webp"));
  const heic = t("ftyp", 4); heic.set(t("heic").slice(0, 4), 8); assert(matchesType(heic, "image/heic"));
  assertEquals(matchesType(t("%PDF-1.7"), "image/jpeg"), false, "a PDF named a photo");
  assertEquals(matchesType(t("MZ"), "application/pdf"), false);
  assertEquals(matchesType(new Uint8Array(0), "image/png"), false, "an empty read");
  assertEquals(matchesType(b(0xff, 0xd8, 0xff), "text/html"), false, "a type that isn't allowed");
});
