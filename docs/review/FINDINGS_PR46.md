# CodeRabbit findings from singhdhruv525-source/Zella-AI#46 (n8n workflows and scripts)

Fix list, in the order CodeRabbit posted them. CodeRabbit fixes them on this branch; each fix is checked and re-reviewed before merge.

- [ ] `n8n/GO-LIVE.md:29` — Update the “Not built yet” list and setup steps.
- [ ] `n8n/README.md:3` — Update the workflow and test counts.
- [ ] `n8n/src/build.mjs:56` — Make the generated workflows not keep tokens in execution history.
- [ ] `n8n/src/build.mjs:457` — Require signatures for both Resend webhooks.
- [ ] `n8n/src/build.mjs:512` — Do not paste OAuth client secrets into workflow node parameters.
- [ ] `n8n/src/business-apply.js:7` — Bind the fallback business to the call.
- [ ] `n8n/src/calendar-pull-map.js:14` — Handle truncated list responses instead of silently replacing busy times with partial data.
- [ ] `n8n/src/calendar-sync-plan.js:3` — Do not save calendar execution data.
- [ ] `n8n/src/calendar-sync-plan.js:30` — Guard against an invalid date before `toISOString()`.
- [ ] `n8n/src/call-plan.js:27` — Guard the timezone so one bad value cannot stall the claimed call.
- [ ] `n8n/src/failure-alert.js:7` — Strengthen the redaction of secrets in the error message.
- [ ] `n8n/src/inbound-email-map.js:18` — Cap the HTML length before running the strip regexes.
- [ ] `n8n/src/inbound-email-plan.js:7` — Validate the webhook key before fetching the email.
- [ ] `n8n/src/meta-receive-plan.js:12` — Oversized or unreadable bodies are blocked from Meta's side with no distinguishing signal.
- [ ] `n8n/src/meta-send-plan.js:16` — WhatsApp templates are blocked when `text` is empty.
- [ ] `n8n/src/meta-send-plan.js:20` — Both WhatsApp branches run for every `kind`.
- [ ] `n8n/src/router-result.js:16` — Guard against a missing `route.problem`.
- [ ] `n8n/src/vapi-tool-plan.js:24` — Reuse the shared call-context helpers instead of copying the tenant-lookup logic.
- [ ] `n8n/src/vapi-tool-reply.js:5` — Check the `Log question` result before telling the caller the request was noted.
- [ ] `n8n/src/website-parse.js:9` — Decode `&amp;` last to avoid double decoding.
- [ ] `n8n/src/website-parse.js:39` — Fix quadratic regex backtracking on untrusted page bodies.
