# Zella automation checklist (338 items)

Item numbers and names come from the Zella AI Complete Automation Guide. Status is honest and conservative: nothing has run against a real provider yet.

- **Built**: the database part is applied and tested, and (where it needs n8n) the unpublished n8n workflow exists and its logic is tested. Nothing runs until go-live and live provider keys.
- **Partly**: some of the item works; the missing part is noted by the module section in `n8n/README.md` or the Not built items nearby.
- **Rules ready**: database logic exists; the n8n workflow, provider connection or screen is missing.
- **Not built**: nothing yet.

Items are served by a small set of shared workflows (see `n8n/README.md`), not one workflow per item. Many industry items (196 to 254) are configurations of the shared appointment, message, assignment and reminder engines; the 98 starter automation rows per industry are seeded in the database.

**Totals:** Built 254, Partly 5, Rules ready 23, Not built 56.


## 1. Calls and AI receptionist (16) — Built 12, Partly 0, Rules ready 4, Not built 0

| # | Automation | Status |
|---|---|---|
| 1 | Trigger | Built |
| 2 | Logic | Rules ready |
| 3 | Action | Built |
| 4 | Verification and recovery | Rules ready |
| 5 | Call outcome detection | Built |
| 6 | Missed-call detection | Rules ready |
| 7 | After-hours and holiday handling | Built |
| 8 | Human transfer | Built |
| 9 | Transfer failure recovery | Built |
| 10 | Callback request capture | Built |
| 11 | Voicemail and message taking | Built |
| 12 | Emergency escalation | Built |
| 13 | AI failure recovery | Rules ready |
| 14 | Call summary and CRM logging | Built |
| 15 | Repeat caller recognition | Built |
| 16 | Unanswered question tracking | Built |

## 2. Callbacks and follow-ups (14) — Built 12, Partly 0, Rules ready 2, Not built 0

| # | Automation | Status |
|---|---|---|
| 17 | Callback task creation | Rules ready |
| 18 | Callback scheduling | Rules ready |
| 19 | Callback reminders | Built |
| 20 | Callback retries | Built |
| 21 | No-answer and busy handling | Built |
| 22 | Configurable retry limits | Built |
| 23 | Callback reassignment | Built |
| 24 | Overdue callback escalation | Built |
| 25 | Callback rescheduling | Built |
| 26 | Outcome logging | Built |
| 27 | Callback cancellation | Built |
| 28 | Daily callback summary | Built |
| 29 | Duplicate callback prevention | Built |
| 30 | Callback recovery | Built |

## 3. Appointments and calendars (20) — Built 14, Partly 2, Rules ready 4, Not built 0

| # | Automation | Status |
|---|---|---|
| 31 | Booking acknowledgment | Rules ready |
| 32 | Availability checking | Built |
| 33 | Appointment booking | Built |
| 34 | Confirmation delivery | Built |
| 35 | Appointment reminders | Built |
| 36 | Customer confirmation | Built |
| 37 | No-response follow-up | Built |
| 38 | Rescheduling | Built |
| 39 | Cancellation handling | Built |
| 40 | Old reminder invalidation | Built |
| 41 | Calendar synchronization | Partly |
| 42 | Staff appointment notifications | Rules ready |
| 43 | Waitlist and open-slot recovery | Built |
| 44 | Check-in and attendance | Rules ready |
| 45 | No-show follow-up | Built |
| 46 | Appointment completion | Rules ready |
| 47 | Thank-you message | Built |
| 48 | Feedback and review request | Built |
| 49 | Repeat booking and recall | Built |
| 50 | Booking failure and conflict recovery | Partly |

## 4. Email automation (15) — Built 15, Partly 0, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 51 | Transactional email | Built |
| 52 | Booking follow-up email | Built |
| 53 | Lead follow-up email | Built |
| 54 | Callback email | Built |
| 55 | Quote follow-up email | Built |
| 56 | Change notification email | Built |
| 57 | Business onboarding email | Built |
| 58 | Service completion email | Built |
| 59 | Feedback and renewal email | Built |
| 60 | Inbound email processing | Built |
| 61 | Reply classification | Built |
| 62 | CRM email linking | Built |
| 63 | Bounce and delivery failure handling | Built |
| 64 | Unsubscribe processing | Built |
| 65 | Email templates and summaries | Built |

## 5. SMS and messaging automation (15) — Built 15, Partly 0, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 66 | Transactional SMS | Built |
| 67 | Appointment SMS | Built |
| 68 | Callback SMS | Built |
| 69 | Missed-call SMS | Built |
| 70 | Lead follow-up SMS | Built |
| 71 | Inbound reply processing | Built |
| 72 | Delivery receipt handling | Built |
| 73 | SMS failure recovery | Built |
| 74 | Consent and opt-out management | Built |
| 75 | STOP and HELP handling | Built |
| 76 | Quiet hours and contact limits | Built |
| 77 | Human handover | Built |
| 78 | Duplicate message prevention | Built |
| 79 | SMS templates | Built |
| 80 | Channel preferences | Built |

## 6. Leads and sales CRM (20) — Built 19, Partly 0, Rules ready 1, Not built 0

| # | Automation | Status |
|---|---|---|
| 81 | Website lead capture | Built |
| 82 | Social lead capture | Built |
| 83 | Lead attribution | Built |
| 84 | Duplicate lead detection | Built |
| 85 | Lead qualification | Built |
| 86 | Lead prioritization | Built |
| 87 | Lead assignment | Built |
| 88 | Round-robin assignment | Built |
| 89 | New-lead notifications | Built |
| 90 | Response-time monitoring | Rules ready |
| 91 | Lead follow-up sequences | Built |
| 92 | Overdue lead escalation | Built |
| 93 | Quote and proposal follow-up | Built |
| 94 | Stale-lead reactivation | Built |
| 95 | Lead-stage updates | Built |
| 96 | Conversion tracking | Built |
| 97 | Lost-lead tracking | Built |
| 98 | Lead reassignment | Built |
| 99 | Follow-up suppression after conversion | Built |
| 100 | Campaign reporting | Built |

## 7. Customer lifecycle automation (15) — Built 15, Partly 0, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 101 | Customer creation | Built |
| 102 | Customer updates | Built |
| 103 | Identity matching | Built |
| 104 | Duplicate review | Built |
| 105 | Welcome messages | Built |
| 106 | Service reminders | Built |
| 107 | Repeat-service workflows | Built |
| 108 | Inactivity reactivation | Built |
| 109 | Complaint routing | Built |
| 110 | Preference management | Built |
| 111 | Correction requests | Built |
| 112 | Retention workflows | Built |
| 113 | Interaction timeline | Built |
| 114 | Data-rights requests | Built |
| 115 | Opt-out enforcement | Built |

## 8. Meta automation (16) — Built 15, Partly 1, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 116 | Facebook Lead Ads integration | Built |
| 117 | Lead import and CRM sync | Built |
| 118 | Instagram DM handling | Built |
| 119 | Messenger handling | Built |
| 120 | WhatsApp Business handling | Built |
| 121 | Social lead qualification | Built |
| 122 | Social conversation assignment | Built |
| 123 | Social appointment flow | Built |
| 124 | Eligible comment-to-private-reply workflow | Built |
| 125 | WhatsApp template management | Partly |
| 126 | Human takeover | Built |
| 127 | Social attribution | Built |
| 128 | Cross-channel duplicate prevention | Built |
| 129 | Permission and token monitoring | Built |
| 130 | API failure recovery | Built |
| 131 | Meta connection health | Built |

## 9. Website leads and chat (15) — Built 15, Partly 0, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 132 | Contact-form capture | Built |
| 133 | Quote-request capture | Built |
| 134 | Appointment-request capture | Built |
| 135 | Callback-request capture | Built |
| 136 | Website-chat lead capture | Built |
| 137 | Consent-based newsletter signup | Built |
| 138 | Spam and validation checks | Built |
| 139 | Lead matching and deduplication | Built |
| 140 | Source tracking | Built |
| 141 | Submission acknowledgment | Built |
| 142 | Lead qualification | Built |
| 143 | Assignment and notification | Built |
| 144 | Callback or booking initiation | Built |
| 145 | Failure alerting | Built |
| 146 | Conversion tracking | Built |

## 10. Website knowledge automation (23) — Built 22, Partly 0, Rules ready 1, Not built 0

| # | Automation | Status |
|---|---|---|
| 147 | Initial website import | Built |
| 148 | Approved-page crawling | Built |
| 149 | Sitemap discovery | Built |
| 150 | Service extraction | Built |
| 151 | Product extraction | Built |
| 152 | FAQ extraction | Built |
| 153 | Hours extraction | Built |
| 154 | Price extraction | Built |
| 155 | Policy extraction | Built |
| 156 | Scheduled synchronization | Built |
| 157 | Content change detection | Built |
| 158 | New-page detection | Built |
| 159 | Deleted-page detection | Built |
| 160 | Broken-link detection | Built |
| 161 | Conflicting-information detection | Built |
| 162 | Approval queue | Rules ready |
| 163 | Knowledge version history | Built |
| 164 | Controlled publishing and rollback | Built |
| 165 | Stale-knowledge alerts | Built |
| 166 | AI knowledge refresh | Built |
| 167 | Unanswered-question analysis | Built |
| 168 | Knowledge-gap reporting | Built |
| 169 | Tenant-isolated knowledge | Built |

## 11. AI quality and knowledge maintenance (12) — Built 11, Partly 0, Rules ready 0, Not built 1

| # | Automation | Status |
|---|---|---|
| 170 | Low-confidence escalation | Built |
| 171 | Repeated unanswered-question detection | Built |
| 172 | Incorrect-answer reporting | Built |
| 173 | Source validation | Built |
| 174 | Transfer-failure monitoring | Built |
| 175 | Configuration versioning | Built |
| 176 | Configuration review | Built |
| 177 | Rollback | Built |
| 178 | Response sampling | Built |
| 179 | AI performance summaries | Built |
| 180 | Retrieval failure handling | Not built |
| 181 | FAQ maintenance | Built |

## 12. Staff and team operations (14) — Built 12, Partly 0, Rules ready 2, Not built 0

| # | Automation | Status |
|---|---|---|
| 182 | Work assignment | Built |
| 183 | Workload-aware routing | Built |
| 184 | Staff invitations | Rules ready |
| 185 | Staff availability | Built |
| 186 | Unassigned-work alerts | Built |
| 187 | Overdue-task alerts | Built |
| 188 | Appointment notifications | Rules ready |
| 189 | Shift handover | Built |
| 190 | Absence reassignment | Built |
| 191 | Manager escalation | Built |
| 192 | Human takeover controls | Built |
| 193 | Escalation acknowledgment | Built |
| 194 | Daily team summary | Built |
| 195 | Offboarding and access revocation | Built |

## 13. Industry-specific workflows (59) — Built 4, Partly 0, Rules ready 0, Not built 55

| # | Automation | Status |
|---|---|---|
| 196 | Automotive — repair status | Not built |
| 197 | Automotive — estimate approval | Not built |
| 198 | Automotive — pickup | Not built |
| 199 | Automotive — maintenance | Not built |
| 200 | Beauty & Salon — stylist bookings | Not built |
| 201 | Beauty & Salon — waitlist | Built |
| 202 | Beauty & Salon — rebooking | Not built |
| 203 | Beauty & Salon — membership renewal | Not built |
| 204 | Dental — patient recall | Not built |
| 205 | Dental — reminders | Built |
| 206 | Dental — administrative follow-up | Not built |
| 207 | E-commerce — order updates | Not built |
| 208 | E-commerce — returns | Not built |
| 209 | E-commerce — delivery | Not built |
| 210 | E-commerce — post-purchase | Not built |
| 211 | Education — admissions | Not built |
| 212 | Education — counselling | Not built |
| 213 | Education — document reminders | Not built |
| 214 | Electrical — emergency intake | Not built |
| 215 | Electrical — dispatch | Not built |
| 216 | Electrical — estimates | Not built |
| 217 | Financial Services — consultation | Not built |
| 218 | Financial Services — application | Not built |
| 219 | Financial Services — renewal | Not built |
| 220 | Fitness — trial booking | Not built |
| 221 | Fitness — class reminders | Built |
| 222 | Fitness — membership | Not built |
| 223 | Healthcare — administration | Not built |
| 224 | Healthcare — referrals | Not built |
| 225 | Healthcare — appointments | Built |
| 226 | Home Services — job scheduling | Not built |
| 227 | Home Services — dispatch | Not built |
| 228 | Home Services — repeat service | Not built |
| 229 | HVAC — maintenance | Not built |
| 230 | HVAC — seasonal workflows | Not built |
| 231 | HVAC — installation follow-up | Not built |
| 232 | Legal — intake | Not built |
| 233 | Legal — consultation | Not built |
| 234 | Legal — deadline reminders | Not built |
| 235 | Other — configurable workflows | Not built |
| 236 | Plumbing — emergency routing | Not built |
| 237 | Plumbing — dispatch | Not built |
| 238 | Plumbing — job follow-up | Not built |
| 239 | Professional Services — proposals | Not built |
| 240 | Professional Services — onboarding | Not built |
| 241 | Professional Services — project milestones | Not built |
| 242 | Real Estate — callbacks | Not built |
| 243 | Real Estate — viewings | Not built |
| 244 | Real Estate — deal tracking | Not built |
| 245 | Restaurant — reservations | Not built |
| 246 | Restaurant — waitlists | Not built |
| 247 | Restaurant — events | Not built |
| 248 | Travel — itinerary | Not built |
| 249 | Travel — booking updates | Not built |
| 250 | Travel — pre-departure | Not built |
| 251 | Hospitality — guest requests | Not built |
| 252 | Hospitality — arrival | Not built |
| 253 | Hospitality — checkout | Not built |
| 254 | Hospitality — feedback | Not built |

## 14. Integration monitoring and recovery (15) — Built 11, Partly 2, Rules ready 2, Not built 0

| # | Automation | Status |
|---|---|---|
| 255 | Connection testing | Built |
| 256 | Token-expiry monitoring | Built |
| 257 | Disconnect alerts | Built |
| 258 | OAuth reconnection | Partly |
| 259 | Timeout and rate-limit handling | Built |
| 260 | Transient-error retry | Built |
| 261 | Permanent-error escalation | Built |
| 262 | Invalid-payload handling | Built |
| 263 | Webhook signature verification | Partly |
| 264 | Duplicate webhook protection | Built |
| 265 | Scheduled reconciliation | Built |
| 266 | Stuck-execution detection | Built |
| 267 | Dead-letter handling | Built |
| 268 | Manual retry | Rules ready |
| 269 | Integration health summaries | Rules ready |

## 15. Automation engine reliability (16) — Built 16, Partly 0, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 270 | Central event router | Built |
| 271 | Event schema validation | Built |
| 272 | Durable job storage | Built |
| 273 | Idempotency | Built |
| 274 | Workflow versioning | Built |
| 275 | Audit logging | Built |
| 276 | Retry and backoff | Built |
| 277 | Execution locks | Built |
| 278 | Cancelled-job invalidation | Built |
| 279 | Failure notifications | Built |
| 280 | Orphaned-task detection | Built |
| 281 | Queue-backlog monitoring | Built |
| 282 | Restart recovery | Built |
| 283 | Configuration validation | Built |
| 284 | Test mode | Built |
| 285 | Manual recovery controls | Built |

## 16. Notifications and reporting (14) — Built 14, Partly 0, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 286 | In-app notifications | Built |
| 287 | Owner email alerts | Built |
| 288 | Staff SMS alerts | Built |
| 289 | Daily summaries | Built |
| 290 | Weekly summaries | Built |
| 291 | Missed-call reports | Built |
| 292 | Callback reports | Built |
| 293 | Appointment reports | Built |
| 294 | Lead reports | Built |
| 295 | Failure and connection reports | Built |
| 296 | Knowledge-gap reports | Built |
| 297 | Unassigned-work reports | Built |
| 298 | KPI alerts | Built |
| 299 | Notification grouping and deduplication | Built |

## 17. Subscription and platform operations (12) — Built 8, Partly 0, Rules ready 4, Not built 0

| # | Automation | Status |
|---|---|---|
| 300 | Onboarding completion | Built |
| 301 | Provisioning recovery | Rules ready |
| 302 | Integration setup reminders | Built |
| 303 | Payment-failure handling | Built |
| 304 | Renewal processing | Built |
| 305 | Cancellation handling | Rules ready |
| 306 | Payment reversal handling | Built |
| 307 | Plan entitlement updates | Built |
| 308 | Suspension and reactivation | Rules ready |
| 309 | Incident notifications | Rules ready |
| 310 | Administrative audit | Built |
| 311 | Plan entitlement checks | Built |

## 18. Security, consent and governance (15) — Built 12, Partly 0, Rules ready 3, Not built 0

| # | Automation | Status |
|---|---|---|
| 312 | UUID and identifier validation | Built |
| 313 | Tenant isolation | Rules ready |
| 314 | Permission enforcement | Rules ready |
| 315 | Consent validation | Built |
| 316 | Opt-out enforcement | Built |
| 317 | Quiet-hour enforcement | Built |
| 318 | Sensitive-action approval | Built |
| 319 | Replay protection | Built |
| 320 | Rate limiting | Built |
| 321 | Sensitive-data redaction | Built |
| 322 | SSRF protection | Built |
| 323 | Data-rights workflow | Built |
| 324 | Recording and transcript access control | Built |
| 325 | Tenant-leak testing | Built |
| 326 | Privileged-action audit | Rules ready |

## 19. Analytics and optimization (12) — Built 12, Partly 0, Rules ready 0, Not built 0

| # | Automation | Status |
|---|---|---|
| 327 | Success and failure metrics | Built |
| 328 | Message-delivery metrics | Built |
| 329 | Callback completion metrics | Built |
| 330 | Appointment outcome metrics | Built |
| 331 | Lead response and conversion metrics | Built |
| 332 | Follow-up completion metrics | Built |
| 333 | Integration uptime metrics | Built |
| 334 | Knowledge-sync metrics | Built |
| 335 | Usage and cost metrics | Built |
| 336 | Dashboard filtering | Built |
| 337 | Anomaly detection | Built |
| 338 | Workflow effectiveness analysis | Built |
