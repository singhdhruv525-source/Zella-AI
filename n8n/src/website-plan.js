// Zella - Website Crawler: one claimed job in (read the sitemap, or read one approved page). Before anything is
// fetched the address is checked again here: http/https only, no login in the address, no numeric or internal
// hostnames, only ports 80 and 443, and it must belong to the owner's own site.
const j = $json;
const bad = (why) => ({ json: { skip: true, why } });
if (!j || (j.kind !== 'discover' && j.kind !== 'page')) return bad('no_job');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const id = j.kind === 'discover' ? j.source_id : j.page_id;
if (typeof id !== 'string' || !uuid.test(id)) return bad('bad_id');
const url = typeof j.url === 'string' ? j.url : '';
const m = /^https?:\/\/([a-z0-9.-]+)(?::([0-9]{1,5}))?(?:[\/?]|$)/i.exec(url);
if (!m || url.length > 2000 || /[\s<>"'\\]/.test(url)) return bad('bad_url');
const host = m[1].toLowerCase();
const port = m[2];
const strip = (h) => h.replace(/^www\./, '');
if (port && port !== '80' && port !== '443') return bad('bad_port');
if (!/\./.test(host) || /^\.|\.$|\.\./.test(host) || /^[0-9.]+$/.test(host)) return bad('bad_host');
if (/(^|\.)(localhost|local|internal|lan|home|corp|intranet|localdomain|test|invalid|example)$/.test(host)) return bad('internal_host');
if (typeof j.host !== 'string' || strip(host) !== strip(j.host.toLowerCase())) return bad('other_site');
return { json: { skip: false, kind: j.kind, id, url, host: strip(host) } };
