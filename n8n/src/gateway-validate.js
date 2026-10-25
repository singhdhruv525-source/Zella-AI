// Zella - Event Gateway: check the incoming request before anything is stored.
// Runs once for each item. Input: the webhook item ({ body }).
const EVENT_TYPES = __EVENT_TYPES__;
const SOURCES = ['database', 'vapi', 'telnyx', 'website', 'meta', 'email', 'calendar', 'staff', 'n8n', 'billing', 'system'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const b = $json.body;
const errors = [];
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

if (!isObject(b)) {
  errors.push('The request body must be a JSON object.');
} else {
  if (typeof b.business_id !== 'string' || !UUID.test(b.business_id)) errors.push('business_id must be a valid UUID.');
  if (!EVENT_TYPES.includes(b.event_type)) errors.push('event_type is not a recognised Zella event.');
  if (!SOURCES.includes(b.source)) errors.push('source is not recognised.');
  if (typeof b.idempotency_key !== 'string' || b.idempotency_key.length < 8 || b.idempotency_key.length > 200) {
    errors.push('idempotency_key must be 8 to 200 characters.');
  }
  if (b.payload !== undefined && !isObject(b.payload)) errors.push('payload must be an object.');
  if (isObject(b.payload) && JSON.stringify(b.payload).length > 60000) errors.push('payload is too large.');
  if (b.provider_event_id !== undefined && (typeof b.provider_event_id !== 'string' || b.provider_event_id.length > 200)) {
    errors.push('provider_event_id must be a string up to 200 characters.');
  }
  for (const key of ['correlation_id', 'causation_id']) {
    if (b[key] !== undefined && b[key] !== null && (typeof b[key] !== 'string' || !UUID.test(b[key]))) errors.push(key + ' must be a valid UUID.');
  }
}

const valid = errors.length === 0;
return {
  json: {
    valid,
    errors,
    rpc: valid
      ? {
          p_business_id: b.business_id,
          p_event_type: b.event_type,
          p_source: b.source,
          p_idempotency_key: b.idempotency_key,
          p_payload: b.payload ?? {},
          p_provider_event_id: b.provider_event_id ?? null,
          p_correlation_id: b.correlation_id ?? null,
          p_causation_id: b.causation_id ?? null,
        }
      : null,
  },
};
