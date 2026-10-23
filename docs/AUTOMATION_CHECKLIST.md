# Zella automation checklist (338 items)

Item numbers and names come from the Zella AI Complete Automation Guide. Status is honest and conservative: nothing has run against a real provider yet.

- **Built**: the database part is applied and tested, and (where it needs n8n) the unpublished n8n workflow exists and its logic is tested. Nothing runs until go-live and live provider keys.
- **Partly**: some of the item works; the missing part is noted by the module section in `n8n/README.md` or the Not built items nearby.
- **Rules ready**: database logic exists; the n8n workflow, provider connection or screen is missing.
- **Not built**: nothing yet.

Items are served by a small set of shared workflows (see `n8n/README.md`), not one workflow per item. Many industry items (196 to 254) are configurations of the shared appointment, message, assignment and reminder engines; the 98 starter automation rows per industry are seeded in the database.

**Totals:** Built 70, Partly 29, Rules ready 36, Not built 203.


## 1. Calls and AI receptionist (16) — Built 3, Partly 4, Rules ready 3, Not built 6

| # | Automation | Status |
|---|---|---|
| 1 | Trigger | Not built |
| 2 | Logic | Rules ready |
| 3 | Action | Built |
| 4 | Verification and recovery | Rules ready |
| 5 | Call outcome detection | Partly |
| 6 | Missed-call detection | Rules ready |
| 7 | After-hours and holiday handling | Not built |
| 8 | Human transfer | Not built |
| 9 | Transfer failure recovery | Built |
| 10 | Callback request capture | Partly |
| 11 | Voicemail and message taking | Not built |
| 12 | Emergency escalation | Not built |
| 13 | AI failure recovery | Not built |
| 14 | Call summary and CRM logging | Partly |
| 15 | Repeat caller recognition | Partly |
| 16 | Unanswered question tracking | Built |

## 2. Callbacks and follow-ups (14) — Built 7, Partly 1, Rules ready 2, Not built 4

| # | Automation | Status |
|---|---|---|
| 17 | Callback task creation | Rules ready |
| 18 | Callback scheduling | Rules ready |
| 19 | Callback reminders | Partly |
| 20 | Callback retries | Built |
| 21 | No-answer and busy handling | Built |
| 22 | Configurable retry limits | Built |
| 23 | Callback reassignment | Not built |
| 24 | Overdue callback escalation | Built |
| 25 | Callback rescheduling | Not built |
| 26 | Outcome logging | Built |
| 27 | Callback cancellation | Not built |
| 28 | Daily callback summary | Not built |
| 29 | Duplicate callback prevention | Built |
| 30 | Callback recovery | Built |

## 3. Appointments and calendars (20) — Built 9, Partly 3, Rules ready 5, Not built 3

| # | Automation | Status |
|---|---|---|
| 31 | Booking acknowledgment | Rules ready |
| 32 | Availability checking | Built |
| 33 | Appointment booking | Built |
| 34 | Confirmation delivery | Partly |
| 35 | Appointment reminders | Built |
| 36 | Customer confirmation | Rules ready |
| 37 | No-response follow-up | Not built |
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
| 48 | Feedback and review request | Not built |
| 49 | Repeat booking and recall | Not built |
| 50 | Booking failure and conflict recovery | Partly |

## 4. Email automation (15) — Built 3, Partly 3, Rules ready 1, Not built 8

| # | Automation | Status |
|---|---|---|
| 51 | Transactional email | Partly |
| 52 | Booking follow-up email | Not built |
| 53 | Lead follow-up email | Partly |
| 54 | Callback email | Built |
| 55 | Quote follow-up email | Built |
| 56 | Change notification email | Not built |
| 57 | Business onboarding email | Not built |
| 58 | Service completion email | Not built |
| 59 | Feedback and renewal email | Not built |
| 60 | Inbound email processing | Not built |
| 61 | Reply classification | Not built |
| 62 | CRM email linking | Not built |
| 63 | Bounce and delivery failure handling | Built |
| 64 | Unsubscribe processing | Rules ready |
| 65 | Email templates and summaries | Partly |

## 5. SMS and messaging automation (15) — Built 9, Partly 4, Rules ready 0, Not built 2

| # | Automation | Status |
|---|---|---|
| 66 | Transactional SMS | Built |
| 67 | Appointment SMS | Built |
| 68 | Callback SMS | Built |
| 69 | Missed-call SMS | Built |
| 70 | Lead follow-up SMS | Partly |
| 71 | Inbound reply processing | Partly |
| 72 | Delivery receipt handling | Not built |
| 73 | SMS failure recovery | Partly |
| 74 | Consent and opt-out management | Built |
| 75 | STOP and HELP handling | Built |
| 76 | Quiet hours and contact limits | Built |
| 77 | Human handover | Not built |
| 78 | Duplicate message prevention | Built |
| 79 | SMS templates | Built |
| 80 | Channel preferences | Partly |

## 6. Leads and sales CRM (20) — Built 2, Partly 2, Rules ready 3, Not built 13

| # | Automation | Status |
|---|---|---|
| 81 | Website lead capture | Not built |
| 82 | Social lead capture | Not built |
| 83 | Lead attribution | Not built |
| 84 | Duplicate lead detection | Not built |
| 85 | Lead qualification | Not built |
| 86 | Lead prioritization | Not built |
| 87 | Lead assignment | Not built |
| 88 | Round-robin assignment | Not built |
| 89 | New-lead notifications | Rules ready |
| 90 | Response-time monitoring | Rules ready |
| 91 | Lead follow-up sequences | Partly |
| 92 | Overdue lead escalation | Built |
| 93 | Quote and proposal follow-up | Built |
| 94 | Stale-lead reactivation | Partly |
| 95 | Lead-stage updates | Rules ready |
| 96 | Conversion tracking | Not built |
| 97 | Lost-lead tracking | Not built |
| 98 | Lead reassignment | Not built |
| 99 | Follow-up suppression after conversion | Not built |
| 100 | Campaign reporting | Not built |

## 7. Customer lifecycle automation (15) — Built 2, Partly 0, Rules ready 4, Not built 9

| # | Automation | Status |
|---|---|---|
| 101 | Customer creation | Rules ready |
| 102 | Customer updates | Rules ready |
| 103 | Identity matching | Built |
| 104 | Duplicate review | Rules ready |
| 105 | Welcome messages | Not built |
| 106 | Service reminders | Not built |
| 107 | Repeat-service workflows | Not built |
| 108 | Inactivity reactivation | Not built |
| 109 | Complaint routing | Not built |
| 110 | Preference management | Not built |
| 111 | Correction requests | Not built |
| 112 | Retention workflows | Not built |
| 113 | Interaction timeline | Rules ready |
| 114 | Data-rights requests | Not built |
| 115 | Opt-out enforcement | Built |

## 8. Meta automation (16) — Built 0, Partly 0, Rules ready 0, Not built 16

| # | Automation | Status |
|---|---|---|
| 116 | Facebook Lead Ads integration | Not built |
| 117 | Lead import and CRM sync | Not built |
| 118 | Instagram DM handling | Not built |
| 119 | Messenger handling | Not built |
| 120 | WhatsApp Business handling | Not built |
| 121 | Social lead qualification | Not built |
| 122 | Social conversation assignment | Not built |
| 123 | Social appointment flow | Not built |
| 124 | Eligible comment-to-private-reply workflow | Not built |
| 125 | WhatsApp template management | Not built |
| 126 | Human takeover | Not built |
| 127 | Social attribution | Not built |
| 128 | Cross-channel duplicate prevention | Not built |
| 129 | Permission and token monitoring | Not built |
| 130 | API failure recovery | Not built |
| 131 | Meta connection health | Not built |

## 9. Website leads and chat (15) — Built 0, Partly 0, Rules ready 0, Not built 15

| # | Automation | Status |
|---|---|---|
| 132 | Contact-form capture | Not built |
| 133 | Quote-request capture | Not built |
| 134 | Appointment-request capture | Not built |
| 135 | Callback-request capture | Not built |
| 136 | Website-chat lead capture | Not built |
| 137 | Consent-based newsletter signup | Not built |
| 138 | Spam and validation checks | Not built |
| 139 | Lead matching and deduplication | Not built |
| 140 | Source tracking | Not built |
| 141 | Submission acknowledgment | Not built |
| 142 | Lead qualification | Not built |
| 143 | Assignment and notification | Not built |
| 144 | Callback or booking initiation | Not built |
| 145 | Failure alerting | Not built |
| 146 | Conversion tracking | Not built |

## 10. Website knowledge automation (23) — Built 1, Partly 1, Rules ready 4, Not built 17

| # | Automation | Status |
|---|---|---|
| 147 | Initial website import | Not built |
| 148 | Approved-page crawling | Not built |
| 149 | Sitemap discovery | Not built |
| 150 | Service extraction | Not built |
| 151 | Product extraction | Not built |
| 152 | FAQ extraction | Not built |
| 153 | Hours extraction | Not built |
| 154 | Price extraction | Not built |
| 155 | Policy extraction | Not built |
| 156 | Scheduled synchronization | Not built |
| 157 | Content change detection | Not built |
| 158 | New-page detection | Not built |
| 159 | Deleted-page detection | Not built |
| 160 | Broken-link detection | Not built |
| 161 | Conflicting-information detection | Not built |
| 162 | Approval queue | Rules ready |
| 163 | Knowledge version history | Not built |
| 164 | Controlled publishing and rollback | Partly |
| 165 | Stale-knowledge alerts | Not built |
| 166 | AI knowledge refresh | Built |
| 167 | Unanswered-question analysis | Rules ready |
| 168 | Knowledge-gap reporting | Rules ready |
| 169 | Tenant-isolated knowledge | Rules ready |

## 11. AI quality and knowledge maintenance (12) — Built 2, Partly 0, Rules ready 1, Not built 9

| # | Automation | Status |
|---|---|---|
| 170 | Low-confidence escalation | Not built |
| 171 | Repeated unanswered-question detection | Rules ready |
| 172 | Incorrect-answer reporting | Not built |
| 173 | Source validation | Not built |
| 174 | Transfer-failure monitoring | Built |
| 175 | Configuration versioning | Not built |
| 176 | Configuration review | Not built |
| 177 | Rollback | Not built |
| 178 | Response sampling | Not built |
| 179 | AI performance summaries | Not built |
| 180 | Retrieval failure handling | Not built |
| 181 | FAQ maintenance | Built |

## 12. Staff and team operations (14) — Built 0, Partly 2, Rules ready 2, Not built 10

| # | Automation | Status |
|---|---|---|
| 182 | Work assignment | Not built |
| 183 | Workload-aware routing | Not built |
| 184 | Staff invitations | Rules ready |
| 185 | Staff availability | Not built |
| 186 | Unassigned-work alerts | Not built |
| 187 | Overdue-task alerts | Partly |
| 188 | Appointment notifications | Rules ready |
| 189 | Shift handover | Not built |
| 190 | Absence reassignment | Not built |
| 191 | Manager escalation | Partly |
| 192 | Human takeover controls | Not built |
| 193 | Escalation acknowledgment | Not built |
| 194 | Daily team summary | Not built |
| 195 | Offboarding and access revocation | Not built |

## 13. Industry-specific workflows (59) — Built 0, Partly 4, Rules ready 0, Not built 55

| # | Automation | Status |
|---|---|---|
| 196 | Automotive — repair status | Not built |
| 197 | Automotive — estimate approval | Not built |
| 198 | Automotive — pickup | Not built |
| 199 | Automotive — maintenance | Not built |
| 200 | Beauty & Salon — stylist bookings | Not built |
| 201 | Beauty & Salon — waitlist | Partly |
| 202 | Beauty & Salon — rebooking | Not built |
| 203 | Beauty & Salon — membership renewal | Not built |
| 204 | Dental — patient recall | Not built |
| 205 | Dental — reminders | Partly |
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
| 221 | Fitness — class reminders | Partly |
| 222 | Fitness — membership | Not built |
| 223 | Healthcare — administration | Not built |
| 224 | Healthcare — referrals | Not built |
| 225 | Healthcare — appointments | Partly |
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

## 14. Integration monitoring and recovery (15) — Built 7, Partly 2, Rules ready 2, Not built 4

| # | Automation | Status |
|---|---|---|
| 255 | Connection testing | Not built |
| 256 | Token-expiry monitoring | Not built |
| 257 | Disconnect alerts | Built |
| 258 | OAuth reconnection | Not built |
| 259 | Timeout and rate-limit handling | Partly |
| 260 | Transient-error retry | Built |
| 261 | Permanent-error escalation | Built |
| 262 | Invalid-payload handling | Built |
| 263 | Webhook signature verification | Partly |
| 264 | Duplicate webhook protection | Built |
| 265 | Scheduled reconciliation | Not built |
| 266 | Stuck-execution detection | Built |
| 267 | Dead-letter handling | Built |
| 268 | Manual retry | Rules ready |
| 269 | Integration health summaries | Rules ready |

## 15. Automation engine reliability (16) — Built 12, Partly 3, Rules ready 1, Not built 0

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
| 279 | Failure notifications | Partly |
| 280 | Orphaned-task detection | Partly |
| 281 | Queue-backlog monitoring | Built |
| 282 | Restart recovery | Built |
| 283 | Configuration validation | Partly |
| 284 | Test mode | Built |
| 285 | Manual recovery controls | Rules ready |

## 16. Notifications and reporting (14) — Built 5, Partly 0, Rules ready 0, Not built 9

| # | Automation | Status |
|---|---|---|
| 286 | In-app notifications | Built |
| 287 | Owner email alerts | Built |
| 288 | Staff SMS alerts | Not built |
| 289 | Daily summaries | Built |
| 290 | Weekly summaries | Built |
| 291 | Missed-call reports | Not built |
| 292 | Callback reports | Not built |
| 293 | Appointment reports | Not built |
| 294 | Lead reports | Not built |
| 295 | Failure and connection reports | Not built |
| 296 | Knowledge-gap reports | Not built |
| 297 | Unassigned-work reports | Not built |
| 298 | KPI alerts | Not built |
| 299 | Notification grouping and deduplication | Built |

## 17. Subscription and platform operations (12) — Built 2, Partly 0, Rules ready 4, Not built 6

| # | Automation | Status |
|---|---|---|
| 300 | Onboarding completion | Built |
| 301 | Provisioning recovery | Not built |
| 302 | Integration setup reminders | Not built |
| 303 | Payment-failure handling | Built |
| 304 | Renewal processing | Not built |
| 305 | Cancellation handling | Rules ready |
| 306 | Payment reversal handling | Not built |
| 307 | Plan entitlement updates | Not built |
| 308 | Suspension and reactivation | Rules ready |
| 309 | Incident notifications | Rules ready |
| 310 | Administrative audit | Rules ready |
| 311 | Plan entitlement checks | Not built |

## 18. Security, consent and governance (15) — Built 6, Partly 0, Rules ready 3, Not built 6

| # | Automation | Status |
|---|---|---|
| 312 | UUID and identifier validation | Built |
| 313 | Tenant isolation | Rules ready |
| 314 | Permission enforcement | Rules ready |
| 315 | Consent validation | Built |
| 316 | Opt-out enforcement | Built |
| 317 | Quiet-hour enforcement | Built |
| 318 | Sensitive-action approval | Not built |
| 319 | Replay protection | Built |
| 320 | Rate limiting | Not built |
| 321 | Sensitive-data redaction | Built |
| 322 | SSRF protection | Not built |
| 323 | Data-rights workflow | Not built |
| 324 | Recording and transcript access control | Not built |
| 325 | Tenant-leak testing | Not built |
| 326 | Privileged-action audit | Rules ready |

## 19. Analytics and optimization (12) — Built 0, Partly 0, Rules ready 1, Not built 11

| # | Automation | Status |
|---|---|---|
| 327 | Success and failure metrics | Rules ready |
| 328 | Message-delivery metrics | Not built |
| 329 | Callback completion metrics | Not built |
| 330 | Appointment outcome metrics | Not built |
| 331 | Lead response and conversion metrics | Not built |
| 332 | Follow-up completion metrics | Not built |
| 333 | Integration uptime metrics | Not built |
| 334 | Knowledge-sync metrics | Not built |
| 335 | Usage and cost metrics | Not built |
| 336 | Dashboard filtering | Not built |
| 337 | Anomaly detection | Not built |
| 338 | Workflow effectiveness analysis | Not built |
