// Zella - Event Router: turn what happened into a result for the execution log and the event.
// Temporary problems (rate limit, network, server error) are retried by the database.
// Everything else is permanent and goes to the dead-letter list for a person to review.
const route = $('Route').item.json;
const start = $('Start execution').item.json;
const startBody = start && start.body;
const executionId = typeof startBody === 'string' ? startBody : (startBody && startBody.data) || null;

let ok = false;
let category = null;
let error = null;
const steps = [{ step: 'route', handler: route.plan ? route.plan.handler : null }];

if (!route.plan) {
  category = route.problem.category;
  error = route.problem.message;
} else {
  const r = $json;
  const status = Number(r.statusCode);
  steps.push({ step: 'handler', rpc: route.plan.rpc, status });
  if (status >= 200 && status < 300) {
    ok = true;
    if (r.body && typeof r.body === 'object' && r.body.action) steps[1].action = r.body.action;
  } else {
    const detail = JSON.stringify(r.body ?? '');
    if (status === 429) category = 'rate_limited';
    else if (status === 408 || status === 504) category = 'provider_timeout';
    else if (status >= 500) category = 'temporary_network';
    else if (status === 401 || status === 403) category = 'authentication_failure';
    else if (/TENANT_MISMATCH|INVALID_BUSINESS/.test(detail)) category = 'tenant_mismatch';
    else if (/NOT_ALLOWED/.test(detail)) category = 'permission_failure';
    else category = 'invalid_input';
    error = 'The database call ' + route.plan.rpc + ' returned ' + status + '.';
  }
}

const temporary = ['rate_limited', 'provider_timeout', 'temporary_network', 'unknown_error'].includes(category);
return {
  json: {
    event_id: route.event.id,
    execution_id: executionId,
    ok,
    category,
    error,
    steps,
    needs_manual: !ok && !temporary,
  },
};
