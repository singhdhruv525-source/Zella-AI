// Zella - Event Gateway: answer a request that failed the checks. Nothing was stored.
return { json: { status: 400, body: { ok: false, error: 'invalid_event', details: $json.errors } } };
