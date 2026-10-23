// Zella - Meta Health: WhatsApp message templates, reduced to name, language, category, status and the body text.
const plan = $('Build request').item.json;
const r = $json;
const b = r.body && typeof r.body === 'object' ? r.body : {};
if (!(Number(r.statusCode) >= 200 && Number(r.statusCode) < 300) || !Array.isArray(b.data)) return { json: { record: null } };
const list = b.data.slice(0, 100).filter((t) => t && typeof t.name === 'string').map((t) => {
  const body = Array.isArray(t.components) ? t.components.find((c) => c && c.type === 'BODY') : null;
  return { name: t.name.slice(0, 100), language: typeof t.language === 'string' ? t.language.slice(0, 10) : 'en_US', category: typeof t.category === 'string' ? t.category.slice(0, 40) : null, status: typeof t.status === 'string' ? t.status.slice(0, 20) : 'unknown', body: body && typeof body.text === 'string' ? body.text.slice(0, 1000) : null };
});
return { json: { record: { p_page_id: plan.page_id, p_templates: list } } };
