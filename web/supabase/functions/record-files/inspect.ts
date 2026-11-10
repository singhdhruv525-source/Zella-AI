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

type Predictor = { value: number; colors: number; bits: number; columns: number };

// Decode one row at a time, preserving state across decompressor chunks.
function predictorDecoder(p: Predictor) {
  const rowBytes = Math.ceil(p.colors * p.columns * p.bits / 8);
  const pixelBytes = Math.ceil(p.colors * p.bits / 8);
  let previous = new Uint8Array(rowBytes), row = new Uint8Array(rowBytes);
  let offset = 0, filter = p.value === 2 ? 0 : -1;
  const paeth = (a: number, b: number, c: number) => {
    const x = a + b - c, da = Math.abs(x - a), db = Math.abs(x - b), dc = Math.abs(x - c);
    return da <= db && da <= dc ? a : db <= dc ? b : c;
  };
  return {
    complete: () => offset === 0 && (p.value === 2 || filter === -1),
    decode(chunk: Uint8Array) {
      const out: number[] = [];
      for (const byte of chunk) {
        if (filter === -1) { if (byte > 4) throw new Error("Invalid PNG filter"); filter = byte; continue; }
        const left = offset >= pixelBytes ? row[offset - pixelBytes] : 0;
        const up = previous[offset], upperLeft = offset >= pixelBytes ? previous[offset - pixelBytes] : 0;
        row[offset++] = byte + (p.value === 2 ? 0 : [0, left, up, Math.floor((left + up) / 2), paeth(left, up, upperLeft)][filter]);
        if (offset === rowBytes) {
          if (p.value === 2) {
            // TIFF differences are per component, including packed and 16-bit samples.
            const samples = p.colors * p.columns, mask = (1 << p.bits) - 1;
            const read = (i: number) => { const bit = i * p.bits; return p.bits === 16 ? row[bit / 8] * 256 + row[bit / 8 + 1] : (row[bit >> 3] >> (8 - p.bits - bit % 8)) & mask; };
            for (let i = p.colors; i < samples; i++) {
              const value = (read(i) + read(i - p.colors)) & mask, bit = i * p.bits;
              if (p.bits === 16) { row[bit / 8] = value >> 8; row[bit / 8 + 1] = value & 255; }
              else { const shift = 8 - p.bits - bit % 8; row[bit >> 3] = (row[bit >> 3] & ~(mask << shift)) | (value << shift); }
            }
          }
          for (const decoded of row) out.push(decoded);
          [previous, row] = [row, previous]; offset = 0; filter = p.value === 2 ? 0 : -1;
        }
      }
      return new Uint8Array(out);
    },
  };
}

async function inflate(data: Uint8Array, limit: number, predictor?: Predictor): Promise<number | "active" | "too_big" | null> {
  try {
    const stream = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new DecompressionStream("deflate"));
    const decoder = predictor ? predictorDecoder(predictor) : null;
    const reader = stream.getReader(); let n = 0, tail = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) return decoder && !decoder.complete() ? null : n;
        n += value.length;
        if (n > limit) { await reader.cancel(); return "too_big"; }
        const text = tail + latin1(decoder ? decoder.decode(value) : value);
        if (ACTIVE.test(unescapeNames(text))) { await reader.cancel(); return "active"; }
        // Retain enough raw bytes for a name (including #xx escapes) spanning chunks.
        tail = text.slice(-256);
      }
    } finally { reader.releaseLock(); }
  } catch { return null; }
}

// Mask literal strings, hex strings and comments without changing token positions.
function dictionaryTokens(text: string): string {
  const out = text.split("");
  let depth = 0, hex = false, comment = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (comment) { out[i] = " "; if (c === "\n" || c === "\r") comment = false; }
    else if (depth) {
      out[i] = " ";
      if (c === "\\") { if (i + 1 < text.length) out[++i] = " "; }
      else if (c === "(") depth++;
      else if (c === ")") depth--;
    } else if (hex) { out[i] = " "; if (c === ">") hex = false; }
    else if (c === "%") { comment = true; out[i] = " "; }
    else if (c === "(") { depth = 1; out[i] = " "; }
    else if (c === "<" && text[i + 1] === "<") { i++; }
    else if (c === "<") { hex = true; out[i] = " "; }
  }
  return out.join("");
}

export async function inspectPdf(b: Uint8Array): Promise<Verdict> {
  const text = latin1(b), names = unescapeNames(text);
  if (/\/Encrypt(?![A-Za-z0-9])/.test(names)) return { ok: false, reason: "encrypted PDF (can't be checked)" };
  const active = names.match(ACTIVE);
  if (active) return { ok: false, reason: `PDF with active content (${active[1]})` };
  const re = /\bstream\r?\n/g; let m: RegExpExecArray | null;
  let streams = 0, budget = 10 * 1024 * 1024, previousEnd = 0;
  while ((m = re.exec(text))) {
    if (++streams > 2000) return { ok: false, reason: "PDF has too many streams to check" };
    // Read from the enclosing object's start, not the last nested dictionary or a fixed window.
    const prefix = dictionaryTokens(text.slice(previousEnd, m.index));
    const objects = [...prefix.matchAll(/\b\d+\s+\d+\s+obj\b/g)];
    const object = objects[0];
    if (!object) return { ok: false, reason: "damaged PDF stream dictionary" };
    const dict = unescapeNames(prefix.slice(object.index! + object[0].length));
    const start = m.index + m[0].length, end = text.indexOf("endstream", start);
    if (end < 0) return { ok: false, reason: "unterminated PDF stream" };
    re.lastIndex = end + "endstream".length;
    previousEnd = re.lastIndex;
    let stop = end;
    if (b[stop - 1] === 0x0a) stop--;
    if (b[stop - 1] === 0x0d) stop--;
    const filters = [...dict.matchAll(/\/Filter(?=[\s<>\[\]()/]|$)\s*(\[[^\]]{0,1024}\]|\/[^\s<>\[\]()]+|[^\s]*)/g)];
    if (!filters.length) continue; // unfiltered bytes were scanned above
    if (filters.some((filter) => !/^\/FlateDecode$|^\[\s*\/FlateDecode\s*\]$/.test(filter[1]))) return { ok: false, reason: "unsupported PDF stream filter" };
    if (/\/DecodeParms\s*(?:\[\s*)?\d+\s+\d+\s+R\b/.test(dict)) return { ok: false, reason: "unsupported PDF stream parameters" };
    const parameter = (key: string, fallback: number) => {
      const matches = [...dict.matchAll(new RegExp(`/${key}(?=[\\s<>\\[\\]()/]|$)\\s*([^\\s<>\\[\\]()/]*)`, "g"))];
      if (!matches.length) return fallback;
      return matches.length === 1 && /^\d+$/.test(matches[0][1]) ? Number(matches[0][1]) : NaN;
    };
    const value = parameter("Predictor", 1);
    if (![1, 2, 10, 11, 12, 13, 14, 15].includes(value)) return { ok: false, reason: "unsupported PDF stream predictor" };
    let predictor: Predictor | undefined;
    if (value !== 1) {
      const colors = parameter("Colors", 1), bits = parameter("BitsPerComponent", 8), columns = parameter("Columns", 1);
      if (!Number.isSafeInteger(colors) || colors < 1 || !Number.isSafeInteger(columns) || columns < 1 ||
          ![1, 2, 4, 8, 16].includes(bits) || colors * columns * bits > budget * 8) {
        return { ok: false, reason: "unsupported PDF stream predictor" };
      }
      predictor = { value, colors, bits, columns };
    }
    const inflated = await inflate(b.subarray(start, stop), budget, predictor);
    if (inflated === "too_big") return { ok: false, reason: "PDF too large to check" };
    if (inflated === null) return { ok: false, reason: "damaged PDF (a compressed part can't be read)" };
    if (inflated === "active") return { ok: false, reason: "PDF with active content (in a compressed stream)" };
    budget -= inflated;
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
