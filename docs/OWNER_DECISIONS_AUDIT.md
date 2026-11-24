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
fixed to match the owner. Needs the owner: unclear or conflicting, nothing written (see the last section).

## Summary

| Status | Rules |
|---|---|
| Covered | 32 |
| Partly covered (now completed) | 17 |
| Missing (now added) | 1 |
| Contradicted (now fixed) | 3 |
| Needs the owner's answer | 2 (plus one conflict inside R26) |
| Skipped on purpose (another pull request) | 1 |
| **Total** | **56** |

## The rules

| # | Date | The owner's words (paraphrased) | The rule | Area | Status | Where it is written |
|---|---|---|---|---|---|---|
| R01 | 28 Oct | A theme option in Settings; a default background, and anyone can upload their own picture | Each person picks the look and a background: a built in default or their own picture | Design | Partly covered (product only said "picture based palette") | `docs/PRODUCT.md` §8.6 Settings; `docs/DESIGN_SYSTEM.md` (looks) |
| R02 | 28 Oct | With an uploaded picture, the whole theme uses its palette, except the logo | A background picture sets the colours of the whole look; the Zella Voice logo keeps its own | Design | Partly covered | `docs/PRODUCT.md` §8.6; `docs/DESIGN_SYSTEM.md`. Code does it in Glass only (see below) |
| R03 | 28 Oct | Check creative notifications exist | Zella Voice uses creative notifications | Notifications | Covered | `docs/DESIGN_SYSTEM.md` (Notifications); `docs/MEMORY.md` §5 |
| R04 | 28 Oct | A notification preferences page isn't needed; it should be built and on; the stop texts switch can come later | No preferences page: pop ups, desktop notifications and urgent texts are on by default; one Notification sound switch; a switch to stop urgent texts is later | Notifications | **Contradicted** (docs said each person turns email and SMS off per type, and listed "notification preferences" on Team) | `docs/ARCHITECTURE.md` §28, REQ-CRM-23, §27; `docs/PRODUCT.md` §10, §15 |
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
| R26 | 15 Nov | Let CodeRabbit fix, then merge; tell me when to click Fix comments | CodeRabbit fixes its findings when the owner ticks Fix comments; Claude tells the owner when | Process | Partly covered ("tell me when" was missing); conflicts with 11 Nov, see below | `docs/MEMORY.md` §1 |
| R27 | 12 Nov | I need architecture, product, design and schema docs that you always follow; from now on follow the architecture rules | The source of truth documents are read and followed | Process | Covered | `CLAUDE.md`, `AGT-1` |
| R28 | 14 Nov | From our side the invoice will be sent automatically | Zella Voice emails every invoice itself on every payment | Billing | Partly covered (only in `docs/BILLING_EMAILS.md`) | REQ-BIL-09 |
| R29 | 14 Nov | When the plan is about to renew they get an email, even when auto debit is on | A renewal notice 3 days before every renewal (yearly plans also 7 days before) | Billing | Partly covered | REQ-BIL-28 |
| R30 | 14 Nov | They can pay by the link or through the app | The owner pays an invoice by the email link or in the app | Billing | Partly covered | REQ-BIL-28 |
| R31 | 14 Nov | Yes, they can switch off auto debit | Auto debit is on by default; the owner can switch it off | Billing, owner | Partly covered | REQ-BIL-28 |
| R32 | 14 Nov | Complete the full list of billing emails (agreed: urgent ones also by text) | The full billing email list; payment failed, final notice and paused also by text | Billing | Partly covered | REQ-BIL-28; `docs/BILLING_EMAILS.md` |
| R33 | 14 Nov | What happens without auto reload, and who stops it at the limit? | At 100% the owner's chosen action applies; calls go to the fallback number; the database decides | Billing, calls | Covered | REQ-BIL-22, REQ-BIL-32, D-44 |
| R34 | 14 Nov | Usage should update on the CRM too, at the same time | The CRM's usage updates within seconds of a call or message | Billing, CRM | Partly covered (product said every minute) | REQ-BIL-05; `docs/PRODUCT.md` §13 |
| R35 | 14 Nov | Nowhere in the whole app should a hyphen exist | No dashes or hyphens anywhere people read text | Writing | Partly covered (design system and memory, not the rulebook) | `BRD-6`; `docs/DESIGN_SYSTEM.md` (Writing) |
| R36 | 14 Nov | Creative but professional notifications, many more for different businesses | One creative, professional notification pattern in each business's own words | Notifications | Covered | `docs/DESIGN_SYSTEM.md` (Notifications) |
| R37 | 14 Nov | Ecommerce is fine | The industry is written "Ecommerce" in the app | Industries | Covered | `docs/MEMORY.md` §5; `docs/DESIGN_SYSTEM.md` (Writing) |
| R38 | 15 Nov | Every business's fallback number is decided when the business is created | Fallback number required at Create Business | Calls, onboarding | Covered | REQ-BIL-34; `docs/PRODUCT.md` §13 |
| R39 | 15 Nov | Those 4 businesses are demo; Zella Voice is still in production (being built) | No real customers yet; the live project holds demo businesses | Status | Covered | `docs/MEMORY.md` §3 |
| R40 | 15 Nov | All emails from Zella Voice to businesses: templates, admin preview, safe send queue | One email catalogue, admin preview, platform outbox | Email | Covered | §14.4; `docs/PRODUCT.md` §15 |
| R41 | 15 Nov | Billing emails will be pushed automatically, right? | Billing emails are automatic once Stripe and email are live | Billing | Covered | §14.4, §23.1a |
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
| R54 | 24 Nov | This should be in the architecture; I told you earlier, why wasn't it added? | Decisions given in chat are written into the docs when they are made | Process | **Missing** | `AGT-9`; `docs/MEMORY.md` §1, §6 |
| R55 | 24 Nov | All limits and caps of every business will be set when creating the business from the admin dashboard | (Unclear, see below) | Billing, admin vs owner | Needs the owner | Nothing written |
| R56 | 24 Nov | 4 minutes is way too much; 1 minute if there is no voice is good | (Unclear, see below) | Calls | Needs the owner | Nothing written |

## Code does not follow this yet

The documents now say these; the code does not do them yet. No code was changed by this audit.

| Rule | What is missing | Where |
|---|---|---|
| R34 Live usage | The usage card refreshes every minute, on focus and on a usage notice; it doesn't update within seconds of a call or message | `web/src/UsageLive.jsx` (`REFRESH_MS = 60000`); would need a Realtime subscription limited to the business |
| R28 to R32 Billing | Nothing sends invoice, Paid or renewal emails, there is no auto debit setting or Pay now in the app, and no billing texts: Stripe isn't connected (billing step 4) | `web/src/settings/BillingPanels.jsx`, `billing-worker`, `billing-webhook`, `platform-emails` (design in `docs/BILLING_EMAILS.md`, `docs/PAYMENTS_ARCHITECTURE.md` §6.11) |
| R02 Picture colours | The picture's colours apply only in the Glass look, behind "Match colours to the picture" | `web/src/appearance.js` (palette applied with Glass only) |
| R46 Bot check | Website forms have no bot check yet (deferred on purpose until the Zella Voice website) | `web/supabase/functions/website-lead` |

## Needs the owner's answer

1. **Who fixes CodeRabbit's findings (R26).**
   - 11 Nov: "You fix" and "So that coderabit can review it".
   - 15 Nov: "make sure you let coderabbit fix then you merge", "let coderabbit fix", "you have to let me know when to
     click on fix comments".
   - Today the docs say CodeRabbit fixes when the owner ticks Fix comments (`docs/MEMORY.md` §1), while recent pull
     requests have had Claude fix the findings. Which is the rule?
2. **Who sets limits and caps (R55).**
   - 24 Nov: "all the limiuts and capping of every buisness will be set at the time of cretaing buisnss from teh admin
     dashbord".
   - The documents (D-44, REQ-BIL-23, REQ-BIL-32, decided 13 Nov 2026) say the business owner chooses what happens at
     100% of minutes (stop, auto reload or pay as you go) and sets the monthly spending limit. The reply on 24 Nov
     also noted that "calls at once" (default 10) has no setting in Create Business, and that an admin can't cap the
     owner's spending limit. Should all of these be set by Zella Voice in Create Business, and can the owner change
     them later?
3. **Ending a silent call (R56).**
   - 24 Nov: "4  min is way more 1 mint if no voice is good", then "Yesse" to a question that asked whether this meant
     the 4 minute wait for an approval popup or ending a phone call after 1 minute of silence.
   - The reply treated it as the popup. If it meant calls, the rule would be: end a call after 1 minute with no voice.
     Which did the owner mean?
4. **Stopping urgent texts (R04).** On 28 Oct the owner said "later" to a switch that lets a person stop urgent
   texts. It is written as later; it needs a decision before texting goes live.
