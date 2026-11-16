// Pure parts of the owner-onboarding function (no network), tested in logic_test.ts. Contract:
// docs/OWNER_ONBOARDING_CONTRACT.md section 5.8.

export const DOCUMENT_BUCKET = "business-documents";
export const UPLOAD_KINDS = ["owner_identity", "business_registration"] as const;
export type UploadKind = typeof UPLOAD_KINDS[number];
export const MAX_BYTES = 10 * 1024 * 1024;
export const FILE_TYPES: Record<string, string> = {
  "application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic",
};

// Words the owner sees (no dashes, contract section 4), and the HTTP status for each database code.
export const ERRORS: Record<string, { status: number; words: string }> = {
  NOT_SIGNED_IN: { status: 401, words: "Please sign in again." },
  NOT_ALLOWED: { status: 403, words: "Only the business owner can do this." },
  MFA_REQUIRED: { status: 403, words: "Enter the code from your authenticator app to continue." },
  NOT_FOUND: { status: 404, words: "We couldn't find that business." },
  UPLOAD_NOT_ALLOWED: { status: 409, words: "We already have your documents." },
  STEP_LOCKED: { status: 409, words: "Finish the earlier steps first." },
  BUSINESS_NOT_AVAILABLE: { status: 409, words: "This workspace is paused. Contact Zella Voice support." },
  INVALID_INPUT: { status: 400, words: "That didn't work. Reload the page and try again." },
  TOO_LARGE: { status: 413, words: "That request was too large." },
  SERVER_ERROR: { status: 500, words: "Something went wrong on our side. Try again in a minute." },
};

export const failure = (code: string, words?: string) => {
  const e = ERRORS[code] ?? ERRORS.SERVER_ERROR;
  return { status: e.status, body: { error: words ?? e.words, code: ERRORS[code] ? code : "SERVER_ERROR" } };
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: unknown): v is string => typeof v === "string" && UUID.test(v);

export type UploadInput = { businessId: string; kind: UploadKind; fileName: string; mimeType: string; size: number; ext: string };

// Checks what the screen sent for an upload. Returns the clean values, or the plain words to show.
export function readUpload(body: Record<string, unknown>): { ok: true; value: UploadInput } | { ok: false; words: string } {
  if (!isUuid(body.businessId)) return { ok: false, words: ERRORS.INVALID_INPUT.words };
  if (typeof body.kind !== "string" || !(UPLOAD_KINDS as readonly string[]).includes(body.kind)) return { ok: false, words: ERRORS.INVALID_INPUT.words };
  const name = typeof body.fileName === "string" ? body.fileName.trim() : "";
  if (!name || name.length > 200 || /[\u0000-\u001f\u007f/\\]/.test(name)) return { ok: false, words: "Give the file a shorter name and try again." };
  const mime = typeof body.mimeType === "string" ? body.mimeType.toLowerCase() : "";
  const ext = FILE_TYPES[mime];
  if (!ext) return { ok: false, words: "Upload a PDF, JPG, PNG, WEBP or HEIC file." };
  const size = body.size;
  if (typeof size !== "number" || !Number.isSafeInteger(size) || size < 1) return { ok: false, words: ERRORS.INVALID_INPUT.words };
  if (size > MAX_BYTES) return { ok: false, words: "The file is over 10 MB. Upload a smaller copy." };
  return { ok: true, value: { businessId: body.businessId.toLowerCase(), kind: body.kind as UploadKind, fileName: name, mimeType: mime, size, ext } };
}

export const uploadPath = (u: UploadInput, random: string) => `${u.businessId}/${u.kind}/${random}.${u.ext}`;

// A path this function hands out for this business, kind and file type, and nothing else.
export function pathBelongs(path: unknown, u: UploadInput): path is string {
  if (typeof path !== "string" || path.length > 300) return false;
  const re = new RegExp(`^${u.businessId}/${u.kind}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.${u.ext}$`);
  return re.test(path);
}

// The code a database function raised (PostgREST: { code: "P0001", message: "<CODE>" }), or null.
export function dbCode(status: number, body: unknown): string | null {
  if (status === 401) return "NOT_SIGNED_IN";
  const m = body && typeof body === "object" ? (body as { message?: unknown }).message : null;
  if (typeof m === "string" && /^[A-Z_]{3,40}$/.test(m)) return m;
  return null;
}

// The token in a signed upload link (Supabase Storage answers { url: "/object/upload/sign/<bucket>/<path>?token=..." }).
export function tokenFrom(url: unknown): string | null {
  if (typeof url !== "string") return null;
  try { return new URL(url, "http://storage.local").searchParams.get("token"); } catch { return null; }
}
