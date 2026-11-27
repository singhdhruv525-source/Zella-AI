# Owner decisions audit (chat, 28 Oct to 24 Nov 2026)

Every product rule or decision the Zella Voice owner gave in chat in the main build session, checked against the
source of truth documents (`docs/ARCHITECTURE.md`, `ZELLA_VOICE_RULES.md`, `docs/PRODUCT.md`, `docs/MEMORY.md`, and
`docs/DESIGN_SYSTEM.md` where the rule is about the look). Audit made on 24 Nov 2026 (`AGT-9`).

**How it was made.** The owner's own messages (about 560, after removing pasted command output, tool results and
session summaries) were read in full, with the assistant replies around any unclear message to see what was agreed.
A message counts as a rule only when the owner clearly decided it or approved a proposal. Questions the owner asked
without deciding anything (hosting, passwords, sharding, backups, a 404 page) are not rules and are left out. No
secrets, keys, codes, personal addresses or customer data are copied here; the owner's words are paraphrased.

**Status words.** Covered: the documents already say it (doc and ID given). Partly covered: something was missing,
now added. Missing: nowhere in the documents, now added. Contradicted: the documents said something different, now
fixed to match the owner. Answered on 25 Nov: unclear or conflicting in chat; the owner answered on 25 Nov 2026 and the
answer is now written (see the last section).

## Summary

| Status | Rules |
|---|---|
| Covered | 31 |
| Partly covered (now completed) | 18 |
| Missing (now added) | 1 |
| Contradicted (now fixed) | 3 |
| Answered by the owner on 25 Nov 2026 (now written) | 2 (R55, R56; the R26 conflict was settled the same day) |
| Decided by the owner on 27 Nov 2026 (written with this entry) | 1 (R59; R57 and R58 are added by pull request 146) |
| Skipped on purpose (another pull request) | 1 |
| **Total** | **57** |

## The rules

| # | Date | The owner's words (paraphrased) | The rule | Area | Status | Where it is written |
|---|---|---|---|---|---|---|
| R01 | 28 Oct | A theme option in Settings; a default background, and anyone can upload their own picture | Each person picks the look and a background: a built in default or their own picture | Design | Partly covered (product only said "picture based palette") | `docs/PRODUCT.md` §8.6 Settings; `docs/DESIGN_SYSTEM.md` (looks) |
| R02 | 28 Oct | With an uploaded picture, the whole theme uses its palette, except the logo | A background picture sets the colours of the whole look; the Zella Voice logo keeps its own | Design | Partly covered | `docs/PRODUCT.md` §8.6; `docs/DESIGN_SYSTEM.md`. Code does it in Glass only (see below) |
| R03 | 28 Oct | Check creative notifications exist | Zella Voice uses creative notifications | Notifications | Covered | `docs/DESIGN_SYSTEM.md` (Notifications); `docs/MEMORY.md` §5 |
| R04 | 28 Oct, 25 Nov | A notification preferences page isn't needed; it should be built and on. 25 Nov: urgent texts are always on for team members; only the business owner changes who gets them | No preferences page: pop ups, desktop notifications and urgent texts are on by default; one Notification sound switch; a team member can't switch urgent texts off, only the business owner changes who receives them | Notifications | **Contradicted** (docs said each person turns email and SMS off per type, and listed "notification preferences" on Team) | `docs/ARCHITECTURE.md` §28, REQ-CRM-23, §27, §14.4, §23.1d; `docs/PRODUCT.md` §10, §15 |
| R05 | 28 Oct | Build items 3, 4, 7, 8, 10 and 12 of the list | Per business languages, an on call list, Google review reply drafts, "You might also need" suggestions, staff scorecards, a status page with uptime alerts | Features | Partly covered ("You might also need" was missing) | REQ-VOX-12, REQ-VOX-06, `docs/PRODUCT.md` §8.5 Reviews, §8.6 Scorecards, §16 status page; added to `docs/PRODUCT.md` §10 |
| R06 | 29 Oct | Voice & Numbers, Messaging and Automations are three admin pages, not under CRM Settings | Three distinct platform admin pages in the admin navigation | Admin | Covered | `docs/PRODUCT.md` §9; REQ-ADM-07, REQ-ADM-09, REQ-ADM-11 |
| R07 | 29 Oct | Never seed demo businesses or fake calls; show a setup state when a provider isn't configured | No fake or demo data in production; never simulate a provider's success | Data, honesty | Covered | REQ-LC-03, `BIZ-9`, `NN-11`, `UX-1` |
| R08 | 29 Oct | Keep businesses isolated; keep Super Admin separate from owner and staff; enforce on the server | Tenant isolation and platform admin permissions are enforced by the server | Admin vs owner | Covered | `NN-1`, §6.3, `UX-3`, `SEC-17` |
| R09 | 29 Oct | Configured, authenticated, reachable, tested and live are different statuses | An integration's status never overstates what was proven | Integrations | Covered | `docs/PRODUCT.md` §9.1; `docs/MEMORY.md` §5 (COM-01) |
| R10 | 29 Oct | Different businesses can have different voices; both the admin and the business owner can change it | A voice per business from an approved list, with a default; Zella Voice admins and the business can change it | Voice, admin vs owner | Covered | REQ-LC-09; `docs/PRODUCT.md` §7.1, §7.2 |
| R11 | 29 Oct | Connect the AI model for knowledge suggestions | Knowledge answers are drafted by AI and approved by the owner | Knowledge | Covered | §23.1 (Knowledge AI), REQ-KNW-04 |
| R12 | 30 Oct | Bought the Zella Voice domain and a spare | The main domain is the Zella Voice one | Brand | Covered | `docs/MEMORY.md` §2 |
| R13 | 30 Oct | When we reply, it must be from support only | support@ is a real shared mailbox; replies go out from it (billing@ and info@ are aliases) | Email | Partly covered (only in the email templates) | `docs/ARCHITECTURE.md` §14.4 (Senders) |
| R14 | 30 Oct | What about the no reply email? (agreed: automatic emails from no-reply@ with Reply-To support@) | Automatic emails come from a no reply address with Reply-To support@ | Email | Partly covered | `docs/ARCHITECTURE.md` §14.4 (Senders) |
| R15 | 30 Oct | The emails say one name but the website is Zella Voice | Customers always see "Zella Voice" | Brand | Covered | `NN-12`, `BRD-1`, D-21 |
| R16 | 30 Oct | The product language task: US English, clear, honest statuses | American English, sentence case, one label per state, distinct delivery statuses | Language | Covered | `BRD-2`, `BRD-3`, `BRD-4`; `docs/ZELLA_STATUS_LANGUAGE_GUIDE.md` |
| R17 | 3 Nov, 5 Nov | Merge it, no other branch or codespace; make changes in main | (Replaced on 6 Nov by R24) | Process | Covered (superseded by `NN-5`) | `NN-5`, `REL-4` |
| R18 | 3 Nov | The receptionist should know the services | Asks which service before booking, offers only the business's services, quotes a price only when entered | Calls | Partly covered | `AI-3` |
| R19 | 6 Nov | Prove the flow from business creation to the live assistant | The assistant is built from that business's current settings, never another's; changes reach the next call; only approved knowledge; caller statements never become knowledge | Calls, knowledge | Covered | REQ-VOX-01, REQ-VOX-ISO-01, `AI-10`, REQ-KNW-01, REQ-KNW-02, §23.1b |
| R20 | 6 Nov | Did the restaurant CRM include tables? Tables. | Restaurants book real tables, not only a seat limit | Industries | Covered | REQ-APT-ISO-09; `docs/PRODUCT.md` §8.1 |
| R21 | 6 Nov | The table layout should look like the reference on the tables page and the dashboard | A drawn floor plan on Tables and a Table layout card on Today | Industries, design | Partly covered | `docs/PRODUCT.md` §8.1 Tables |
| R22 | 6 Nov | Make buttons more dynamic, nothing should look like a boring page; every page, every button, pop ups, admin too | Lively but short motion in both apps, off for reduced motion | Design | **Contradicted** (design system said "nothing moves on hover") | `docs/DESIGN_SYSTEM.md` (Rules of use) |
| R23 | 6 Nov | Everything is reviewed by CodeRabbit first, then goes to main | Every change goes through a pull request reviewed by CodeRabbit before main | Process | Covered | `NN-5`, `REL-4`, `CLAUDE.md` |
| R24 | 6 Nov | No need to review many times | Fixes are batched; CodeRabbit reviews once, and again only on request | Process | Covered | `docs/MEMORY.md` §5 (CodeRabbit review routine) |
| R25 | 10 Nov | If it needs to be merged you can merge | Claude may merge once the review is clean and the checks pass | Process | Covered | `NN-5`; `docs/MEMORY.md` §1 |
| R26 | 15 Nov, 25 Nov | 15 Nov: let CodeRabbit fix, tell me when to click Fix comments. 25 Nov: Claude fixes them | Claude fixes every CodeRabbit finding itself, requests a new review, and merges only when every merge condition holds | Process | Partly covered; the 11 and 15 Nov messages conflicted, the owner settled it on 25 Nov | `docs/MEMORY.md` §1; `docs/ARCHITECTURE.md` §23.1d |
| R27 | 12 Nov | I need architecture, product, design and schema docs that you always follow; from now on follow the architecture rules | The source of truth documents are read and followed | Process | Covered | `CLAUDE.md`, `AGT-1` |
| R28 | 14 Nov | From our side the invoice will be sent automatically | Zella Voice emails every invoice itself on every payment | Billing | Partly covered (only in `docs/BILLING_EMAILS.md`) | REQ-BIL-09 |
| R29 | 14 Nov | When the plan is about to renew they get an email, even when auto debit is on | A renewal notice 3 days before every renewal (yearly plans also 7 days before) | Billing | Partly covered | REQ-BIL-28 |
| R30 | 14 Nov | They can pay by the link or through the app | The owner pays an invoice by the email link or in the app | Billing | Partly covered | REQ-BIL-28 |
| R31 | 14 Nov | Yes, they can switch off auto debit | Auto debit is on by default; the owner can switch it off | Billing, owner | Partly covered | REQ-BIL-28 |
| R32 | 14 Nov | Complete the full list of billing emails (agreed: urgent ones also by text) | The full billing email list; payment failed, final notice and paused also by text | Billing | Partly covered | REQ-BIL-28; `docs/BILLING_EMAILS.md` |
| R33 | 14 Nov | What happens without auto reload, and who stops it at the limit? | At 100% of minutes the owner's chosen action applies, decided by the database: with stop, new calls go to the fallback number; with auto reload a pack is bought; with pay as you go the AI keeps answering, up to the monthly spending limit | Billing, calls | Covered | REQ-BIL-22, REQ-BIL-32, D-44 |
| R34 | 14 Nov | Usage should update on the CRM too, at the same time | The CRM's usage updates within seconds of a call or message | Billing, CRM | Partly covered (product said every minute) | REQ-BIL-05; `docs/PRODUCT.md` §13 |
| R35 | 14 Nov | Nowhere in the whole app should a hyphen exist | No dashes or hyphens anywhere people read text | Writing | Partly covered (design system and memory, not the rulebook) | `BRD-6`; `docs/DESIGN_SYSTEM.md` (Writing) |
| R36 | 14 Nov | Creative but professional notifications, many more for different businesses | One creative, professional notification pattern in each business's own words | Notifications | Covered | `docs/DESIGN_SYSTEM.md` (Notifications) |
| R37 | 14 Nov | Ecommerce is fine | The industry is written "Ecommerce" in the app | Industries | Covered | `docs/MEMORY.md` §5; `docs/DESIGN_SYSTEM.md` (Writing) |
| R38 | 15 Nov | Every business's fallback number is decided when the business is created | Fallback number required at Create Business | Calls, onboarding | Covered | REQ-BIL-34; `docs/PRODUCT.md` §13 |
| R39 | 15 Nov | Those 4 businesses are demo; Zella Voice is still in production (being built) | No real customers yet; the live project holds demo businesses | Status | Covered | `docs/MEMORY.md` §3 |
| R40 | 15 Nov | All emails from Zella Voice to businesses: templates, admin preview, safe send queue | One email catalogue, admin preview, platform outbox | Email | Covered | §14.4; `docs/PRODUCT.md` §15 |
| R41 | 15 Nov | Billing emails will be pushed automatically, right? | Billing emails must be built (not built yet) and stay held; they go out automatically only once Stripe and email are live, each switched on with the owner's approval | Billing | Partly covered | §14.4, §23.1a |
| R42 | 16 Nov | Complete everything; once Stripe is made we just add the webhook | Build now, connect Stripe later | Billing | Covered | §23.1a; `docs/PRODUCT.md` §17 |
| R43 | 16 Nov | After the link: set password, go through the details, verify documents (Persona or another app), see the plan, then pay | The owner onboarding journey after the invite | Onboarding | Covered | REQ-LC-21; `docs/PRODUCT.md` §8.8 |
| R44 | 16 Nov | Zella Voice doesn't have a signup process | Invite only; businesses are created by the Zella Voice team | Onboarding | Covered | D-06, REQ-LC-03, `BIZ-9` |
| R45 | 17 Nov | Push to CodeRabbit one by one, merge when clean; check every 10 minutes and update me | Keep the owner posted about every 10 minutes while waiting | Process | Partly covered | `docs/MEMORY.md` §1 |
| R46 | 18 Nov | (Bot check on website forms) This will be added when the Zella Voice website is made | The bot check comes with the website, and is on before automatic texts or calls to form leads | Security, leads | Partly covered | REQ-LEAD-02 |
| R47 | 18 Nov | Answers to the security audit questions | Confirmation code for phone changes, appointment lookup checks, 90 day retention, AI disclosure, account deletion | Security, privacy | **Contradicted** in `docs/MEMORY.md` §5 (still said recordings 30 days); covered elsewhere | §23.1b, §23.1c; fixed `docs/MEMORY.md` §5 |
| R48 | 18 Nov | First recommend to me (before fixing the high and medium items) | Recommend before acting on choices that are the owner's | Process | Covered | `AGT-7`, `DEC-2` |
| R49 | 7 Nov, 24 Nov | Don't connect Cloudflare yet; first complete the app | Hosting is connected only when the owner says | Process | Covered | `docs/MEMORY.md` §2 (planned hosting) |
| R50 | 24 Nov | Authenticator is good | Admin two step sign in uses an authenticator app, not email codes | Security | Covered | REQ-LC-04; `docs/PRODUCT.md` §8.7; `SEC-17` |
| R51 | 24 Nov | I subscribed to Cartesia; make sure admins can choose the voice when creating a business | Cartesia voices; a voice picker in Create Business | Voice | Covered | `docs/MEMORY.md` §4; `docs/PRODUCT.md` §9 (Create Business wizard) |
| R52 | 24 Nov | Replace the dropdown; add a play button; every voice says the same Zella Voice line; use the reference only for the animation | Voice cards in a carousel with a sample of one shared line | Voice, design | Covered in the open pull request `claude/voice-cards` | `docs/PRODUCT.md` §7.1, `docs/DESIGN_SYSTEM.md` (Voice carousel), `docs/MEMORY.md` §4 on that branch |
| R53 | 24 Nov | Business owners can't change the language; Zella Voice admins can, if the plan includes Spanish | Languages are admin only and follow the plan | Languages, admin vs owner | Skipped here: written by the pull request `claude/admin-only-languages` | REQ-VOX-12, REQ-CRM-17, §10.9, `AI-22` (that branch) |
| R54 | 24 Nov | This should be in the architecture; I told you earlier, why wasn't it added? | Decisions given in chat are written into the docs when they are made | Process | **Missing** | `AGT-9`; `docs/ARCHITECTURE.md` §23.1d; `docs/MEMORY.md` §1, §6 |
| R55 | 24 Nov, 25 Nov | 24 Nov: all limits and caps are set when creating the business from the admin dashboard. 25 Nov: the admin sets them, and the owner can lower them | Zella Voice admins set every plan limit and cap at Create Business (including the highest monthly spending limit) and can change them later; the owner may choose a lower spending limit and what happens at the limit, never above the plan | Billing, admin vs owner | Decided by the owner on 25 Nov (was: needs the owner); now written | REQ-BIL-01, REQ-BIL-23, REQ-BIL-32, D-44, §23.1d |
| R56 | 24 Nov, 25 Nov | 24 Nov: 4 minutes is way too much, 1 minute with no voice is good. 25 Nov: a caller silent for 1 minute gets a polite goodbye | If the caller says nothing for 1 minute, the receptionist ends the call politely | Calls | Decided by the owner on 25 Nov (was: needs the owner); now written | REQ-VOX-13, `AI-24`, §23.1d |
| R59 | 27 Nov | Brand and last 4: billing emails may show the card brand and last 4 digits, read from Stripe; the expiry may be shown on screen during payment from Stripe's preview, never stored | Zella Voice keeps only the card brand and last 4 digits from Stripe, for billing notices, never the expiry; never a full card number or security code; Stripe holds the card | Billing, privacy | Decided by the owner on 27 Nov 2026 (written with this entry) | `docs/PAYMENTS_ARCHITECTURE.md` §9 and lane F; `docs/BILLING_EMAILS.md`; `docs/MEMORY.md` §5; legal drafts (Terms 9.5, Privacy Policy 3.1 and 10, DPA Annex 3) |

## Code does not follow this yet

The documents now say these; the code does not do them yet. No code was changed by this audit.

| Rule | What is missing | Where |
|---|---|---|
| R34 Live usage | The usage card refreshes every minute, on focus and on a usage notice; it doesn't update within seconds of a call or message | `web/src/UsageLive.jsx` (`REFRESH_MS = 60000`); would need a Realtime subscription limited to the business |
| R28 to R32 Billing | Nothing sends invoice, Paid or renewal emails, there is no auto debit setting or Pay now in the app, and no billing texts: Stripe isn't connected (billing step 4) | `web/src/settings/BillingPanels.jsx`, `billing-worker`, `billing-webhook`, `platform-emails` (design in `docs/BILLING_EMAILS.md`, `docs/PAYMENTS_ARCHITECTURE.md` §6.11) |
| R02 Picture colours | The picture's colours apply only in the Glass look, behind "Match colours to the picture" | `web/src/appearance.js` (palette applied with Glass only) |
| R46 Bot check | Website forms have no bot check yet (deferred on purpose until the Zella Voice website) | `web/supabase/functions/website-lead` |
| R56 Silent callers | **Built, not applied** (no longer missing in code): `sql/zella_silence_timeout.sql` (pull request #118) adds Vapi `customer.speech.timeout` hooks to `zella_assistant_config`: "Are you still there?" after 30 s of silence, then at 60 s the goodbye with the business's name (English or Spanish) spoken before the call ends; setting `voice_silence_timeout_seconds` = 60. Vapi's 3.0.0 types have no `silenceTimeoutSeconds` on an assistant, so hooks replace it. What is left: the owner's approval to apply it, then a test call to time it (`docs/VOICE_RELIABILITY.md`, Silent callers) | `sql/zella_silence_timeout.sql`, `zella_silence_hooks` |
| R55 Limits and caps | Plans have no highest monthly spending limit: `business_plans` (`sql/zella_billing_allowances.sql`) stores no spending cap, and `zella_auto_reload_save` accepts any cap up to $100,000 whatever the plan; the owner's choice at the limit lives in `business_usage_preferences`. "Calls at once" (default 10) has no Create Business setting | `sql/zella_billing_allowances.sql` (`business_plans`, `zella_auto_reload_save`), Create Business plan step, `sql/zella_call_limits.sql` |
| R59 Card brand and last 4 | Billing records don't store the card brand or last 4 digits yet, so the templates that need them stay held (`MISSING_FIELD:<code>:card`). B2 stays held until the owner decides whether to revise its trigger and copy to work without card expiry or remove the template. | `sql/zella_stripe_emails.sql`, `_shared/billingEmails.ts`; legal launch blocker 22 |
| R04 Urgent texts | No screen lets the business owner choose who receives urgent texts, and Settings, My profile says the mobile number is "used for urgent text alerts you switch on" | `web/src/settings/PersonalPanels.jsx`; the urgent text recipient rules |

## Answered by the owner on 25 Nov 2026

These were listed as needing the owner's answer on 24 Nov. The owner answered on 25 Nov 2026, and each answer is now
in the documents (architecture §23.1d).

1. **Who fixes CodeRabbit's findings (R26).** Chat said both "You fix" (11 Nov) and "let coderabbit fix" (15 Nov).
   **Answer:** Claude fixes every finding itself, requests a new review, and merges only when every merge condition
   holds (`docs/MEMORY.md` §1).
2. **Who sets limits and caps (R55).** Chat (24 Nov) said every limit is set at Create Business, while D-44 let the
   owner choose. **Answer:** Zella Voice admins set every limit and cap at Create Business and can change them later;
   the owner may choose a lower monthly spending limit and what happens at the limit, never above the plan (REQ-BIL-01,
   REQ-BIL-23, REQ-BIL-32, D-44).
3. **Ending a silent call (R56).** Unclear whether 24 Nov was about calls or an approval popup. **Answer:** if the
   caller says nothing for 1 minute, the receptionist ends the call politely (REQ-VOX-13, `AI-24`).
4. **Stopping urgent texts (R04).** On 28 Oct this was "later". **Answer:** urgent texts are always on for team
   members; only the business owner changes who receives them (§28, REQ-CRM-23).
