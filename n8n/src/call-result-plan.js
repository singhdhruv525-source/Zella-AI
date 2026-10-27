// Zella - Call Results: turn one Vapi call event into one database call (the same code the voice-rules edge function
// runs; build.mjs inlines web/supabase/functions/_shared/vapi-call-events.js here).
//   status-update -> status (ringing, in-progress, forwarding, ended; applied once and in order)
//   end-of-call-report for a call Zella placed (metadata zella_source / zella_id, set by Outbound Calls) -> record
//   end-of-call-report for a customer's call to the business -> inbound (call wrap-up)
// Anything else is ignored (record, inbound and status all null).
__VAPI_CALL_EVENTS__
const body = $json.body && typeof $json.body === 'object' ? $json.body : {};
return { json: planCallEvent(body.message) };
