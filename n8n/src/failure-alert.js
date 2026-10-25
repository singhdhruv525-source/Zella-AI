// Zella - Failure Alert: turn an n8n failure into one platform alert. No customer data is copied; only the workflow, the step and a short error.
const j = $json || {};
const wf = String((j.workflow && j.workflow.name) || 'Unknown workflow').slice(0, 80);
const ex = j.execution && typeof j.execution === 'object' ? j.execution : {};
const err = ex.error && typeof ex.error === 'object' ? ex.error : (j.trigger && j.trigger.error) || {};
const step = String(ex.lastNodeExecuted || (j.trigger && 'trigger') || 'unknown step').slice(0, 80);
const msg = String(err.message || 'No message').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/(key|token|secret|authorization|bearer)\S*/gi, '[hidden]').slice(0, 200);
const runId = String(ex.id || '').slice(0, 40);
// Anything that sends to a customer or takes a call matters more than a background check.
const urgent = /SMS|Email|Follow-up|Outbound|Brain|Booking|Event Router|Meta Sender/i.test(wf);
return { json: { alert: {
  p_kind: 'workflow_failed',
  p_title: ('Automation failed: ' + wf).slice(0, 120),
  p_detail: ('Step "' + step + '": ' + msg + (runId ? ' (run ' + runId + ')' : '')).slice(0, 400),
  p_severity: urgent ? 'urgent' : 'warning',
  p_dedupe_key: (wf + '|' + step).slice(0, 160),
  p_meta: { workflow: wf, step, run_id: runId },
} } };
