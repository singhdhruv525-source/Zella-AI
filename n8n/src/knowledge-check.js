// Zella - Knowledge: check one knowledge item an owner added or changed, then report it ready or failed.
// The assistant reads ready items straight from the database at call time, so there is nothing to upload.
// An item that changed again meanwhile is ignored by the database (version check).
const k = $json;
if (!k || !k.id) return { json: { record: null } };
const title = String(k.title || '').trim();
const answer = String(k.answer || '').trim();
let error = null;
if (!title) error = 'The title is empty.';
else if (!answer) error = 'The answer is empty.';
else if (answer.length > 4000) error = 'The answer is too long (limit 4000 characters).';
return { json: { record: { p_item_id: k.id, p_version: k.version, p_ok: !error, p_error: error } } };
