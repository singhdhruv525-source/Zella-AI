# Zella Voice: copy changelog

## 28 November 2026: business app (CRM), onboarding and public pages, line by line

Words only, plus two raw errors replaced. Every sentence of eight words or more in the CRM, the owner onboarding
screens and the public pages (1,378 in all) was read against `docs/ZELLA_PRODUCT_VOICE.md`, and every shorter label
was checked by pattern (closes the CRM half of R-1 in `docs/ZELLA_UX_COPY_AUDIT.md`). The notification and celebration
lines in `src/zellaVoice.js` were left as the owner chose them on 28 Nov 2026.

| Where | Was | Now | Why |
|---|---|---|---|
| Network failures (people, scheduling, workflows) | Couldn't reach Zella Voice. Nothing was changed; try again. | Couldn't reach Zella Voice, so this may not have been saved. Check your connection, refresh and try again. | A request can reach the server before the connection drops; the old words claimed what the app can't know (UX-2, NN-11) |
| Dispatch board and resource day | zella_dispatch_board / zella_resource_day returned an unexpected shape | The dispatch board (this day's resources) couldn't be read. Try again, or contact Zella Voice support if it keeps happening. | A function name was shown to business users |
| Settings group | SMS, email and messages | Texts, email and messages | "Text", not "SMS" |
| Signposts | Settings &gt; Team; Settings → Tables and seating; under Personal profile; Settings > Users, roles & access > Platform roles; Plan & pricing | Settings, Team and access; Settings, Tables and seating; My profile; Settings, Admins and roles, Platform roles; setup under Plan & pricing | The names the menus show |
| Suggested messages empty state | for a family, patient or client | for someone | No industry words hard coded (BIZ-10) |
| Callbacks, handovers, profile | or you escalate one; Handled handoffs; Flagged for a human | or you hand one over; Handled handovers; Flagged: needs a person | The voice guide's words |
| Admin pages | every client business; Things that block clients | every business; Things that block businesses | "Client" is an industry's word for customers |
| British words | lettings, takings, till system | rentals, sales, point of sale system | American English |
| Contractions and plain words | is not, was not, could not, will no longer, They will, any more, reemailed, billing.manage | isn't, wasn't, couldn't, won't ... anymore, They'll, anymore, sent again, the billing permission | Plain, consistent voice |
| Reviews and spam | ...needs to apply its latest database update; location ids | This needs the latest Zella Voice update; IDs | One phrase for one state |
| Errors | ...Please ask the Zella Voice team | ...Ask the Zella Voice team | "Please" kept for real requests only |

## 28 November 2026: admin dashboard, line by line

Words only. Every sentence in the admin settings registry, the create business wizard, offers, voice and numbers,
security and abuse, automations, messaging, industry configuration, number orders, support, alert rules, data
retention, audit logs, verification, integrations and the other admin panels was read against
`docs/ZELLA_PRODUCT_VOICE.md` (closes the admin half of R-1 in `docs/ZELLA_UX_COPY_AUDIT.md`).

| Where | Was | Now | Why |
|---|---|---|---|
| Signposts in admin and CRM settings | Voice, telephony & usage; Webhook management; Voice & numbers > Providers; Plans, subscriptions & entitlements; Legal, policy & platform documents; Security & privacy > Data retention; My account; Restaurant operations; Business profile > Business hours | The names the menus show now: Voice and numbers; Integrations, then Webhooks; Telephony providers; Plans and limits; Legal documents; Security and privacy; My profile; the Tables page; Business profile, Business hours | Several pointed at pages that no longer have that name |
| Admin pages that serve Zella Voice's customers | client businesses, every client's | businesses, every business's | "Client" is also an industry's word for a business's own customers |
| Features waiting for a database file | Needs sql/zella_...sql applied (after a backup); not installed on this database | Needs the latest Zella Voice update | One phrase for one state, no file names |
| AI receptionists list | No agents yet; Agent | No AI receptionists yet; AI receptionist | The product's word |
| IDs | Provider id, Correlation id, Record id, Vapi phone number id, Telnyx number id | ... ID | Acronyms in capitals |
| AI guardrails and evaluation | (ai_tool_calls), (ai_eval_cases), (zella_brain_run_evals) | Plain sentences | No table or function names in sentences |
| Wizard | Owner email / login; Enquiries; Confirmation & check in; no show follow up; Finish & send invitation; for this client; was not activated | Owner email (used to sign in); Inquiries; Confirmation and check in; No show follow up; Finish and send invitation; for this business; wasn't activated | Plain words, American spelling, sentence case |
| Offers | Total claims (empty = no limit); paid claim(s) | Total claims (leave empty for no limit); paid claim or claims by count | Plain words, real plurals |
| Number orders | It can't be got back; was not bought | This can't be undone; wasn't bought | Plain words, contractions |
| Messaging switches | so one click can't start messaging customers | so a single mistake can't start messaging customers | Works for any input |

Kept on purpose: "e.g." in input placeholders (one consistent, short pattern; "For example," overflows narrow inputs on
phones), setting and secret names an admin has to type (STRIPE_WEBHOOK_SECRET, vapi_auth_mode), and "&" in menu
names.

## 28 November 2026: quick fixes from the full app scan (both apps and the public pages)

Words only; nothing a screen does changed. Found by a scan of every string in `web/src` against
`docs/ZELLA_PRODUCT_VOICE.md` (owner's go ahead, 28 Nov 2026). Errors now say what happened and what to do next; none
claims something was or wasn't saved unless the code knows.

| Where | Was | Now | Why |
|---|---|---|---|
| Page error panel (CRM, admin and the whole app) | Something went wrong (on this page) | This page stopped working | Says what happened (UX-10) |
| Unsubscribe page, after a failed confirm | Something went wrong. Please try again, ... | We couldn't confirm that you're unsubscribed. Try again, ... | The person learns the one thing that matters |
| Reschedule and waitlist links | Something went wrong. Please try again. | That didn't work. Try again in a minute, or contact the business. (heading: We couldn't do that right now) | A next step for customers |
| Continue plan link, setup and onboarding fallbacks | Something went wrong. Please try again. | That didn't work. Try again (in a minute), or contact the Zella Voice team (if it keeps happening). | Same |
| Onboarding server error | Something went wrong on our side. Please try again. | We had a problem on our side. Try again in a minute. | Same |
| Admin lists that fail to load | Something went wrong. | This couldn't load. Try again. | Same |
| Weekly report fallback | Something went wrong. | The weekly report couldn't load. Try again. | Same |
| Website contact form (the business's own site) | Something went wrong. Please call us. | We couldn't send your message. Please call us instead. | Same |
| Owner and admin errors (sign in, session, voices, invitations, plan) | ... Please try again / Please sign in again / Please review it again | ... Try again / Sign in again / Review it again | "Please" kept only where we ask someone to do something inconvenient (contact the business or support) |
| Calendar | Click an empty time to book | Select an empty time to book | Works for touch and keyboard too |
| Connection state | Business cancelled | Business canceled | American English |
| Offers history | Could not go live; Error while going live | Couldn't go live; Couldn't go live (system problem) | Plain words, contractions |
| Six sentences with a serial comma (data requests, connections, offers, controls, capabilities, onboarding) | a, b, and c | a, b and c | House voice: no serial comma |
| Shopify connection hint | In Shopify: Settings, Apps and sales channels, Develop apps, create an app ... | In Shopify, go to Settings, then Apps and sales channels, then Develop apps. Create an app ... | A path, then the steps |

## 25 November 2026: phone navigation (both apps)

New words on phones (under 768 wide), except the "Needs you now" notes in the notification bell, which show on phones
and desktops alike (owner, 25 Nov 2026, REQ-MOB-12; the bell rows below). Tablets show nothing new. Approved by the
owner on 25 Nov 2026 (`docs/ARCHITECTURE.md` §23.1d). Sources: `web/src/navigation/` and the phone parts of the pages named below.

| Where | Text | Why |
|---|---|---|
| Bottom bar, CRM | Today, Calendar, Tables, Check ins, Dispatch, Orders (the record type's name), Leads, the industry's customers (Guests, Clients, Patients, Customers), Inbox, More | The tab rule; "Calendar" for every industry (owner decision 3) |
| Bottom bar, admin | Overview, Businesses, Support, Operations, More (Verification and Audit logs when a role can't open Support or Operations) | Owner decision 4 |
| Tab names for screen readers | "Inbox, 2 waiting", "More, 1 to review", "Support, 5 open", "Operations, 1 open alert" | The count is part of the tab's name |
| Side panel | Menu (its name), Close menu, Switch, My profile, Password and security, Appearance and theme, Sign out, Zella Voice Platform | Same words as the desktop menus |
| Top bar | Search (and the page's own "Search ..." words), Show more, Show less (the sheet handle), Close | Plain names for icon buttons |
| Sticky action | New reservation (the industry's word for a booking), Add lead, New task, Seat a walk in (restaurants) or Add a walk in, Create business, Quick actions | One main action per page |
| Quick actions sheet | Quick actions; Seat a walk in, Add lead, New task, Tell callers | Today's round button |
| Business switcher sheet | Switch business or open its settings; Switch business; Business profile; Modules and industry; Team members; Plan and billing | Same as the desktop switcher |
| Live strip, CRM | "2 callers want a person", "Tom Becker, waiting 4 min", "Waiting 9 min", "Your AI receptionist handed them over", Open | Callers waiting only (owner decision 6) |
| Live strip, admin | The incident's title, "Incident open for 18 min", "2 open incidents", View | Open incidents only |
| Needs you now (Today) | Needs you now; "2 callers want a person"; "Tom Becker asked about ..."; "Task for Maya Chen, due 1 hr ago"; "3 overdue tasks"; "The oldest: ..."; Overdue; "1 call to review in Spam protection"; "Blocked as likely spam, check it was right" | P14 |
| Tasks | "Swipe a task left to call back or mark it done", Call back, Done, "Mark ... done", "More for ...", Mark done, "Call back ...", "Open ...", Dismiss, "Task marked done", Undo, "Couldn't mark it done, so it's back on the list." | Swipe rows with visible buttons, Undo |
| Callbacks | "Swipe a callback left to call or mark it called", Call, Called, "Mark ... called", Overdue | Swipe rows; Called opens the existing "how did it go" form |
| Admin Support | "Swipe a ticket left to assign it to you or resolve it", Assign, Resolve, Open ticket, Assign to me, "Open ...", "Ticket resolved", "Ticket assigned to you", "Couldn't save that change, so it's back as it was.", No reply yet, "Couldn't load this list. Pull down to try again, or reload the page." | Swipe rows, Undo |
| Admin business sheet | Plan, Stage, Last call, Open, Continue setup, Call owner, Activity, Needs attention, Setup; "Plumbing, owner Dana Reyes" | P12 |
| Pull to refresh | Pull to refresh, Let go to refresh, Refreshing | P17 |
| Placeholders (screen readers) | Loading the page, Loading tasks, Loading callbacks, Loading tickets, Checking your access | P18 |
| Notification bell, "Needs you now" notes (phones and desktops) | Kicker "Needs you now"; "Tom Becker wants a person" or "A caller wants a person", "Asked about ... Waiting 4 min" or "Your AI receptionist handed them over. Waiting 4 min"; "Overdue: Confirm cake delivery" (or "Overdue: a task"), "Task for Maya Chen, due 1 hr ago" or "Due 5 min ago"; "1 call to review in Spam protection", "Blocked as likely spam, check it was right"; "And 37 more callers want a person", "Open Needs attention to see them all"; "And 1 more overdue task", "Open Tasks to see them all"; "Task dismissed", "Couldn't dismiss it, so it's back on the list." | Owner, 25 Nov 2026: Needs you now should show in the notification |

## 25 November 2026: wording pass across the admin and CRM

Owner approved 25 Nov 2026, "yes to all A and C" (architecture §23.1d, `AGT-9`): the wording items of the admin audit
(A2 to A5, A14 to A21, A34, A36, A38, A42, A43, A50, A52, A56, A58) and the CRM audit (C1 to C8, C11 to C15, C28,
C31, C32, C34, C35, C38, C43, C44, C46 to C48, C50). Frontend wording only: no behaviour, permission or data changes.
Where an item also offered the page's own button (A20, C13, C14) the button is the one the page already has.

### Admin

| Where | Before | After | Item |
|---|---|---|---|
| Setup wizard, footer | "Save & continue →", "Create draft & continue →", "← Back" | "Save & continue", "Create draft & continue", "Back" with the back icon | A2 |
| Business details, back link | "← Businesses" | "Businesses" with the back icon | A2 |
| Page not found | "Go to Overview →" | "Go to Overview" | A2 |
| Wizard, line above the title | "BUSINESS SETUP", "NEW BUSINESS" | "Business setup", "New business" | A4 |
| Wizard word table and preview label, rule headings, ticket notes heading, Settings group labels and table headers, alert rule groups | spaced capitals | sentence case at 12px | A3 |
| Line above the title: Support tickets | "Support" | "Operations" | A5 |
| Line above the title: Users & access, Audit logs | "Access", "Security" | "Administration" | A5 |
| Line above the title: AI receptionists, Voice & numbers, Messaging | "AI and communications" | "AI & communications" (the sidebar group) | A5 |
| Settings setting keys, webhook paths, record field keys | code type | the normal typeface, grey | A14 |
| Verification, not set up | "Document storage isn't set up yet. Apply sql/zella_onboarding.sql; documents uploaded in the Create Business wizard then appear here for review." | "Document review isn't switched on yet. Documents uploaded during setup appear here once it is." (the file name is in the hover tip) | A15 |
| Security & abuse, not set up | "Spam protection isn't set up in the database yet. Apply sql/zella_spam_protection.sql (after a backup); incidents, defaults and rules then appear here." | "Spam protection isn't switched on yet. Ask the Zella Voice team to turn it on." (file name in the hover tip) | A15 |
| Settings, Branding, email note | "Emails are plain text with a simple layout (sql/zella_owner_emails.sql)." | "Emails are plain text with a simple layout." | A15 |
| Messaging, Emails to businesses | "The outbox isn't installed on this database yet (sql/zella_platform_emails.sql)." | "The email outbox isn't switched on yet." (file name in the hover tip) | A15 |
| Any page, missing server function | "This page needs a database update (sql/zella_admin_ops.sql)." | "This page needs the latest Zella Voice update." | A15 |
| Voice & numbers, switches | "Switches need a database update" / "Once the voice admin update is applied, this lists the call switches and jobs." | "Switches aren't available yet" / "This lists the call switches and jobs once they are." | A15 |
| Voice & numbers, number drawer | "Carrier details aren't read from Telnyx" / "Number type, capabilities and carrier status need the Telnyx API from a server action, which isn't built. …" | "Carrier details aren't shown yet" / "Number type and carrier status are in the Telnyx dashboard. …" (the reason is in the hover tip) | A15 |
| Voice & numbers, provider checks off | "… A "test connection" button isn't offered because it would need the provider keys in the browser." | sentence removed | A15 |
| Support, overdue tab | "Overdue tracking is unavailable until reply times are recorded (a database update is needed)." | "Overdue tracking starts once reply times are recorded." | A15 |
| Businesses list, draft stage | "Draft · next: Phone & integrations" | "Draft, next step: Phone & integrations" | A16 |
| Business details, setup progress | "Dental · America/Chicago" | "Dental, America/Chicago" | A16 |
| Wizard progress | "Step 5 of 10 · AI receptionist" | "Step 5 of 10: AI receptionist" | A16 |
| Settings subtitle | "Platform administration · signed in as Zella owner with two step sign in" | "Signed in as Zella owner, with two step sign in" | A16 |
| Automations overview notes | "51 active · 9 paused · 4 archived", "… reminders · … follow ups · … events" | "51 active, 9 paused, 4 archived", "… reminders, … follow ups, … events" | A16 |
| Security & abuse, risk | "high · 82", "high risk · 82" | "High risk, score 82" | A16 |
| AI receptionists, rows | "Plumbing · Setup finished" | "Plumbing, setup finished" | A16 |
| Settings, All businesses plan; Platform administrators last action | "Basic · Active", "Business updated · Nov 25, 2026" | "Basic, active", "Business updated, Nov 25, 2026" | A16 |
| Every "still working" label (about 100 places, admin and CRM) | "Loading...", "Saving...", "Checking...", "Retrying..." | "Loading…", "Saving…", "Checking…", "Trying again…" | A17, C15 |
| Offers, choices | "Choose...", "＋ Add a rule..." | "Choose", "Add a rule" | A17 |
| Any failed action (admin) | "Something went wrong. Please try again." / "Something went wrong. Try again." | "That didn't work. Check your connection and try again." | A18 |
| Businesses | "Could not load businesses. Please try again.", "Unable to load businesses", "Businesses not loaded" | "Businesses didn't load. Try again.", "Businesses didn't load", "Not loaded yet" | A18 |
| Business details | "Could not load this business: …" | "This business didn't load. …" | A18 |
| Billing records | "The list could not be loaded. Please try again." | "The list didn't load. Try again." | A18 |
| Session ended (Appearance, profile) | "Your session has ended. Please sign in again." | "Your session ended. Sign in again." | A18 |
| Users & access | "Admins not loaded" | "Admins didn't load. Try again" | A18 |
| Support, list error | "Couldn't load this list. Try again with Refresh, or reload the page." | "Tickets didn't load." with a Try again button | A18 |
| Failed load buttons (load notices, Businesses, access check, wizard plan and industries, Offers runs) | "Retry", "Retry now" | "Try again", "Try again now" | A19 |
| Support, empty | "No tickets here." | "No open tickets." with a New ticket button (other tabs keep "No tickets here.") | A20 |
| Voice & numbers, Numbers; Settings, Phone number management | "No phone numbers are assigned to any business yet.", "No numbers assigned yet." | "No numbers yet." with an Assign a number button (admins who manage numbers) | A20 |
| Offers, empty | "No offers here." | "No offers yet." on All, with a New offer button | A20 |
| Settings, Branding | "sign in page headline" | "Sign in page headline" | A21 |
| Settings, Authentication policies | "sign in options" | "Sign in options" | A21 |
| Business details, readiness note | ""Voice connection" reads the connections table, which has no rows yet, so it stays unticked until that connection is recorded." | "Voice connection stays unticked until the first call connection is recorded." | A34 |
| Business details, Phone & integrations | "google_calendar" | "Google Calendar" | A36 |
| Wizard, industry list failed | "The industry list couldn't be loaded" / "The industry list couldn't be read. Try again." / "Retry" | "Industries didn't load" / "Setup needs the industry list." / "Try again" | A38 |
| Offers, note | "No payment provider connected yet. Businesses can claim offers, and each claim waits as "Waiting for payment". It becomes "Paid" only when …" | "No payment provider is connected yet, so claims wait as "Waiting for payment" until a real payment arrives. Checkout, renewal pricing, referrals, win back and promotional emails switch on once their connections exist." | A42 |
| Offers, dates | "2026-11-15 10:00 → 2026-12-15 10:00 (America/Chicago)" | "Nov 15, 2026, 10:00 AM to Dec 15, 2026, 10:00 AM (America/Chicago)" | A43 |
| Automations, latest failure | "Latest failure: Missed call text back at Nov 25, 2026 at 4:09 AM" | "Latest failure: Missed call text back, Nov 25, 2026 at 4:09 AM" | A50 |
| Integrations | "Client requests vs. connected"; "forward · not connected", "Gmail · not tracked" | "Asked for and connected"; "Forwarding, not connected", "Gmail, not tracked" | A52 |
| Settings menu, the 17 categories | "General platform settings", "Business and tenant management", "Users, roles and access", "Plans, subscriptions and entitlements", "Offers and promotions", "Billing and financial operations", "AI providers and agents", "Voice, telephony and usage", "SMS, email and communications", "Integrations and automation", "Security and privacy", "Notifications and alerts", "Support and service operations", "Analytics and reporting", "Legal, policy and documents", "Developer and API", "Administrator profile" | "Platform", "Businesses", "Admins and roles", "Plans and limits", "Offers", "Billing", "AI", "Voice and numbers", "Texts and email", "Integrations", "Security and privacy", "Alerts", "Service health", "Reports", "Legal", "Developer", "Your profile" | A56 |
| Settings, Branding | "Zella Voice uses one fixed theme (Oat & Slate). Making it adjustable needs a theme layer that reads saved settings instead of fixed CSS. …" | "Each admin picks Zella Voice, Classic or Glass for themselves under Appearance. A platform wide theme needs its own setting first." | A58 |

### CRM

| Where | Before | After | Item |
|---|---|---|---|
| Line above every page title | spaced capitals in the accent ("CALLS & MESSAGES / SPAM PROTECTION") | plain words in a quiet grey ("Calls and messages / Spam protection") | C1 |
| Sidebar and the line above titles | "Calls & messages", "AI & automation", "Reports & analytics", "Team & staff", "Tasks & follow ups" | "Calls and messages", "AI and automation", "Reports and analytics", "Team and staff", "Tasks and follow ups" | C2 |
| Line above the title: Tables | "Service" | "Workspace / Tables" | C3 |
| Line above the title: record pages, Customize records | "Records / Events and catering", "Business operations / Customize records" | the sidebar group, for example "Restaurant operations / Events and catering" | C3 |
| Line above the title: Check ins, Tasks, receptionist | "Workspace / check ins", "Workspace / Tasks & follow-ups", "AI Receptionist / Voice and setup" | "Workspace / Check ins", "Workspace / Tasks and follow ups", "AI receptionist / Voice and setup" | C3 |
| Sidebar | "check ins", "AI Receptionist" | "Check ins", "AI receptionist" | C3 |
| Page titles | "Reports", "Knowledge", "Transcripts and recordings", "Team", "Tasks" | "Reports and analytics", "Knowledge base", "Transcripts", the staff word (for example "Restaurant staff"), "Tasks and follow ups" | C4 |
| Times in lists and lines | "13 min ago", "2 h ago", "1 d ago", "5 d ago" | "13 minutes ago", "2 hours ago", "yesterday" ("Yesterday" on its own), "5 days ago" | C5 |
| Phone numbers (Calls, people, Team, call and person popups, booking panel, Needs attention) | "+15555550101" | "(555) 555 0101" | C6 |
| Time zones (Calendar, Check ins, Block time, New reservation, Move it, Scheduling rules) | "America/New York" | "Eastern Time (New York)" | C7 |
| Number card labels, Scorecards and Tables headings, table details panel, floor plan states, person profile, notification labels, Settings table headers and groups, profile menu email | spaced capitals ("COMING UP", "UPDATE", "OWNER@EXAMPLE.TEST") | sentence case ("Coming up", "Update", "owner@example.test") | C8 |
| Settings subtitle | "The Olive Table · Owner" | "The Olive Table, signed in as owner" | C11 |
| Calendar subtitle | "Sun, Nov 22 to Sat, Nov 28 · America/New York" | "Sun, Nov 22 to Sat, Nov 28, Eastern Time (New York)" | C11 |
| Tables subtitle | "Now · 6 tables" | "Now, 6 tables" | C11 |
| Person popup | "Guest · added 1 d ago · Phone · not contacted yet" | "Guest added yesterday by phone, not contacted yet" | C11 |
| Team rows | "Host · +15555550101" | "Host, (555) 555 0101" | C11 |
| Tables | "Add your tables in Settings → Tables and seating." | "Add your tables in Settings, Tables and seating." | C12 |
| Tables and seating, Seating rules | "Set in Receptionist → Booking rules, …", "Settings → Hours and holidays" | "Set in AI receptionist, Appointment booking, …", "Settings, Business hours" | C12 |
| Settings links | "Billing & subscription > AI usage protection", "Team & access > Staff availability", "AI receptionist > Escalation and fallback" | "Billing and subscription, AI usage protection", "Team and access, Staff availability", "AI receptionist, Escalation and fallback" | C12 |
| Empty lists | "No resources yet", "No recurring plans yet", "No automations yet", "Nobody is waiting", "No open invitations" | the same words with the page's own button: Add a resource, Add a plan, Write your own rule, Add to waitlist, Invite someone | C13 |
| Tables, waitlist panel button | "Add" | "Add to waitlist" (one name with the Waitlist page) | C13 |
| Money | "Business currency unavailable." | "Your currency didn't load. Try again, or check Settings, Time zone and locale." | C14 |
| AI receptionist page | "Couldn't load this page: The receptionist's settings couldn't be loaded." | "Your receptionist's settings didn't load. Try again." | C14 |
| Spam protection and Reviews figures | "Not available" in big number type | "Didn't load." in small type with Try again | C14 |
| Tables | "walk in" | "Walk in" | C28 |
| Follow through | "quote · asked 1 d ago", "answer by Fri, Nov 27", "asked …", "finished …", "opened …" | "Quote, asked yesterday", "Answer by Fri, Nov 27", "Asked …", "Finished …", "Opened …" | C31 |
| Customers and record pages | "Use the search box at the top to find someone by name, phone or email.", "Use the search box at the top to find one." | "Search by name, phone or email in the top bar.", "Search in the top bar to find one." | C32 |
| Call details | "follow up", "handoff" | "Follow up", "Handed to a person" | C34 |
| Sending failed, Automations (view only) | "follow ups, appointment reminders …", "follow ups, reminders and check ins …" | "Follow ups, appointment reminders …", "Follow ups, reminders and check ins …" | C35 |
| Reports | "Handed to a human" | "Handed to a person" | C38 |
| Scorecards | "no longer works here" | "No longer on the team" | C43 |
| Settings, Roles and permissions | "Can…", "None" | "Permission", "No" | C44 |
| Settings, Business information | "For example: family clinic, 24-hour plumbing." | "For example: family clinic, 24 hour plumbing." | C46 |
| Settings, Current plan | "None AI minutes / month", "English & Spanish", "One-time setup fee" | "AI minutes not set" (and "Texts not set", "Emails not set"), "English and Spanish", "One time setup fee" | C47 |
| Settings, Usage and charges | "None to None. Counted from your records." | "No billing period yet. Counted from your records." | C48 |
| Settings, Appearance | "Paper, midnight and coral. The official Zella Voice look." and the other theme and sidebar descriptions | "Paper, midnight and coral, the official Zella Voice look"; the descriptions lose their full stops | C50 |

Added once the bug fix pull request (#121) merged, on the lines it changed:

| Where | Before | After | Item |
|---|---|---|---|
| Industry configuration, failed load | "Couldn't load the industries. Reload the page to try again." (with "Industries didn't load." in a second panel) | one message, "Industries didn't load.", with a Try again button (from #121); the empty right hand panel is gone | A40 |
| Industry configuration, empty list | "No industries yet." | "No industries yet." with a New industry button | A20 |
| Industry configuration, loading | "Loading industries...", "Loading..." | "Loading industries…", "Loading…" | A17 |
| Settings, Industry profile, Words | "Industry & business workflows > Terminology" | "Industry and workflows, Terminology" | C12 |

The Today page keeps its own wording pass.

## 25 November 2026: CRM Today page polish

Owner approved, 25 Nov 2026 (architecture §23.1d). Frontend wording only.

| Where | Before | After | Change |
|---|---|---|---|
| Today, title | "Good morning, Rosa!" (a greeting with the first name) | "Today" (another day: its date, for example "Thursday, November 26") | 1 |
| Today, lines under the title | "Here's what's happening at The Olive Table today." | "Wednesday, November 25", then "The Olive Table" on a second, quieter line (another day: the business name only) | 2 |
| Today, walk in button | "walk in" | "Walk in" | 3 |
| Sidebar | "check ins" | "Check ins" | 3 |
| Today, card | "Tasks & follow ups" | "Tasks and follow ups" | 4 |
| Today, card | "Reviews & feedback" | "Reviews and feedback" | 4 |
| Header search, placeholder | "Search guests (press Enter)" | "Search guests" (the industry's word) | 5 |
| Today, bookings table, empty Table or staff cell | "None" | "Not set" | 6 |
| Today, bookings table, empty Guests cell | "None" | "None" in faint text (first shipped blank; corrected 25 Nov 2026 by the full review, since an empty count is never blank) | 6 |
| Sidebar section names | "WORKSPACE", "CRM", "RESTAURANT OPERATIONS" (spaced capitals by style) | "Workspace", "CRM", "Restaurant operations" (sentence case) | 19 |

Change 2 was revised by the owner on 25 Nov 2026, before merge: the first version read "Wednesday, November 25 · The
Olive Table" on one line. A meta line joined with a middle dot ("A · B") reads as a generic template tell, so the date
and the business name now sit on two lines, the name quieter.

## 25 November 2026: wording bugs found by the page audits

Approved by the owner on 25 Nov 2026 (A41, C33, C36, C39, C45). Details: the admin and CRM page audits.

| Where | Before | After | Item |
|---|---|---|---|
| Record lists, count under the table | "4 event or catering enquirys" | each kind's own plural word, as stored in its setup: "4 events and catering" for the restaurant preset (customer lists too) | C33 |
| Spam protection, incidents per day chart | "11-23" | "Nov 23" | C36 |
| Reports, Checked in | "1 arrivals" | "1 arrival" (and "1 no show" under No show rate) | C39 |
| Settings, Industry profile, Modules switched on | "Ai-receptionist, Automations, Calendar, Calls" | "AI receptionist, Automations, Calendar, Calls" | C45 |
| Admin, Industry configuration, failed or empty load | "Cannot read properties of undefined (reading '0')", "Couldn't load the industries. Reload the page to try again." and "Industries didn't load." | "Industries didn't load." with a Try again button | A41 (A40 wording) |
| Admin Settings, Reporting configuration, empty answer | the page crashed | "Couldn't load this: The server didn't answer." with Try again | S62 |
| Settings, Billing, Auto reload, a resource with no packs | the page crashed when the list was missing | "No packs of texts are on offer right now, so there is nothing to reload with. Ask Zella Voice support." (per resource) | CRM audit, section 4 |

## 25 November 2026: CRM look

CRM only (owner approved, `docs/DESIGN_SYSTEM.md` "CRM look"). One wording change; the chart gains date marks.

| Where | Before | After | Item |
|---|---|---|---|
| Tables, a table's details panel | "Block…" | "Block table" | C29 |
| Reports, Calls per day | no dates under the bars | "Oct 27", the middle day ("Nov 10") and "Today" under the first, middle and last bar | C41 |

## 25 November 2026: admin pages polish

Admin dashboard only (owner approved, `docs/DESIGN_SYSTEM.md` "Admin pages polish").

| Where | Before | After | Why |
|---|---|---|---|
| Admin buttons (Refresh, New ticket, New offer, Add admin, Back, Close, wizard Back and Continue, ticks) | "↻ Refresh", "＋ New ticket", "← Businesses", "×", "✓", "Save & continue →" | Same words with real icons | Typed symbols replaced by the icon set |
| Business, Phone & integrations | "Fallback number, where calls go when the AI receptionist can't take them: not set." under the card | "Fallback number: Not set" as the Phone numbers card's last row, with "Where calls go when the AI receptionist can't take them" under it | One place for the numbers |
| Audit logs, an opened entry | The raw before and after records | What changed, in words (field, before, after; "No field changed in this entry." when nothing did), the raw record under "Show raw record" | Readable first |
| Integrations, requests table | "✓ Website" | "Website" with a green dot | No typed ticks |

## 25 November 2026: admin dashboard polish

Admin dashboard only (owner approved, `docs/DESIGN_SYSTEM.md` "Admin polish"). No words added or removed.

| Where | Before | After | Why |
|---|---|---|---|
| Admin sidebar group labels | BUSINESSES, CONFIGURATION, AI & COMMUNICATIONS, OPERATIONS, ADMINISTRATION (spaced capitals) | Businesses, Configuration, AI & communications, Operations, Administration | Sentence case, as written |
| Line above the page title | PLATFORM CONTROL CENTER (and every admin page's eyebrow) | Platform control center | Sentence case |
| Admin sidebar scroll cue | MORE BELOW | More below | Sentence case |
| Overview panel captions | "Problems that block a client from going live." and the four others | No full stop at the end | A caption is a label, not a sentence; empty state sentences keep theirs |
| Top bar search hint | "Search businesses..." | "Search businesses" | No trailing dots |
| Overview counts | 3182, 2847 handled by AI | 3,182, 2,847 handled by AI | Thousands separator |
| Overview buttons | "↻ Refresh", "＋ Create business", "＋ Create your first business" | Same words with real icons | Typed symbols replaced by the icon set |

## 30 October 2026: product language pass

Frontend wording only (`web/src`). Internal values, routes, permissions and backend behavior are unchanged, except
where a label and its calculation disagreed (call results; see below). Details and evidence:
`docs/ZELLA_UX_COPY_AUDIT.md`.

### Calls and messages

| Where | Before | After | Why |
|---|---|---|---|
| Call result (Calls, call details, Inbox, profile, leads, booking panel, Today) | "Answered" for every call that wasn't missed | Answered / Missed / Didn't connect / In progress | Failed and ringing calls were shown as answered |
| Calls filter | "Answered" (included failed calls) | "Answered" (answered or completed only) | The filter matches its name |
| Reports | answered count included failed and in-progress calls | answered or completed only | The metric matches its label |
| Sidebar, page | "Didn't send" / "Messages that didn't send" | "Sending failed" | Matches the backend state: a send attempt failed |
| Sending failed, button | "Try again" | "Retry sending" | Names the action |
| Sending failed, empty | "Nothing has failed. Messages and reminders are going out as expected." | "No failed messages. Nothing failed to send in the last 7 days." | The page can't confirm that sending works |
| Sending failed, toast | "Queued to send again." | "…It goes out on the next sending run." | Says what happens next |
| Retry refused | "This can't be retried any more." | Gives the reason (already retried, or appointment passed) | Actionable |
| Test-mode reasons | "Dry run no provider" | "Not sent (test mode: no provider connected)" | No internal codes |
| Sidebar | "Conversations" (page titled "Unified inbox") | "Inbox" (page "Inbox") | One name for one page |
| Messages | "Sms", "sms conversation", raw "open" | "Text message", "Open" | No internal values |
| Escalations | "Needs a human", "Human handover" | "Needs a person" | One term |
| Calls filter | "AI handled" | "Handled by AI" | Reads naturally |

### Navigation

- Sentence case: Calls & messages, Tasks & follow-ups, Reports & analytics, Team & staff, Business growth,
  AI & automation (sidebar and breadcrumbs).
- Breadcrumbs now match the sidebar:
  - Calls & messages / Calls;
  - AI Receptionist / Transcripts;
  - AI & automation / Knowledge base;
  - CRM / Leads (and the industry's customers);
  - Calls & messages / Inbox.
- "Customise records" → "Customize records".

### Industry wording

- Header button and booking dialog: "Book booking" (salons) → "New booking". Generally it is now
  `New <appointment word>`: New appointment, New reservation, New service call.

### Statuses everywhere

- New `web/src/copy/labels.js`:
  - `humanize()` gives one label per internal value, covering every status in the database;
  - `callResult()` and `isAnswered()` cover call results.
- Replaced 7 duplicate `words()` helpers and 13 inline `.replace(/_/g, " ")` conversions.
- Examples:
  - `pending_review` → Awaiting review;
  - `false_positive` → Not spam;
  - `needs_reconnect` → Needs reconnecting;
  - `dry_run` → Not sent (test mode);
  - `no_show` → No-show;
  - `ai_setup` → AI setup;
  - `cancelled` → Canceled;
  - `11labs` → ElevenLabs.
- Raw status badges are now humanized in:
  - admin Automations and Voice & numbers;
  - Integrations;
  - profile callbacks.
- Badges are no longer force-capitalized by CSS (`.ba-pill`), so they read in sentence case.

### Errors

- About 25 screens showed raw server text (`err.message`). They now go through:
  - `friendly()` in the business app;
  - `friendlyError()` in the admin dashboard.
- The page loader (`useLoad`) and the plan-continue banner use `friendly()` too.
- New rules:
  - network failures → "Couldn't reach Zella. Check your internet connection and try again.";
  - unknown codes → "That didn't work (code X). Try again, or contact Zella support if it keeps happening.".

### Spelling (US English)

About 70 user-facing strings changed:
- color, customize, customized, license, driver's license;
- programs, recognized, summarizes;
- canceled, canceling, anymore.

Internal values such as `cancelled`, field names and code identifiers were left unchanged.

### Not changed on purpose

- **Admin dashboard navigation labels** ("Industry Configuration", "Audit Logs", …) stay in Title Case. They double
  as routing keys, so renaming them is a code change, not a copy change. Tracked as R-2 in the audit.
- **"AI Receptionist"** stays capitalized as the module name in navigation; in sentences it is "your AI
  receptionist".
- **Database status values, API fields and audit action names** are unchanged.
