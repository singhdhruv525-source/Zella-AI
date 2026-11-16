// Zella Voice - owner onboarding: the one owner step that needs the server key, uploading a new identity document
// for step 4 into the private "business-documents" bucket (docs/OWNER_ONBOARDING_CONTRACT.md section 5.8). Every other
// step of the journey is a database function the owner calls with their own session (sql/zella_owner_onboarding.sql).
//
//   identity_upload_url      checks with the owner's own session (zella_owner_identity_upload_check: active owner of
//                            THIS business, code verified session, on step 4, a kind they may send), then hands out
//                            a signed upload link for a path this function chooses.
//   identity_upload_confirm  checks again with the owner's session, confirms the stored file matches what was sent,
//                            and records it with the server key (zella_owner_identity_document_add, which checks the
//                            owner and the step again). The document then waits in the admin Verification queue.
//
// Who the owner is comes only from the database's answer to their own token, never from the request. Not behind admin
// permissions: owner-provision-business refuses anyone who is not a Zella Voice admin. verify_jwt is off
// (config.toml) because this function checks the token itself, through the database.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { withCors } from "../_shared/cors.ts";
import { DOCUMENT_BUCKET, dbCode, ERRORS, failure, pathBelongs, readUpload, tokenFrom, uploadPath } from "./logic.ts";

const TIMEOUT_MS = 10_000;   // BE-3: every outbound call has a time limit
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const fail = (code: string, words?: string) => { const f = failure(code, words); return json(f.body, f.status); };

export async function route(req: Request): Promise<Response> {
  if (req.method !== "POST") return fail("INVALID_INPUT");
  const base = Deno.env.get("SUPABASE_URL"), server = Deno.env.get("ZELLA_SERVER_SECRET_KEY"), anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !server || !anon) return fail("SERVER_ERROR");
  const userAuth = req.headers.get("authorization") ?? "";
  // a signed in person's token only: never the server key, never the publishable key alone
  if (!/^Bearer\s+\S+$/i.test(userAuth) || userAuth.includes(server) || userAuth.slice(7).trim() === anon) return fail("NOT_SIGNED_IN");

  const read = await readJsonLimited(req, 16_000);   // SEC-12
  if (!read.ok) return read.error === "too_large" ? fail("TOO_LARGE") : fail("INVALID_INPUT");
  const body = asObject(read.value);
  if (!body) return fail("INVALID_INPUT");
  const action = body.action;
  if (action !== "identity_upload_url" && action !== "identity_upload_confirm") return fail("INVALID_INPUT");
  const input = readUpload(body);
  if (!input.ok) return fail("INVALID_INPUT", input.words);
  const u = input.value;

  const asServer = { apikey: server, Authorization: `Bearer ${server}` };
  const call = (path: string, headers: Record<string, string>, payload: unknown) =>
    fetch(`${base}${path}`, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(payload), signal: AbortSignal.timeout(TIMEOUT_MS) });
  const answer = async (res: Response) => { try { return await res.json(); } catch { return null; } };

  // 1. as the owner: may this person upload this kind for this business now? (the database decides)
  const check = await call("/rest/v1/rpc/zella_owner_identity_upload_check", { apikey: anon, Authorization: userAuth }, { p_business_id: u.businessId, p_kind: u.kind });
  const checked = await answer(check);
  if (!check.ok) return fail(dbCode(check.status, checked) ?? "SERVER_ERROR");
  const userId = checked?.user_id;
  if (checked?.ok !== true || typeof userId !== "string") return fail("SERVER_ERROR");

  if (action === "identity_upload_url") {
    const path = uploadPath(u, crypto.randomUUID());
    const sign = await call(`/storage/v1/object/upload/sign/${DOCUMENT_BUCKET}/${path}`, asServer, {});
    const token = sign.ok ? tokenFrom((await answer(sign))?.url) : null;
    if (!token) return fail("SERVER_ERROR");
    return json({ path, token });
  }

  // 2. confirm: the path must be one this function hands out for this business, kind and type, and the stored file
  // must match what the screen said (the bucket itself also limits size and type)
  if (!pathBelongs(body.path, u)) return fail("INVALID_INPUT");
  const folder = `${u.businessId}/${u.kind}`, name = body.path.slice(folder.length + 1);
  const list = await call(`/storage/v1/object/list/${DOCUMENT_BUCKET}`, asServer, { prefix: folder, search: name, limit: 10, offset: 0 });
  const found = list.ok ? await answer(list) : null;
  const stored = Array.isArray(found) ? found.find((o) => o?.name === name) : null;
  if (!stored) return fail("INVALID_INPUT", "The file didn't finish uploading. Try again.");
  const size = stored.metadata?.size, mime = stored.metadata?.mimetype;
  if (size !== u.size || mime !== u.mimeType) return fail("INVALID_INPUT", "The file didn't upload correctly. Try again.");

  const add = await call("/rest/v1/rpc/zella_owner_identity_document_add", asServer, {
    p_business_id: u.businessId, p_user: userId, p_kind: u.kind, p_path: body.path, p_file_name: u.fileName, p_mime: u.mimeType, p_size: u.size,
  });
  const added = await answer(add);
  if (!add.ok) {
    const code = dbCode(add.status === 401 ? 500 : add.status, added);   // a 401 here is the server key, not the owner
    return fail(code && ERRORS[code] ? code : "SERVER_ERROR");
  }
  return json(added);
}

// A failed or timed out outbound call answers SERVER_ERROR rather than an unhandled 500.
export const handle = withCors(async (req: Request) => {
  try { return await route(req); } catch { return fail("SERVER_ERROR"); }
});

if (import.meta.main) Deno.serve(handle);
