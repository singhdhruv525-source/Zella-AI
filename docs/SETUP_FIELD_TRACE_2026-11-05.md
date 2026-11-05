# Setup wizard: every field from the screen to what the business actually gets (5 Nov 2026)

For each answer in the admin's setup wizard (`web/src/CreateBusinessWizard.jsx`), this records:
- **Saved** — where the `owner-provision-business` action stores it.
- **Used by** — the code that reads it again: the AI receptionist's prompt and tools (`zella_brain_context`,
  `zella_brain_prompt_base`, `zella_ai_tool`, `zella_ai_booking`, `zella_transfer_destination`, `zella_assistant_config`),
  the CRM, or n8n.
- **Enforced** — whether the server holds to it, rather than only showing it.

How this was checked:
- The source of every live database function, from `sql/baseline` (identical to production), plus the 17 pending
  migrations.
- The edge functions and the n8n sources.
- Read-only counts in production (no customer content read).

## Result

| Step / field | Saved | Used by | Enforced | Verdict |
|---|---|---|---|---|
| **Business**: name, industry, time zone, phone, website, city, state | `businesses` | prompt (`zella_brain_context`), availability (time zone), terminology | yes | OK |
| Business: street address, postal code, country | `businesses` | prompt gives the address when a street or city is set | n/a | OK |
| Business: legal name, business email | `businesses` | admin views, emails | n/a | OK (not used on calls; not meant to be) |
| **Owner**: name, email | owner invitation (`business_invitations`, role owner) | setup completion, owner invite | yes | OK |
| Owner: phone | `businesses.setup_data.owner.phone` | **nothing**. A transfer to "Business owner" never uses it | no | **D4** |
| **Hours & services**: opening hours | `business_hours` | prompt, `check_open_hours`, `zella_available_slots`, after-hours replies | yes | OK |
| Services (name, length, price, description) | `ai_agent_configs.knowledge_base.services` | prompt ("the only services you may offer"), booking length | yes | OK |
| About the business, service area, industry details | `knowledge_base.about / service_area / business_details`, `setup_data.operations` | **nothing on calls**. The prompt says facts come only from `search_knowledge`, which searches `knowledge_items` only | no | **D2** |
| Booking: default length | `appointment_rules.default_minutes` | **nothing**. `zella_ai_booking` uses 30 minutes when no length is given | no | **D3** |
| Booking: minimum notice, how far ahead | `appointment_rules.min_notice_hours / max_days_ahead` | **nothing**. Times are offered from now, and booking allows up to a year ahead | no | **D3** |
| Booking: buffer between appointments | `appointment_rules.buffer_minutes` | **nothing** | no | **D3b** (now fixed as B1 in zella_booking_buffers.sql, pending) |
| **Team** members | `staff_members` | `zella_available_slots` (who can be booked), CRM | yes | OK |
| **AI receptionist**: name, personality, instructions (saved as `tone`) | `ai_agents.name`, `ai_agent_configs.personality / tone` | prompt | n/a | OK |
| Greeting, language ("English and Spanish") | `ai_agent_configs.voice_config.greeting / language` | **nothing**. The live assistant reads `business_languages` (Settings > Languages). Production: the salon in testing chose English + Spanish and a greeting in setup and has no `business_languages` row, so it answers in English with the default greeting | no | **D6** |
| FAQs, policies (cancellation, refund, payment, emergency, appointment, other) | `knowledge_base.faqs / policies` | **nothing on calls** (same as D2). The CRM Knowledge page says "No approved answers yet" for a business whose FAQs were entered in setup | no | **D2** |
| Abilities: book, reschedule, cancel appointments | `capabilities` + `appointment_rules.can_book / can_reschedule / can_cancel` | **nothing**. No function reads `can_*`; the booking tools are offered and work. Production: one business (`4478f7be…`, in setup) has "book" switched off and would still book | no | **D1** |
| Abilities: answer questions, answer calls, texts, emails, collect details, follow up leads, take messages | `capabilities` | the versioned agent config (draft, check, publish) | no (the tools don't read them) | documented; the channel abilities depend on texting and email being live |
| Escalation triggers (asks for a person, upset, unknown answer, emergency…) | `escalation_rules.triggers` | only "emergency" (`zella_ai_voice`); the prompt always transfers on request, upset or "can't help" | partly | **D5** (now fixed in zella_escalation_rules.sql, pending) |
| Transfer to (owner, manager, team member, phone number) + phone | `escalation_rules.transfer_to` | `zella_transfer_destination` uses `transfer_to.phone` only | yes, when a phone is typed | **D4** when no phone is typed |
| Restrictions ("don't discuss…"), booking notes | `knowledge_base.restrictions`, `appointment_rules.notes` | **nothing** | no | **D7** (now fixed in zella_escalation_rules.sql, pending; delivery to Vapi is K3) |
| **Phone & integrations**: number choice, area code, forwarding | `setup_data.integrations.phone` | Zella team (admin Voice & numbers); not automatic | n/a | OK (admin task by design) |
| Call transfer number | `setup_data.integrations.transfer_number` | **nothing**. Transfers read `escalation_rules.transfer_number` | no | **D4** |
| Calendar, email provider, lead sources | `setup_data.integrations` | admin view; calendar now has its own connection (pending migration 16) | n/a | OK (intent only) |
| **Spam protection** | `spam_settings` | voice screening, SMS and email checks | yes | OK |
| **Automations** on/off and notify via | `automations` (paused until go-live) | n8n jobs and claims | see item 4 (messaging audit) | checked in item 4 |
| **CRM setup**: modules, words | `business_modules`, `businesses.terminology_overrides` | navigation, row-security module checks (`zella_module_on`), prompt words | yes | OK |
| Verification documents | `business_verification_documents` + private storage | setup completion | yes | OK |

## Defects confirmed (fixed in `sql/zella_setup_enforcement.sql` and `owner-provision-business`; not applied)

- **D1.** Booking abilities switched off in setup are now enforced:
  - the tools are left out of the assistant's list;
  - if the AI calls them anyway, they are refused.
- **D2.** Setup FAQs, policies, "about", service area and industry details become searchable knowledge for the AI:
  - stored as `knowledge_items` marked `setup:…`, and kept in step whenever they change;
  - items an owner adds never change.
- **D3.** Booking uses the setup's default length, minimum notice and how-far-ahead limits, both for the times offered
  and for the booking itself.
- **D4.** Transfer number: the first that is set is used.
  1. The receptionist step's phone.
  2. The integrations step's transfer number.
  3. For "Business owner", the owner's phone.

  It is written where transfers look.
- **D6.** Setup's language and greeting are saved to the live language settings (`business_languages`). The same
  validation as Settings > Languages applies.

Not fixed (documented, need a decision):
- **D3b:** the buffer (since fixed as B1, pending; see docs/DEFECT_INVENTORY_2026-11-05.md).
- **D5:** escalation triggers (since fixed, pending).
- **D7:** restrictions and booking notes (since fixed, pending; delivery to Vapi is K3).

## Evidence note (added 5 Nov, evening)

Statements here about production are one of:
- **current configuration** read on 5 Nov;
- **retained history**: the audit log since 22 Oct and reminders since 23 Oct, which show every reminder ever queued
  was a text and no automation change mentioned an AI-call channel;
- **local tests** on isolated copies.

None comes from a provider test: no real Vapi call, Shopify store, SMS, email or Google request was made. "Changes no
existing row" or "no customer affected" means within that configuration and history, not a proof about earlier
states that left no record. Per-issue labels and statuses: `docs/DEFECT_INVENTORY_2026-11-05.md`.
