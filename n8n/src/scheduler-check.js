// Zella - Schedulers: read the result of one timed database job.
// A failed job produces an alert (grouped by job name, so repeats do not pile up).
const job = '__JOB__';
const status = Number($json.statusCode);
const ok = status >= 200 && status < 300;
const count = ok && typeof $json.body === 'number' ? $json.body : null;
return {
  json: {
    job,
    ok,
    status,
    count,
    alert: ok ? null : {
      p_kind: 'scheduler_failed',
      p_title: 'Scheduled job failed: ' + job,
      p_detail: 'The database call ' + job + ' returned ' + status + '.',
      p_severity: 'warning',
      p_business_id: null,
      p_dedupe_key: job,
      p_meta: { job, status },
    },
  },
};
