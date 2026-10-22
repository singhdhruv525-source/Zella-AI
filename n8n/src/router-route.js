// Zella - Event Router: decide what to do with one claimed event.
// Output: { event, plan, problem }.
//   plan    = the database function to call and its arguments, or null.
//   problem = why there is no plan: 'missing_configuration' (no handler built yet)
//             or 'invalid_input' (the event is missing something it needs).
// An event with no handler is never marked as done. It goes to the dead-letter list so the gap is visible.
const e = $json;
const p = e.payload && typeof e.payload === 'object' ? e.payload : {};
const text = (v, max = 300) => (typeof v === 'string' ? v.trim().slice(0, max) : '');

const none = (problem, message) => ({ json: { event: e, plan: null, problem: { category: problem, message } } });
const run = (rpc, body, handler) => ({ json: { event: e, plan: { rpc, body, handler }, problem: null } });

switch (e.event_type) {
  case 'message.received': {
    if (text(p.channel) !== 'sms') return none('missing_configuration', 'No handler yet for ' + (text(p.channel) || 'this') + ' messages.');
    if (!text(p.from, 40) || !text(p.body, 1600)) return none('invalid_input', 'An inbound text needs "from" and "body".');
    return run('zella_handle_inbound_sms_keyword', { p_business_id: e.business_id, p_from: text(p.from, 40), p_body: text(p.body, 1600) }, 'inbound_sms_keywords');
  }
  case 'customer.opted_out': {
    const channel = text(p.channel, 20);
    if (!['sms', 'call', 'email', 'whatsapp'].includes(channel)) return none('invalid_input', 'channel must be sms, call, email or whatsapp.');
    if (!p.customer_id && !text(p.phone, 40) && !text(p.email, 200)) return none('invalid_input', 'An opt-out needs a customer_id, phone or email.');
    return run('zella_record_consent', {
      p_business_id: e.business_id, p_channel: channel, p_status: 'opted_out', p_source: 'system',
      p_customer_id: p.customer_id || null, p_phone: text(p.phone, 40) || null, p_email: text(p.email, 200) || null,
      p_purpose: p.purpose === 'transactional' ? 'transactional' : 'marketing',
      p_evidence: { event_id: e.id },
    }, 'record_opt_out');
  }
  case 'integration.disconnected': {
    const provider = text(p.provider, 60);
    if (!provider) return none('invalid_input', 'An integration event needs "provider".');
    return run('zella_platform_alert', {
      p_kind: 'integration_disconnected', p_title: provider + ' disconnected', p_detail: text(p.reason, 500) || null,
      p_severity: 'urgent', p_business_id: e.business_id, p_dedupe_key: provider, p_meta: { event_id: e.id },
    }, 'integration_alert');
  }
  case 'integration.reconnected': {
    const provider = text(p.provider, 60);
    if (!provider) return none('invalid_input', 'An integration event needs "provider".');
    return run('zella_resolve_platform_alerts', {
      p_kind: 'integration_disconnected', p_business_id: e.business_id, p_dedupe_key: provider, p_note: 'Reconnected',
    }, 'integration_resolved');
  }
  default:
    return none('missing_configuration', 'No handler has been built yet for ' + e.event_type + '.');
}
