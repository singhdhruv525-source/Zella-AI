// Zella - Website Crawler: turn what the website answered into a short, safe record for the database.
// Nothing here runs the page: it is only read as text. What is found are SUGGESTIONS (drafts) for the owner.
const plan = $('Plan').item.json;
const r = $json || {};
const status = Number(r.statusCode) || 0;
const failed = !!r.error && !status;
const raw = typeof r.body === 'string' ? r.body : '';
const body = raw.length > 600000 ? raw.slice(0, 600000) : raw;
const decode = (s) => String(s).replace(/&nbsp;|&#160;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#0?39;|&apos;/g, "'").replace(/&#(\d{2,5});/g, (_, n) => { const c = Number(n); return c > 31 && c < 65536 ? String.fromCharCode(c) : ' '; });
const clean = (s) => decode(s).replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();

if (plan.kind === 'discover') {
  let urls = []; let kids = [];
  if (status >= 200 && status < 300) {
    const isIndex = /<sitemapindex/i.test(body);
    const locs = [...body.matchAll(/<loc>\s*([^<\s]{5,2000})\s*<\/loc>/gi)].map((x) => decode(x[1])).slice(0, 300);
    if (isIndex) kids = locs.filter((u) => /^https?:\/\//i.test(u)).slice(0, 5); else urls = locs.filter((u) => /^https?:\/\//i.test(u));
  }
  return { json: { mode: 'discover', rpc: { p_source_id: plan.id, p_sitemap_url: plan.url, p_urls: urls, p_child_sitemaps: kids, p_status: status, p_error: failed ? 'network' : null } } };
}

// ---- a page
const base = { p_page_id: plan.id, p_http_status: status, p_final_url: null, p_title: null, p_text: null, p_hash: null, p_links: [], p_items: [], p_error: null };
if (failed) return { json: { mode: 'page', rpc: { ...base, p_error: 'network' } } };
if (status >= 300 && status < 400) {
  const h = r.headers && typeof r.headers === 'object' ? r.headers : {};
  let loc = typeof h.location === 'string' ? h.location : '';
  try { loc = new URL(loc, plan.url).toString(); } catch (e) { loc = ''; }
  return { json: { mode: 'page', rpc: { ...base, p_final_url: loc.slice(0, 2000) } } };
}
if (!(status >= 200 && status < 300)) return { json: { mode: 'page', rpc: base } };
const ct = r.headers && typeof r.headers === 'object' ? String(r.headers['content-type'] || '') : '';
if (ct && !/html|xml|text/i.test(ct)) return { json: { mode: 'page', rpc: { ...base, p_http_status: 0, p_error: 'not_a_web_page' } } };

const titleM = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(body);
const title = titleM ? clean(titleM[1]).slice(0, 200) : '';
// links to other pages of the same site
const links = [];
for (const m of body.matchAll(/<a\s[^>]*href\s*=\s*["']([^"']{1,1500})["']/gi)) {
  let u; try { u = new URL(decode(m[1]), plan.url); } catch (e) { continue; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') continue;
  if (u.username || u.password) continue;
  if (u.hostname.replace(/^www\./, '').toLowerCase() !== plan.host) continue;
  u.hash = '';
  const s = u.toString();
  if (!links.includes(s)) links.push(s);
  if (links.length >= 60) break;
}
// readable text, one line per block; headings are marked so questions and sections can be found
let html = body.replace(/<!--[\s\S]*?-->/g, ' ').replace(/<(script|style|noscript|svg|nav|template|iframe)\b[\s\S]*?<\/\1>/gi, ' ');
html = html.replace(/<h[1-6][^>]*>/gi, '\n#H# ').replace(/<(summary|dt)\b[^>]*>/gi, '\n#H# ')
  .replace(/<\/(h[1-6]|summary|dt|p|li|dd|tr|div|section|article|ul|ol|table|br)>|<br\s*\/?>/gi, '\n');
const lines = html.replace(/<[^>]+>/g, ' ').split('\n').map((l) => {
  const h = l.trim().startsWith('#H#');
  return { h, t: clean(l.replace('#H#', '')) };
}).filter((l) => l.t.length > 1);
const text = lines.map((l) => l.t).join('\n').slice(0, 20000);
// a simple fingerprint (FNV-1a) so a change in the words is noticed
let a = 0x811c9dc5; let b = 0x01000193;
for (let i = 0; i < text.length; i++) { a = Math.imul(a ^ text.charCodeAt(i), 16777619) >>> 0; b = (Math.imul(b ^ text.charCodeAt(i), 2246822519) + i) >>> 0; }
const hash = a.toString(16) + b.toString(16) + '-' + text.length;

const items = []; const seen = new Set();
const add = (kind, t, ans, key) => {
  const tt = t.slice(0, 100); const aa = ans.slice(0, 1200).trim();
  if (tt.length < 3 || aa.length < 8) return;
  const k = (key || kind + ':' + tt.toLowerCase().replace(/[^a-z0-9]+/g, '-')).slice(0, 120);
  if (seen.has(k) || items.length >= 15) return;
  seen.add(k); items.push({ kind, title: tt, answer: aa, key: k });
};
const after = (i, max) => { const out = []; for (let k = i + 1; k < lines.length && out.join(' ').length < max; k++) { if (lines[k].h) break; out.push(lines[k].t); } return out.join(' ').slice(0, max); };
const where = (title + ' ' + plan.url).toLowerCase();
const servicePage = /service|treatment|menu|pricing|price|package|what-we-do|offer/.test(where);
lines.forEach((l, i) => {
  if (!l.h) return;
  if (/\?$/.test(l.t)) { add('faq', l.t, after(i, 700)); return; }
  if (/cancel|refund|return|warranty|guarantee|deposit|no-show|late fee|payment|booking policy/i.test(l.t) && l.t.length < 80) { add('policy', l.t, after(i, 700)); return; }
  const next = after(i, 500);
  if (l.t.length < 80 && ((servicePage && next.length >= 20) || (/\$\s?\d/.test(next) && next.length >= 8))) add('service', l.t, next);
});
// prices: "Haircut - $45" lines, and a heading followed by a price. Each price is its own small answer so it can be checked on its own.
const priceLine = /^(.{3,60}?)\s*[-\u2013\u2014:|]\s*(?:from\s+|starting at\s+)?(\$\s?\d[\d,]*(?:\.\d{2})?(?:\s?[-\u2013]\s?\$?\s?\d[\d,]*(?:\.\d{2})?)?)/i;
lines.forEach((l, i) => {
  const m = !l.h ? l.t.match(priceLine) : null;
  if (m && !/\$/.test(m[1])) { add('price', m[1].trim(), 'The price for ' + m[1].trim() + ' is ' + m[2].replace(/\s+/g, '') + ' (from the website).'); return; }
  if (l.h && l.t.length < 80 && !/\$/.test(l.t)) {
    const n = after(i, 200); const pm = n.match(/\$\s?\d[\d,]*(?:\.\d{2})?/);
    if (pm && servicePage) add('price', l.t, 'The price for ' + l.t + ' is ' + pm[0].replace(/\s+/g, '') + ' (from the website).');
  }
});
// products: a heading with a description on a shop or product page
if (/shop|product|store|catalog|collection/.test(where)) {
  lines.forEach((l, i) => {
    if (l.h && l.t.length < 80 && !/\?$/.test(l.t)) { const n = after(i, 500); if (n.length >= 20) add('product', l.t, n); }
  });
}
// opening hours: lines that name days with times
const dayRe = /\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b[^.]{0,60}?(\d{1,2}(:\d{2})?\s?(am|pm)\b|closed|24 ?hours)/i;
const hoursLines = lines.filter((l) => l.t.length < 160 && dayRe.test(l.t)).map((l) => l.t).slice(0, 8);
if (hoursLines.length) add('hours', 'Opening hours', hoursLines.join('; '), 'hours');

return { json: { mode: 'page', rpc: { ...base, p_title: title, p_text: text, p_hash: hash, p_links: links, p_items: items } } };
