// What a stored file really is, from its bytes (not from the name or the type the browser declared).
// Used by the record-files edge function before a file on a record becomes visible to anyone but the uploader.
export const MAX_BYTES = 10 * 1024 * 1024;
export type Verdict = { ok: true } | { ok: false; reason: string };

const startsWith = (b: Uint8Array, sig: number[], at = 0) => sig.every((x, i) => b[at + i] === x);
const ascii = (b: Uint8Array, from: number, to: number) => String.fromCharCode(...b.subarray(from, to));

// file signatures for the five allowed types
export function signatureMatches(mime: string, b: Uint8Array): boolean {
  switch (mime) {
    case "image/jpeg": return startsWith(b, [0xff, 0xd8, 0xff]);
    case "image/png": return startsWith(b, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    case "image/webp": return ascii(b, 0, 4) === "RIFF" && ascii(b, 8, 12) === "WEBP";
    case "image/heic": return ascii(b, 4, 8) === "ftyp" && ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].includes(ascii(b, 8, 12));
    case "application/pdf": return ascii(b, 0, 5) === "%PDF-";
    default: return false;
  }
}

// PDF features that run, launch or carry something; looked for in the file and inside its compressed streams
const ACTIVE = /\/(JavaScript|JS|Launch|EmbeddedFiles?|RichMedia|XFA|SubmitForm|ImportData|GoToR|GoToE)(?![A-Za-z0-9])/;
const latin1 = (b: Uint8Array) => { let s = ""; for (let i = 0; i < b.length; i += 65536) s += String.fromCharCode(...b.subarray(i, i + 65536)); return s; };
// PDF names may hide letters as #xx ("/J#61vaScript")
const unescapeNames = (s: string) => s.replace(/#([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));

async function inflate(data: Uint8Array, limit: number): Promise<Uint8Array | "too_big" | null> {
  try {
    const stream = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new DecompressionStream("deflate"));
    const reader = stream.getReader(); const parts: Uint8Array[] = []; let n = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      n += value.length; if (n > limit) { await reader.cancel(); return "too_big"; }
      parts.push(value);
    }
    const out = new Uint8Array(n); let at = 0; for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
  } catch { return null; }
}

export async function inspectPdf(b: Uint8Array): Promise<Verdict> {
  const text = latin1(b);
  if (/\/Encrypt(?![A-Za-z0-9])/.test(unescapeNames(text))) return { ok: false, reason: "encrypted PDF (can't be checked)" };
  if (ACTIVE.test(unescapeNames(text))) return { ok: false, reason: `PDF with active content (${unescapeNames(text).match(ACTIVE)![1]})` };
  // compressed streams (object streams can hide the same features)
  const re = /stream\r?\n/g; let m: RegExpExecArray | null; let streams = 0, budget = 64 * 1024 * 1024;
  while ((m = re.exec(text)) && streams < 2000) {
    const head = text.slice(Math.max(0, m.index - 400), m.index);
    const dict = head.slice(head.lastIndexOf("<<"));
    if (!/\/FlateDecode/.test(unescapeNames(dict))) continue;
    const start = m.index + m[0].length;
    const end = text.indexOf("endstream", start);
    if (end < 0) break;
    streams++;
    let stop = end; // the line break before "endstream" is not part of the data
    if (b[stop - 1] === 0x0a) stop--;
    if (b[stop - 1] === 0x0d) stop--;
    const raw = b.subarray(start, stop);
    const inflated = await inflate(raw, budget);
    if (inflated === "too_big") return { ok: false, reason: "PDF too large to check" }; // a compression bomb, or simply huge
    if (inflated === null) return { ok: false, reason: "damaged PDF (a compressed part can't be read)" }; // unreadable could hide anything
    budget -= inflated.length;
    if (ACTIVE.test(unescapeNames(latin1(inflated)))) return { ok: false, reason: "PDF with active content (in a compressed stream)" };
    if (budget <= 0) return { ok: false, reason: "PDF too large to check" };
  }
  return { ok: true };
}

export async function inspect(mime: string, b: Uint8Array): Promise<Verdict> {
  if (b.length === 0) return { ok: false, reason: "empty file" };
  if (b.length > MAX_BYTES) return { ok: false, reason: "larger than 10 MB" };
  if (!signatureMatches(mime, b)) return { ok: false, reason: `not really a ${mime.split("/")[1].toUpperCase()} file` };
  if (mime === "application/pdf") return await inspectPdf(b);
  return { ok: true };
}

export async function sha256(b: Uint8Array): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", b as Uint8Array<ArrayBuffer>))).map((x) => x.toString(16).padStart(2, "0")).join("");
}
