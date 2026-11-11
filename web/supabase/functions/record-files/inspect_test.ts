// What the record-files check accepts and refuses, from crafted files (no real customer files).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { INFLATE_PIECE, inspect, MAX_BYTES, sha256 } from "./inspect.ts";

const enc = (s: string) => new TextEncoder().encode(s);
const cat = (...parts: Uint8Array[]) => { const o = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let a = 0; for (const p of parts) { o.set(p, a); a += p.length; } return o; };
async function deflate(s: string) { return new Uint8Array(await new Response(new Blob([enc(s)]).stream().pipeThrough(new CompressionStream("deflate"))).arrayBuffer()); }
const jpeg = cat(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]), enc("JFIF rest of image"));
const png = cat(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), enc("IHDR..."));
const webp = enc("RIFF\x10\x00\x00\x00WEBPVP8 ...");
const heic = cat(new Uint8Array([0, 0, 0, 0x18]), enc("ftypheic\x00\x00\x00\x00mif1heic"));
const pdf = (body: string) => enc(`%PDF-1.7\n${body}\n%%EOF`);
const plainPdf = pdf("1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj");
async function pdfWithStream(inside: string) {
  const z = await deflate(inside);
  return cat(enc(`%PDF-1.7\n3 0 obj << /Type /ObjStm /Length ${z.length} /Filter /FlateDecode >>\nstream\n`), z, enc("\nendstream\nendobj\n%%EOF"));
}

Deno.test("real images and plain PDFs pass", async () => {
  assertEquals(await inspect("image/jpeg", jpeg), { ok: true });
  assertEquals(await inspect("image/png", png), { ok: true });
  assertEquals(await inspect("image/webp", webp), { ok: true });
  assertEquals(await inspect("image/heic", heic), { ok: true });
  assertEquals(await inspect("application/pdf", plainPdf), { ok: true });
  assertEquals(await inspect("application/pdf", await pdfWithStream("BT /F1 12 Tf (Vaccination record) Tj ET")), { ok: true });
});
Deno.test("contents that don't match the declared type are refused", async () => {
  assertEquals((await inspect("image/jpeg", png)).ok, false);
  assertEquals((await inspect("image/png", enc("<html><script>alert(1)</script>"))).ok, false);
  assertEquals((await inspect("application/pdf", enc("MZ\x90\x00 windows program"))).ok, false);
  assertEquals((await inspect("image/svg+xml", enc("<svg onload=alert(1)>"))).ok, false); // not an allowed type at all
  assertEquals((await inspect("image/heic", cat(new Uint8Array([0, 0, 0, 0x18]), enc("ftypisom")))).ok, false); // an MP4, not a photo
});
Deno.test("empty and oversized files are refused", async () => {
  assertEquals(await inspect("image/png", new Uint8Array()), { ok: false, reason: "empty file" });
  const big = new Uint8Array(MAX_BYTES + 1); big.set(png);
  assertEquals(await inspect("image/png", big), { ok: false, reason: "larger than 10 MB" });
});
Deno.test("PDFs with active content are refused", async () => {
  for (const k of ["/JavaScript", "/JS (app.alert(1))", "/Launch << /F (cmd.exe) >>", "/EmbeddedFile", "/EmbeddedFiles", "/RichMedia", "/XFA", "/SubmitForm", "/ImportData", "/GoToR"]) {
    const v = await inspect("application/pdf", pdf(`1 0 obj << /OpenAction << /S ${k} >> >> endobj`));
    assert(!v.ok, k);
  }
});
Deno.test("active content hidden with #-escapes or inside a compressed stream is refused", async () => {
  assertEquals((await inspect("application/pdf", pdf("1 0 obj << /S /J#61vaScript /JS (x) >> endobj"))).ok, false);
  const v = await inspect("application/pdf", await pdfWithStream("4 0 obj << /S /JavaScript /JS (app.launchURL('x')) >> endobj"));
  assertEquals(v, { ok: false, reason: "PDF with active content (in a compressed stream)" });
});
Deno.test("names that merely start the same are not mistaken for active content", async () => {
  assertEquals(await inspect("application/pdf", pdf("1 0 obj << /JSONData (x) /Launcher 1 >> endobj")), { ok: true });
});
Deno.test("a compressed part that can't be read is refused, not skipped", async () => {
  const b = cat(enc(`%PDF-1.7\n1 0 obj << /Filter /FlateDecode >>\nstream\n`), enc("not deflate data /J"), enc("\nendstream\nendobj"));
  assertEquals((await inspect("application/pdf", b)).ok, false);
});
Deno.test("encrypted PDFs can't be checked and are refused", async () => {
  assertEquals((await inspect("application/pdf", pdf("trailer << /Encrypt 5 0 R >>"))).ok, false);
});
Deno.test("a compression bomb stops at the budget", async () => {
  const z = await deflate("A".repeat(70 * 1024 * 1024));
  const b = cat(enc(`%PDF-1.7\n1 0 obj << /Filter /FlateDecode >>\nstream\n`), z, enc("\nendstream\nendobj"));
  assertEquals(await inspect("application/pdf", b), { ok: false, reason: "PDF too large to check" }); // refused, never skipped
});
Deno.test("sha256", async () => {
  assertEquals(await sha256(enc("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

Deno.test("unchecked PDF streams fail closed", async () => {
  for (const [body, reason] of [
    ["1 0 obj << >> stream\nunterminated", "unterminated PDF stream"],
    ["1 0 obj << /Filter /ASCIIHexDecode >> stream\n2f4a53>\nendstream endobj", "unsupported PDF stream filter"],
    ["1 0 obj << /Filter [/ASCII85Decode /FlateDecode] >> stream\nx\nendstream endobj", "unsupported PDF stream filter"],
    ["1 0 obj << /Filter 2 0 R >> stream\nx\nendstream endobj", "unsupported PDF stream filter"],
    [Array.from({ length: 2001 }, (_, i) => `${i + 1} 0 obj << >> stream\nx\nendstream endobj`).join("\n"), "PDF has too many streams to check"],
  ]) assertEquals(await inspect("application/pdf", pdf(body)), { ok: false, reason });
});
Deno.test("nested and long stream dictionaries cannot hide compressed active content", async () => {
  const z = await deflate("/J#61vaScript");
  for (const extra of ["/Foo 1 0 obj", "/Note (1 0 obj)", "/Note (nested (2 0 obj) literal)", "/DecodeParms << /Predictor 1 >>", `/Padding (${"x".repeat(500)})`]) {
    const b = cat(enc(`%PDF-1.7\n1 0 obj << /Filter /FlateDecode ${extra} >> stream\n`), z, enc("\nendstream endobj"));
    assertEquals(await inspect("application/pdf", b), { ok: false, reason: "PDF with active content (in a compressed stream)" });
  }
});
Deno.test("stream markers inside compressed bytes are skipped", async () => {
  const bytes = enc("stream\ninnocent text");
  let a = 1, b = 0;
  for (const byte of bytes) { a = (a + byte) % 65521; b = (b + a) % 65521; }
  const n = bytes.length;
  const z = cat(new Uint8Array([0x78, 0x01, 0x01, n & 255, n >> 8, (~n) & 255, ((~n) >> 8) & 255]),
    bytes, new Uint8Array([b >> 8, b & 255, a >> 8, a & 255]));
  assert(new TextDecoder().decode(z).includes("stream"));
  const file = cat(enc(`%PDF-1.7\n3 0 obj << /Length ${z.length} /Filter /FlateDecode >>\nstream\n`), z, enc("\nendstream\nendobj\n%%EOF"));
  assertEquals((await inspect("application/pdf", file)).ok, true);
});
Deno.test("every stream filter entry must be supported", async () => {
  const z = await deflate("innocent");
  for (const filters of ["/Filter /FlateDecode /Filter /ASCIIHexDecode", "/Filter /ASCIIHexDecode /Filter /FlateDecode"]) {
    const file = cat(enc(`%PDF-1.7\n1 0 obj << ${filters} >> stream\n`), z, enc("\nendstream endobj"));
    assertEquals(await inspect("application/pdf", file), { ok: false, reason: "unsupported PDF stream filter" });
  }
});

Deno.test("indirect decode parameters fail closed before inspecting compressed content", async () => {
  const z = await deflate("/J#61vaScript");
  for (const parameters of ["2 0 R", "[2 0 R]"]) {
    const b = cat(enc(`%PDF-1.7\n1 0 obj << /Filter /FlateDecode /DecodeParms ${parameters} >> stream\n`), z, enc("\nendstream endobj"));
    assertEquals(await inspect("application/pdf", b), { ok: false, reason: "unsupported PDF stream parameters" });
  }
});

async function predictedPdf(bytes: Uint8Array, parameters: string) {
  const z = new Uint8Array(await new Response(new Blob([bytes as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new CompressionStream("deflate"))).arrayBuffer());
  return cat(enc(`%PDF-1.7\n1 0 obj << /Type /XRef /W [1 2 1] /Size 2 /Filter /FlateDecode /DecodeParms << ${parameters} >> /Length ${z.length} >> stream\n`), z, enc("\nendstream endobj\n%%EOF"));
}
Deno.test("predictor 12 cross-reference stream is accepted", async () => {
  // Two xref rows: free object and an in-use object, encoded with PNG Up.
  const bytes = new Uint8Array([2, 0, 0, 0, 255, 2, 1, 0, 9, 1]);
  assertEquals(await inspect("application/pdf", await predictedPdf(bytes, "/Predictor 12 /Columns 4")), { ok: true });
});
Deno.test("all supported predictors reveal active content, across rows and chunks", async () => {
  // Varied filler keeps the compressed stream large, so it is decompressed in many pieces and the name, well past the
  // midpoint, is only found if row state carries across chunk boundaries.
  let seed = 7;
  const next = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return (seed >>> 0) % 26; };
  const filler = Array.from({ length: 120000 }, () => String.fromCharCode(97 + next())).join("");
  const plain = enc(filler + "/J#61vaScript " + "y".repeat(1000));
  for (const predictor of [2, 10, 11, 12, 13, 14, 15]) {
    const encoded: number[] = [];
    let previous = 0;
    for (const byte of plain) {
      // One-byte rows; PNG Up (2) reconstructs from the preceding row.
      if (predictor !== 2) encoded.push(2);
      encoded.push(predictor === 2 ? byte : (byte - previous + 256) % 256);
      previous = byte;
    }
    const file = await predictedPdf(new Uint8Array(encoded), `/Predictor ${predictor}`);
    assert(file.length > 20 * INFLATE_PIECE, `the compressed stream must span many decompressor pieces (${file.length} bytes)`);
    assertEquals(await inspect("application/pdf", file), { ok: false, reason: "PDF with active content (in a compressed stream)" });
  }
});
Deno.test("indirect predictor parameters fail closed", async () => {
  const z = await deflate("/J#61vaScript");
  for (const parameters of ["/Predictor 12 /Columns 5 0 R", "/Predictor 12 0 R", "/Predictor 12 /Colors 1 0 R"]) {
    const b = cat(enc(`%PDF-1.7\n1 0 obj << /Filter /FlateDecode /DecodeParms << ${parameters} >> >> stream\n`), z, enc("\nendstream endobj"));
    assertEquals(await inspect("application/pdf", b), { ok: false, reason: "unsupported PDF stream predictor" }, parameters);
  }
});
const imagePdf = (dict: string, bytes: Uint8Array) =>
  cat(enc(`%PDF-1.7\n5 0 obj << ${dict} /Length ${bytes.length} >> stream\n`), bytes, enc("\nendstream endobj\n%%EOF"));
const jp2 = cat(new Uint8Array([0, 0, 0, 0x0c, 0x6a, 0x50, 0x20, 0x20, 0x0d, 0x0a, 0x87, 0x0a]), enc("image data"));
Deno.test("JPEG and JPEG 2000 images in a PDF are accepted", async () => {
  for (const [filter, bytes] of [["/DCTDecode", jpeg], ["[/DCTDecode]", jpeg], ["/JPXDecode", jp2]] as const) {
    assertEquals(await inspect("application/pdf", imagePdf(`/Type /XObject /Subtype /Image /Width 1 /Height 1 /Filter ${filter}`, bytes)), { ok: true }, filter);
  }
});
Deno.test("JPEG filters are refused outside real image streams", async () => {
  for (const [dict, bytes] of [
    ["/Type /ObjStm /N 1 /First 4 /Filter /DCTDecode", jpeg], // an object stream would be parsed as PDF syntax
    ["/Filter /DCTDecode", jpeg], // no image subtype
    ["/Subtype /Image /Filter /DCTDecode", enc("not a jpeg")], // no JPEG signature
    ["/Subtype /Image /Filter [/FlateDecode /DCTDecode]", jpeg], // filter chains are not checked
  ] as const) {
    assertEquals(await inspect("application/pdf", imagePdf(dict, bytes)), { ok: false, reason: "unsupported PDF stream filter" }, dict);
  }
  // The raw bytes of an image stream are still scanned with the rest of the file.
  assertEquals(await inspect("application/pdf", imagePdf("/Subtype /Image /Filter /DCTDecode", cat(jpeg, enc("/JavaScript")))),
    { ok: false, reason: "PDF with active content (JavaScript)" });
});
Deno.test("TIFF packed, byte, and 16-bit differences are reversed", async () => {
  // Byte samples with horizontal differences hide the active name.
  const plain = enc("/JavaScript"), encoded = plain.map((b, i) => i ? (b - plain[i - 1] + 256) % 256 : b);
  assertEquals(await inspect("application/pdf", await predictedPdf(encoded, `/Predictor 2 /Columns ${plain.length}`)),
    { ok: false, reason: "PDF with active content (in a compressed stream)" });
  for (const bits of [1, 2, 4, 16]) {
    assertEquals(await inspect("application/pdf", await predictedPdf(new Uint8Array(Math.ceil(4 * bits / 8)), `/Predictor 2 /Columns 4 /BitsPerComponent ${bits}`)), { ok: true });
  }
});
Deno.test("unsupported predictors and malformed rows fail closed", async () => {
  for (const parameters of ["/Predictor 3", "/Predictor 12 /Columns 0", "/Predictor 2 /BitsPerComponent 3"]) {
    assertEquals(await inspect("application/pdf", await predictedPdf(enc("x"), parameters)), { ok: false, reason: "unsupported PDF stream predictor" });
  }
  for (const bytes of [new Uint8Array([5, 0]), new Uint8Array([2])]) {
    assertEquals(await inspect("application/pdf", await predictedPdf(bytes, "/Predictor 12")), { ok: false, reason: "damaged PDF (a compressed part can't be read)" });
  }
});
Deno.test("oversized and unterminated filter arrays fail closed", async () => {
  for (const filter of [`[${" ".repeat(1025)}/FlateDecode]`, "[ /Filter [".repeat(5000)]) {
    const file = pdf(`1 0 obj << /Filter ${filter} >> stream\nx\nendstream endobj`);
    assertEquals(await inspect("application/pdf", file), { ok: false, reason: "unsupported PDF stream filter" });
  }
});

Deno.test("each PNG row filter is reversed before scanning", async () => {
  const columns = 8;
  const plain = enc("innocent/JavaScript     ".padEnd(24));
  const paeth = (a: number, b: number, c: number) => {
    const x = a + b - c, distances = [Math.abs(x - a), Math.abs(x - b), Math.abs(x - c)];
    return [a, b, c][distances.indexOf(Math.min(...distances))];
  };
  for (let filter = 0; filter <= 4; filter++) {
    const encoded: number[] = [];
    for (let i = 0; i < plain.length; i++) {
      if (i % columns === 0) encoded.push(filter);
      const left = i % columns ? plain[i - 1] : 0;
      const up = i >= columns ? plain[i - columns] : 0;
      const upperLeft = i >= columns && i % columns ? plain[i - columns - 1] : 0;
      const prediction = [0, left, up, Math.floor((left + up) / 2), paeth(left, up, upperLeft)][filter];
      encoded.push((plain[i] - prediction + 256) % 256);
    }
    assertEquals(await inspect("application/pdf", await predictedPdf(new Uint8Array(encoded), `/Predictor 15 /Columns ${columns}`)),
      { ok: false, reason: "PDF with active content (in a compressed stream)" });
  }
});
Deno.test("a stream marker inside a string or comment cannot hide a later compressed stream", async () => {
  const z = await deflate("<< /S /J#61vaScript /JS (app.alert(1)) >>");
  const real = cat(enc(`2 0 obj << /Type /ObjStm /Filter /FlateDecode /Length ${z.length} >>\nstream\n`), z, enc("\nendstream\nendobj\n"));
  for (const decoy of ["1 0 obj << /Title (decoy stream\n) >> endobj\n", "1 0 obj << >> endobj\n% stream\n", "1 0 obj << /T (unbalanced\n"]) {
    const file = cat(enc(`%PDF-1.7\n${decoy}`), real, enc("%%EOF"));
    assertEquals(await inspect("application/pdf", file), { ok: false, reason: "PDF stream marker inside a string or comment" }, decoy);
  }
  // Without a decoy the same stream is opened and its active content found.
  assertEquals(await inspect("application/pdf", cat(enc("%PDF-1.7\n"), real, enc("%%EOF"))), { ok: false, reason: "PDF with active content (in a compressed stream)" });
});
Deno.test("a very wide predictor row with little data is refused quickly", async () => {
  // Rows wider than the data never complete; the decoder must not allocate a row-sized buffer per piece.
  const started = performance.now();
  let seed = 11;
  const bytes = new Uint8Array(200000).map(() => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed & 255; });
  bytes[0] = 2;
  assertEquals(await inspect("application/pdf", await predictedPdf(bytes, "/Predictor 12 /Columns 9000000")),
    { ok: false, reason: "damaged PDF (a compressed part can't be read)" });
  assert(performance.now() - started < 5000, "refused without per-piece row allocations");
});
