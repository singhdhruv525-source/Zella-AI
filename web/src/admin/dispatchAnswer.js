// n8n's answer to the dispatcher's last hand over of a workflow, in plain words (OPS-17). Rows come from
// zella_admin_dispatch_responses (sql/zella_dispatch_response.sql). Pure, so node --test checks the wording.

// { tone, label } for one workflow's answer; null when nothing is known (the function isn't applied yet)
export function dispatchAnswer(row) {
  if (!row) return null;
  const answer = answerOf(row);
  // another request is still waiting for its answer (its order isn't known), and the label says so
  if (row.waiting && answer.kind !== "none") return { ...answer, tone: answer.tone === "success" ? "neutral" : answer.tone, label: `${answer.label}, another request is waiting`, pending: true };
  if (row.waiting) return { tone: "neutral", label: "Waiting for the answer", kind: "waiting" };
  return answer;
}

function answerOf(row) {
  const code = row.status_code;
  if (code >= 200 && code < 300) return { tone: "success", label: `Accepted (${code})`, kind: "accepted" };
  if (code === 401 || code === 403) return { tone: "danger", label: `Refused: wrong secret (${code})`, kind: "refused" };
  if (code === 404) return { tone: "danger", label: "Workflow not published (404)", kind: "not_published" };
  if (code) return { tone: "warning", label: `Answered ${code}`, kind: "other" };
  if (row.error) return { tone: "danger", label: `No answer: ${row.error}`, kind: "no_answer" };
  return { tone: "neutral", label: "Not recorded yet", kind: "none" };
}

// the answers keyed by workflow, from the reader's list (or an empty map)
export const answersByWorkflow = (rows) => new Map((Array.isArray(rows) ? rows : []).map((r) => [r.workflow, r]));
