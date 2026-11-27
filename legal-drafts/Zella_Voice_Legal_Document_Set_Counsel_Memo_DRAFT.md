# Zella Voice legal document set: drafting notes for counsel

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Internal memo for the owner and counsel. Not for publication.

Date: **[MEMO DATE]**

## 1. Purpose

1.1 This memo accompanies version 0.2 drafts of the Zella Voice legal document set: nine documents plus this memo. Each document was drafted from the project's own source documents (the architecture, product, rulebook, project memory and database schema documents, and the version 0.1 privacy policy and terms held in the database migration for legal documents). Nothing in the set describes a feature, certification or guarantee that those sources do not support, with two exceptions: encryption at rest and backups with point in time recovery are stated in the public documents as intended controls, but neither is verified in the source documents (launch blockers 16 and 17). The public documents also describe as operating the controls that are built but not yet live; each is a launch blocker in section 4. Unknown company facts are bold bracketed placeholders.

1.3 **Status (internal; not for publication).** Zella Voice has not launched. The live project holds demo businesses only and no real customer data, and every sending and calling switch (calls, texts, emails and the others) is off. The public documents in this set are nevertheless written as the final, published versions for a live, operating service, as the owner instructed. They describe each control as the service will provide it at launch. Every place where the product does not yet do what a public document promises is listed in section 4 as a launch blocker.

1.2 No document in the set claims compliance with HIPAA, the GDPR, SOC 2 or any other standard. The source documents state that no compliance is claimed.

## 2. The document set

### 2.1 Structure

| # | Document | Audience | Contents |
|---|---|---|---|
| 1 | Zella Voice Terms of Service | Customers (master agreement) | Terms, with Schedule 1 Acceptable Use Policy, Schedule 2 AI and Call Disclosure Policy, Schedule 3 Content and Defamation Complaints Policy, Schedule 4 Service Level and Support Policy |
| 2 | Zella Voice Privacy Policy | Public | Privacy notice, with section 15 on cookies and browser storage |
| 3 | Zella Voice Data Processing Addendum | Customers | DPA, Annex 1 details of processing, Annex 2 security measures, Annex 3 Subprocessor List, Schedule 1 optional Business Associate Agreement |
| 4 | Zella Voice Messaging Terms | Message recipients and Customers | SMS and email program terms |
| 5 | Zella Voice Order Form (template) | Customers | Plan, Fees, trial, term, add ons, special terms, precedence |
| 6 | Zella Voice Trust and Security Overview | Public | Security controls; vulnerability disclosure policy; security.txt; accessibility statement (section 10) |
| 7 | Zella Voice Team and Partner Agreements (templates) | Internal | Mutual NDA; Contractor Agreement; Employee Confidentiality and Invention Assignment; Founder IP Assignment; Reseller and Referral Partner Agreement (Part E) |
| 8 | Zella Voice Privacy and Security Operations Handbook | Internal | Incident response plan; data subject request procedure; law enforcement and legal request policy; record of processing activities; Employee and Applicant Privacy Notice (Part E) |
| 9 | Zella Voice Consent and Carrier Registration Pack | Customers and Zella Voice | Consent checkbox wording, in call disclosure, recording options, 10DLC brand and campaign text, mismatches with current behavior |

### 2.2 Merge map

| Former separate document | Now |
|---|---|
| Acceptable Use Policy | Terms of Service, Schedule 1 |
| AI and Call Disclosure Policy | Terms of Service, Schedule 2 |
| Content and Defamation Complaints Policy | Terms of Service, Schedule 3 |
| Service Level and Support Policy | Terms of Service, Schedule 4 |
| Cookie and Browser Storage Notice | Privacy Policy, section 15 |
| Subprocessor List | Data Processing Addendum, Annex 3 (also kept at a public location) |
| Business Associate Agreement template | Data Processing Addendum, Schedule 1 (optional) |

The separate files were removed after merging; their full text is inside the merged documents.

**Placement of the optional documents.** The Accessibility Statement is section 10 of the Trust and Security Overview, because both are short public trust pages and readers look for them together. The Reseller and Referral Partner Agreement is Part E of the Team and Partner Agreements. The Employee and Applicant Privacy Notice is Part E of the Operations Handbook, because it is a privacy notice that sits with the other privacy procedures and the record of processing, rather than with the signed agreements.

### 2.3 How they fit together

2.3.1 **Defined terms.** Section 2 of the Terms of Service defines every shared term. Every other document adopts those meanings.

2.3.2 **The Agreement** is the Order Form, the DPA (with its Annexes and Schedule 1 when signed), the Terms with Schedules 1 to 4, and the Messaging Terms. The Privacy Policy is a notice, not part of the Agreement.

2.3.3 **Order of precedence** (Terms section 26, repeated in the Order Form and the DPA): a BAA for PHI only; then Order Form special terms, only where they expressly override a named provision; then the DPA for Customer Personal Data; then the Terms; then the Policies (Schedules 1 to 4 and the Messaging Terms). Transfer clauses prevail over the DPA. Marked "as counsel prefers".

2.3.4 **Changes.** Zella Voice may update the Terms and the Policies on notice under Terms section 22; section 22.4 confirms this for Schedules 1 and 4.

2.3.5 **Acceptance.** The owner onboarding journey records acceptance on the server; the Terms' clickwrap clause relies on it. That step is built but not applied (launch blocker 21 in section 4).

## 3. Retention: two conflicts to resolve

3.1 The architecture (section 20, REQ BIL 49) and the rulebook (PRV 4) say a canceled Customer's data is deleted 30 days after cancellation, after a final export offer. The version 0.1 privacy policy said 90 days. The product document notes that the database falls back to 90 days when no value is set, and the admin page labels it "Pending legal review".

3.2 Every public document uses the placeholder **[CANCELLATION RETENTION PERIOD]** for this period, wherever it appears (Terms 12.7, Privacy Policy section 10, DPA 12.2, Trust overview section 5). The rulebook's 30 days is the proposal; the database falls back to 90 days. To resolve: decide the period, replace the placeholder with it everywhere it appears, and set the production database value to match through a reviewed migration, applied only with the owner's explicit approval for that specific change (NN 3, NN 4). Each kind of data keeps its own deletion schedule during the export window, so recordings and transcripts are still deleted 90 days after the call and the window covers only data still held.

3.2.1 **Businesses already canceled.** The database stores each canceled business's deletion date (retention_until) once, at cancellation, from the retention_days value in force at that time. Changing the value later affects only later cancellations, unless a reviewed migration recomputes the stored dates for businesses already canceled. Owner decision, with counsel's input: whether a new period applies to businesses already canceled, and if so, run that migration only with the owner's explicit approval for that specific change (NN 3, NN 4). The documents should then say whether the period in force at cancellation applies.

3.3 **Recordings: 90 days or 30 days.** The owner decided on 18 November 2026 that call recordings and transcripts are kept 90 days (architecture section 23.1c; rulebook PRV 4). The earlier proposal was recordings 30 days and transcripts 90 days. The per kind retention settings built on 16 November 2026 (not deployed) still default to that earlier proposal, recordings 30 days, while the privacy retention migration (not applied) sets both to 90 days. Every period is pending legal review. **The drafts use 90 days for recordings and transcripts.** Decide between 90 days (current owner decision) and 30 days (earlier proposal), and make the settings match before publishing, through a reviewed migration applied only with the owner's explicit approval for that specific change (NN 3, NN 4).

3.4 **Automatic deletion.** The public documents state the deletion periods as operating controls. The purge jobs for recordings, transcripts and message contents, and the deletion of copies at Vapi, are built but not applied, and their switches are off; this is launch blocker 3 in section 4.

3.5 Other periods used consistently across the set: recordings and transcripts 90 days; message contents 2 years; audit and security logs 7 years; Owner identity documents 90 days after the check (replaced copies 30 days); backups cleared within 90 days after cancellation; account deletion 30 days after confirmation; numbers released 30 days after cancellation; legal holds override. All periods are marked pending legal review in the product (PRV 4). The consistency of the recording period across the set (section 9) depends on the decision in section 3.3.

## 4. Launch blockers

**The public documents must not be published until each blocker below is built and verified in the product, or the promise is removed from the public text.** No public text is published while it is untrue. Each fix that changes production needs the owner's explicit approval for that specific change (NN 3, NN 4). The Owner Action Pack lists the same items as owner actions before launch. **Exception for recording (blockers 1 and 33; actions 1 and 33):** removing the public promise is not an option for either. Call recording must stay disabled for every Customer until recording consent and caller disclosures have passed legal review, whatever the public text says, and the live Vapi recording setting must be confirmed, for the account and for each assistant, and the result recorded with the date and the person who checked (blocker and action 1). Before recording is enabled for any Customer, stored recordings must hold no spoken card details, including audio kept by Vapi and audio behind any stored recording link, with the control verified and legally reviewed (blocker and action 33); this is mandatory whatever happens to the public text. **Separation between businesses (blocker and action 31)** cannot be cleared by removing a public promise either: automated isolation tests that run on every change, and the refuse and alert rule for conflicting call identifiers with its automated conflict test, are required before launch whatever the public text says.

**Card details.** Zella Voice's policy is that it never collects or stores full card numbers or security codes, and never stores card details a caller speaks; for billing notices it keeps only the card brand, last 4 digits and expiry from Stripe (owner decision, 27 Nov 2026; blocker 22). Card masking (blocker 11) must therefore be built and verified before any live call is answered or placed, and blocker 33 before recording is enabled for any Customer, even if the public promise of masking were removed from the text, because callers may speak card numbers on any call.

| # | Promise in the public documents | Where it is promised | Product fix needed |
|---|---|---|---|
| 1 | Call recording off by default | Terms 5.3; Schedule 2, 4.1; Privacy Policy 3.2 and 6.1; DPA Annex 1; Consent Pack 4 | Verify the live Vapi recording setting (today Vapi's own settings decide whether a call is recorded); send recording off explicitly in the assistant configuration to Vapi (an approved call path change); apply the recording policy; confirm at Vapi, for the account and for each assistant, that recording is disabled, and record the result. Recording must stay disabled for every Customer until the recording consent rules and caller disclosures have passed legal review |
| 2 | AI disclosure cannot be removed and is added in the caller's language; recording notice line | Schedule 2, 3.1, 3.2 and 4.2; Privacy Policy 5.2; Consent Pack 3 | Apply the call disclosure migration and confirm on a test call |
| 3 | Automatic deletion: recordings and transcripts after 90 days, message contents after 2 years, deletion of Vapi copies | Terms 12.7; Schedule 2, 4.5; Privacy Policy 6.3 and 10; DPA 12.1 and 12.4; Trust overview 5 | Apply the privacy retention migration, record legal approval of the periods, and switch on the purge job and Vapi deletion |
| 4 | Deletion after cancellation and after an account deletion request | Terms 12.7; Privacy Policy 10 and 11.3; DPA 12.2 and 12.3; Trust overview 5 | Decide the cancellation period (section 3.2), apply the account deletion migration, and schedule the purge |
| 5 | A recorded consent or a stated consent basis before any automated service call or text; leads without a basis never contacted automatically | Terms 5.4; Schedule 2, 5.2; Messaging Terms 10.1 and 11.2; Privacy Policy 7.1; DPA Annex 2; Consent Pack 2.4 | Make zella_can_contact and the senders require a recorded consent or stated basis for service purposes, not only the absence of an opt out |
| 6 | Frequency limit (one unprompted message a day unless the plan sets another) | Messaging Terms 4.1 and 11.2; Schedule 2, 5.2; Privacy Policy 7.1; DPA Annex 2 | Count earlier messages and calls per person and block at sending |
| 7 | Contact hours in the recipient's time zone, with every window, and calls within the Customer's calling hours | Messaging Terms 4.2 and 11.2; Schedule 2, 5.2; Privacy Policy 7.1; DPA Annex 2; Consent Pack 5.3A | Enforce COM 3 in the text sender and the call claims (today: marketing texts only, 8 a.m. to 9 p.m. in the Business's time zone; calls 9 a.m. to 7 p.m. in the Business's time zone), and make a message due outside its window move to the next allowed time in that window, as Messaging Terms 4.2 states, instead of being refused (today zella_prepare_sms refuses a marketing text outside its hours with the reason quiet_hours and does not reschedule it); verify with tests that nothing due outside its window is dropped |
| 8 | "Don't call me" honored immediately, including for automatic callbacks; the AI Receptionist records it | Terms 5.6; Schedule 2, 5.2; Messaging Terms 6.4; Privacy Policy 7.2; DPA Annex 2 | Make zella_claim_callbacks check the do not call flag and call opt outs, and let the receptionist record the request |
| 9 | Texts start only after 10DLC registration is approved | Terms 5.5; Messaging Terms 10.2; Consent Pack 1.3 | Add a per Customer registration check (or per Customer text switch) to the text sender |
| 10 | STOP confirmation text; HELP reply with contact method sent to every number; START confirmation | Messaging Terms 6.1, 6.2 and 7; Consent Pack 5.4 | Build the STOP and START confirmations and change the HELP reply and its matching |
| 11 | Spoken card details (card numbers, security codes and expiry dates) masked in transcripts and summaries | Terms 9.5; Privacy Policy 3.1 and 3.2; DPA Annex 1, Annex 2 (payment card details row) and Annex 3 (Stripe row); Trust overview 5 | Detect all card details (card numbers, security codes and expiry dates). Mask them in vapi-call-events.js before p_transcript and the summary are passed, and in the database before calls.transcript and calls.summary are written; cover the copies held by Vapi; clean up existing transcripts and existing summaries (calls.transcript and calls.summary) with the same detection, masking and verification checks; and verify that no stored transcript, summary or provider copy still holds any card detail. Before any live call, also verify, with an approved test call, that the provider side controls stop card details being stored before the webhook runs, at Vapi (on the account and on each assistant) and at every provider that processes caller audio or its text, including Deepgram, Cartesia and ElevenLabs where enabled. For each provider, confirm the setting that stops card details being stored (or confirm that it keeps no audio or text), and record the result, the date and the person who checked. If Vapi's account controls also cover a provider reached through Vapi, record that and name each provider they cover, with the evidence; otherwise confirm that provider's own setting; the downstream masking, cleanup and verification above are still required. Card details are never stored. Owner decision (27 Nov 2026): rule AI 25, approved for the rulebook, a platform receptionist rule that the AI Receptionist never asks for, reads back or records card or bank details, and sends the caller to a secure payment link or to staff follow up; it is in draft pull request 146, not yet applied, and must be applied with approval and verified before any live call. Card digits a caller speaks before being stopped can still reach the transcript, so the masking and the provider checks above remain required |
| 12 | Legal holds respected on erasure | Privacy Policy 11.2 and 11.3; DPA 9.1 and 12.5 | Make zella_erase_customer check zella_retention_on_hold, keep held data and skip its provider deletion |
| 13 | Whole business export, its second owner approval, and the export exclusions | Terms 12.6; Privacy Policy 11.1; DPA 9.1 and Annex 2; Trust overview 4 and 5 | Apply the business export migration and deploy the export worker and its approval |
| 14 | Two step sign in for administrators and Owners; fresh code for admin changes; masked contact details in admin tools | Privacy Policy 13.1; DPA 5 and Annex 2; Trust overview 3 | Deploy the admin two step sign in, owner onboarding, admin sessions and masking work |
| 15 | Leaked password protection | Trust overview 3 | Turn it on in the sign in provider |
| 16 | Encryption at rest; HTTPS for voice provider webhooks | Privacy Policy 13.1; DPA Annex 2; Trust overview 5 | Confirm encryption at rest with the hosting provider and that the live Vapi server address uses HTTPS |
| 17 | Backups with point in time recovery | Privacy Policy 13.1; DPA Annex 2; Trust overview 5 | Enable point in time recovery and run a restore drill |
| 18 | Security headers with an enforcing content security policy | Trust overview 6 | Switch the content security policy from report only to enforcing after a clean release |
| 19 | Caller verification with confirmation codes | Schedule 2, 2.3; Trust overview 6 | Apply the caller verification migration |
| 20 | Silence timeout, concurrent call limit and maximum call length | Terms 8.5; Schedule 2, 6.7 | Apply the silence timeout and call limits migrations and set the maximum call length |
| 21 | Clickwrap acceptance recorded; onboarding with identity check and plan acceptance | Terms 1.2, 4.1 and 23.1 | Apply the owner onboarding and legal acceptance migrations with approval; choose and connect the identity verification provider (until one is connected, identity is checked by manual review of the uploaded documents in Verification); deploy the owner-onboarding and identity-webhook edge functions with approval; verify with an approved test that a provider confirmed identity check reaches identity-webhook and marks identity verified only on the provider's approval, and that checkout stays locked until then; and deploy the screens |
| 22 | Payments: trial at checkout, billing, renewal notices, refunds, packs, automatic reload, pay as you go, failed payments, usage alerts and limits | Terms 9 and 10; Order Form 3 to 6 | Switch on payments with approval, build pay as you go charging, align trial checkout with payment before going live, and set pack prices. Setup fee during a trial: confirm in the Stripe sandbox that a trial with a nonzero setup fee charges no setup fee before the trial ends (Terms 9.2 says it is charged with the first paid billing period), and record the owner decision in docs/PAYMENTS_ARCHITECTURE.md section 15 to match Terms 9.2; if the owner chooses to charge it at the start of the trial, Terms 9.2 and the Order Form must be amended before publication. Usage limits, as separate steps: (a) migrations: confirm sql/zella_usage_enforcement.sql is applied with both switches off, and apply sql/zella_call_limits.sql only with approval (it starts the per business limit on calls at once, even with the switches off); (b) prerequisites before any fallback routing: every live Customer has an allowance set up (once the call limits migration is applied, an unknown allowance closes calls instead of answering them) and a valid fallback number recorded, and provider spending and concurrency caps are set at Vapi, the language model provider and ElevenLabs; (c) an approved staging test call, with the calls switch on for one demo business and a test fallback number the owner controls, confirms that Vapi transfers the call to the fallback destination; (d) only then, with the owner's explicit approval for that specific switch, turn on usage_enforcement.calls, and later usage_enforcement.messages with a separate approval. Billing notices and card details: owner decision (27 Nov 2026), brand and last 4. Billing emails may show the card brand, last 4 digits and expiry month and year, read from Stripe (for example "your Visa ending 4242"), so Zella Voice keeps those limited details, and never full card numbers or security codes, in its billing records and email log (Terms 9.5; Privacy Policy 3.1, 4.2 and 10; DPA Annex 3; Trust overview 5). Recorded in docs/PAYMENTS_ARCHITECTURE.md (section 9 and lane F), docs/BILLING_EMAILS.md, docs/MEMORY.md and docs/OWNER_DECISIONS_AUDIT.md (R59). Still to build: store those fields from Stripe, set the billing records retention period, and change the templates that need them (A2, A3, A4, A6, B1, B2 card expiring soon, C1, C2, C3, D1 and H2 card updated in docs/BILLING_EMAILS.md). Those templates stay held (MISSING_FIELD) until they are changed to use these fields; this blocker stays open until that is built and verified |
| 23 | First Billing Date without a trial is the day checkout completes | Terms 9.3; Order Form 5.1 | Align the architecture (REQ BIL 17, first sign in) and the checkout code on one date |
| 24 | Data rights request reminder | DPA 9.1 | Switch on the daily job that sends the reminders |
| 25 | Support replies in the app, honest status page wording, calls to the Fallback Number | Schedule 4, 2.1, 3.2 and 3.3; Trust overview 7.1 | Apply the support replies, status page and usage enforcement migrations |
| 26 | Consent evidence stored for each source | Consent Pack 2.3 and 2.4 | Confirm the product stores the evidence listed for each source, or change the list |
| 27 | Templates match the registration samples | Consent Pack 5.3 | Change the cancellation template to American spelling ("canceled") and remove the "Reply C to confirm or R to reschedule" wording |
| 28 | Receptionist asks consent before confirmation texts | Consent Pack 3.4 | Confirm the receptionist's script asks the question in 3.4 |
| 29 | Voicemail prompt and voicemails | Consent Pack 4 | Build inbound voicemail, or remove the voicemail prompt |
| 30 | Recording option C (consent question with a no that turns recording off) | Consent Pack 4 | Build the product change, or do not offer option C |
| 31 | Separation between businesses | Trust overview 2; DPA Annex 2 | The public text now claims only the database policies and function checks. Before launch, build automated isolation tests that cover every table, view, function and endpoint and run them on every change (today the isolation tests exist in tests/security but there is no automated run on every change). Also resolve conflicting call identifiers: when the called number and the Vapi phone number identifier point to different businesses, zella_business_for_number today picks the business of the Vapi identifier without flagging the conflict. Owner decision (27 Nov 2026): refuse and alert. When the two point to different businesses, neither is used: the call is handled as a call to an unknown number, with a neutral message that names no business; no business configuration, caller context or records are loaded; and Zella Voice admins get an urgent alert. A call must never use another business's configuration, caller context or records. The fix and an automated test of a conflicting pair in zella_business_for_number's routing (number registered to one business, Vapi identifier to another; 33 isolated tests) are in draft pull request 146, not yet applied. This blocker stays open until pull request 146 is applied with approval and verified, and the conflict test runs on every change |
| 32 | Backups cleared within 90 days after cancellation | Terms 12.7; Privacy Policy 10; DPA 12.2 (all three state 90 days) | Set and verify an expiry policy for every backup copy (database backups, point in time recovery history, file storage and any provider backups), with evidence that each is cleared within 90 days after cancellation, or within whatever period the public documents finally state |
| 33 | Call recordings keep no spoken card details | Terms 9.5; Privacy Policy 3.1; DPA Annex 1 and Annex 2 (payment card details row); Trust overview 5 | Before recording is enabled for any Customer, ensure stored recordings contain no spoken card details, including the audio kept by Vapi and the audio behind any stored recording link (technique chosen by the owner and engineering), verify the control, and obtain legal review; recording also stays disabled under blocker 1 until legal review |
| 34 | Automatic payment switch: off from the next renewal; first payment after a trial always charged to the saved card | Terms 9.2 and 9.3; Order Form section 4 | Build the automatic payment switch (Stripe collection by invoice when off, as the payments architecture designs it), make it take effect from the next renewal, and verify that the first invoice at the end of a trial is always charged to the card saved at checkout; the billing emails in the code already say "from your next renewal" |
| 35 | The file for one End User's request leaves out the transcripts of Customers in Regulated Industries | DPA 9.1; Privacy Policy 11.1 | zella_export_customer_data returns call summaries and transcripts for every business today. Change it (a new, version guarded migration with an exact rollback, applied with approval) to leave out transcripts when the business is in a Regulated Industry, test it on the isolated database, and verify the file; until then staff remove them by hand (Handbook B2 step 3) |
| 36 | Emails from a Business come from its own address (verified domain or connected Gmail or Outlook mailbox), otherwise in its name from the Zella Voice no reply address with replies to the Business | Messaging Terms 1.3; Terms 15; Privacy Policy 8.1; DPA Annex 3 (Google and Microsoft mailbox row) | The no reply fallback with the Business's name and reply address is built (zella_prepare_email). Build and verify per business domain verification, mailbox connection for Gmail and Outlook and sending through either, with the fallback when a mailbox reaches its provider's daily cap; sign Google and Microsoft data processing terms for mailbox sending; if mailbox sending is not ready at launch, keep the "where enabled" rows and confirm the fallback on a test email to an owner controlled address |
| 37 | Deletion suspended for a transcript or recording named in a pending return request under a BAA, until returned and for no longer than the BAA return period, including at the end of the export window and on account deletion | DPA 9.1, 12.1 to 12.5 and S1.6.3 (DPA Schedule 1); Privacy Policy 6.3, 10, 11.2 and 11.3; Terms 12.7 and Schedule 2, 4.5; Trust overview 5; Handbook B2 steps 5, 6, 8 and 9 (manual check until built) | The retention, purge and account deletion jobs know legal holds (zella_retention_on_hold) but not BAA return requests. Build the delivery, reminder and destruction process in S1.6.3(a) and a per item return request suspension that every deletion path (90 day deletion, customer erasure through zella_erase_customer, purge after cancellation, account deletion and Vapi deletion requests) checks, and that lets customer erasure leave out only the named item and its Vapi copy while erasing the rest on time, with the time limit, tested on the isolated database; do not offer the HIPAA option until it is verified |
| 38 | Pro rata refund when a Customer cancels over an adverse amendment, effective the day before the amendment, or over an adverse change that took effect sooner, effective on receipt of notice | Terms 22.2 and 22.3 | Decide the refund period and the adverse change cancellation window (Terms 22.3); set up the cancellation on the chosen date (the day before the amendment under Terms 22.2, or on receipt of the notice for an adverse change that took effect sooner under Terms 22.3) and the pro rata refund through Stripe with the payments work (blocker 22), and verify it with an approved test before relying on it |
| 39 | Separate, optional marketing checkboxes for calls and for texts, each recording a consent for its own channel only | Consent Pack 2.2 and 2.4 | The website form sends one marketing_consent flag, and zella_capture_web_lead records it as a marketing opt in for texts and for email, and none for calls. Change the form and the function (a new, version guarded migration with rollback, applied with approval) to carry one flag per channel and record each separately with the evidence in Consent Pack 2.4; record email marketing only from wording that names email (counsel to confirm, Consent Pack 2.2) |
| 40 | Earned, unapplied service credits paid out in the payout cases (termination under Schedule 4, 4.6; cancellation under Terms 22.2; termination for Zella Voice's breach; Zella Voice ending the Agreement other than for Customer's breach), and forfeited when Customer leaves by its own choice | Terms Schedule 4, 4.3, 4.6 and 4.7 | Owner decision (27 Nov 2026): forfeit if they leave. Set the credit payout period; track earned credits; pay them out through Stripe in the payout cases only, with the payments work (blocker 22); obtain counsel's view on forfeiture in each launch jurisdiction |
| 41 | Businesses can connect work Microsoft accounts (Outlook mailbox and calendar) | Terms 15; Privacy Policy 8.1; DPA Annex 3; Messaging Terms 1.3 | Microsoft publisher verification. Done 27 Nov 2026: the Zella Voice app is registered in Entra for multitenant and personal accounts, and zellavoice.com is verified in Entra and set as the publisher domain. Still to do: join the Microsoft AI Cloud Partner Program with a work account, and add the Partner ID under Branding and properties for the verified publisher mark. Any privacy policy and terms links added under Branding and properties wait until those pages are published as the version in effect under the publication rule in this section (the same links and version as blocker 42). Needed before businesses outside the test users can connect work Microsoft accounts |
| 42 | Businesses can connect Gmail and Google Calendar | Terms 15; Privacy Policy 8.1; DPA Annex 3; Messaging Terms 1.3 | Google OAuth app verification. Done 27 Nov 2026: zellavoice.com is verified in Search Console and added as an authorized domain. Still to do once the legal pages are public: the app's /privacy and /terms routes (web/src/LegalPage.jsx) show the version that zella_legal_current returns from legal_documents; today that is the v0.1 draft from sql/zella_privacy_retention.sql (built, not applied), marked as a draft, and app hosting is not connected. Under the publication rule in this section, the v0.2 Privacy Policy and Terms (or the version counsel approves) must first be approved by counsel and published by the owner as the version in effect, served at **[PUBLIC PRIVACY POLICY URL]** and **[PUBLIC TERMS URL]** on zellavoice.com or a subdomain, with no draft notice and the same version number as submitted. Verification waits until then. Then add those exact links and that version, write the scope justifications (openid, email, gmail.send, calendar.events), record a demo video, then publish the app and submit it for verification. These are sensitive scopes, not restricted ones, so no security assessment is needed. Needed before businesses outside the test users can connect Gmail or Google Calendar. Owner decision (27 Nov 2026): publish first. The approved documents are published with the Gmail and Google Calendar wording, and Google verification is then submitted. Until Google approves, the Connect Gmail and Connect Google Calendar options stay hidden from every business outside the test users; Outlook and the business's own verified domain keep working. Build item: hide the Google connect options until verification is approved, and verify on a test business that they are hidden and that Outlook and domain sending still work. This recorded path satisfies the publication gate for the Gmail and Google Calendar wording |
| 43 | Trial of 5 days with 20 AI minutes, 5 texts and 5 emails | Order Form 4; Terms 9.2 | What billing provides today: the billing_rules defaults in sql/zella_billing_allowances.sql (applied 14 Nov 2026) are trial_days 5, trial_minutes 20, trial_texts 5 and trial_emails 5, and zella_billing_open_period grants those as trial buckets when a subscription is in trial; admins can change billing_rules, business_plans.trial_enabled defaults to false and is set per business, and no trial reaches a Customer until trial checkout and payments are switched on (blocker 22). So the trial allowances are not yet provisioned for any Customer. Before publication, the Order Form and Terms trial terms and the billing settings must agree. **[OWNER DECISION: HOW THE TRIAL TERMS AND THE BILLING SETTINGS ARE KEPT IN AGREEMENT]** |

## 5. Open decisions for the owner

1. Retention after cancellation: 30 days (proposed) or 90 days (database fallback); a placeholder in every document until decided (section 3.2). Also: retention of call recordings, 90 days (used; owner decision of 18 November 2026) or 30 days (earlier proposal still in the per kind settings) (section 3.3).
2. Publicity: the Terms take the safer default (no use of a Customer's name without written consent). Confirm or choose an opt out model.
3. Whether to publish an uptime target. The source documents say there is no formal uptime guarantee at launch and service credits are the remedy; the rulebook's internal service level targets are not published.
4. Founding customer price terms (open decision D 47).
5. Identity verification provider (Persona was recommended; none is connected).
6. Monitoring provider (D 31).
7. Governing law, forum, arbitration and the optional class action and jury waiver.
8. Liability cap floor amount.
9. Notice periods: changes to the Agreement, termination for convenience, Subprocessor changes, audit notice, complaint acknowledgment.
10. Support hours and holidays (the support module's default setting is Monday to Friday, 9 a.m. to 5 p.m. New York time).
11. Whether to offer the HIPAA BAA at all (D 49).
12. Maximum call length to publish (20 minutes in policy, 10 live).
13. Whether a STOP confirmation text is sent, and the HELP reply content (today: "{business}: for help please contact us directly. Reply STOP to opt out.", sent only when the number matches a known customer).
14. Tax treatment (D 50).
15. Where the legal documents will be hosted (the /privacy and /terms pages exist; the other documents need a location).
16. Contact addresses: privacy, support, legal notices, content complaints, DMCA agent. Version 0.1 proposed role addresses at the company domain, marked "owner to confirm".
17. Pack prices (in the database design, not yet applied).
18. Identity of the security contact and in scope domains for the vulnerability disclosure policy, and whether to offer bug bounty rewards.
19. Whether to publish a transparency report on legal requests.
20. Which recording disclosure option to use if recording is ever turned on (Consent Pack section 4).
21. Product fixes before 10DLC registration: a STOP confirmation text, a HELP reply with a contact method sent to every number, removal of the "Reply C to confirm or R to reschedule" wording, and American spelling in the cancellation template.
22. Incident response roles and the incident and request log locations.
23. Accessibility contact, response time and known limitations after an audit.
24. Reseller and referral model, commission rate, period and payment timing, and whether to include non solicitation.
25. HR providers and retention periods for applicant, employee and payroll records.
26. Product fix before texts go live: make the text sender use the recipient's time zone when known (rulebook COM 3) and enforce every window in Messaging Terms 4.2 (immediate replies, the missed call text and booking confirmations; follow ups after a call attempt within the Business's calling hours; appointment reminders between 7 a.m. and 9 p.m.; other service and marketing messages between 9 a.m. and 7 p.m.; and moving any message due outside its window to the next allowed time); confirm the hour ranges.
27. Product fix (needs the owner's approval for that specific change): mask payment card numbers that callers speak. The control must detect card numbers (for example digit sequences that pass the card number check) and mask them in the call event handler before p_transcript and the summary are passed to the database (web/supabase/functions/_shared/vapi-call-events.js), and in the database before calls.transcript and calls.summary are written (sql/zella_inbound_calls.sql); zella_redact today only masks long tokens and is not applied to transcripts. It must also cover the copy held by Vapi (provider side redaction settings, or deleting the provider copy), and existing transcripts must be checked and masked.
28. Trial start (checkout start in the payment design, or another point) and whether packs, automatic reload and pay as you go stay unavailable during the trial (Terms 9.2 and 9.7, Order Form section 4).
29. Product fix before texts go live: send the HELP reply to every number that texts HELP, with the business name, a contact method and opt out instructions (Messaging Terms 7, Consent Pack 5.4).
30. Custom trials: checkout supports only the platform's standard trial, stored in the billing rules setting (currently 5 days, 20 minutes, 5 texts, 5 emails); decide whether to build per business trials before offering one (Order Form section 4).
31. First Billing Date without a trial: the start of the first paid period recorded at checkout (current code) or the Owner's first sign in (architecture REQ BIL 17); the Terms, Order Form and billing must use the same date.
32. Objection period after an urgent Subprocessor replacement (DPA 8.3 and Annex 3).
33. Whether a changed cancellation retention period applies to businesses already canceled, which needs a migration to recompute their stored deletion dates (section 3.2.1).
34. Confirm, before publishing, that call recording is explicitly disabled at Vapi (launch blocker 1).
35. Product fix: customer erasure (zella_erase_customer) must check the legal hold (zella_retention_on_hold) before deleting anything, keep held data, and not queue held calls for deletion at Vapi; until then staff check holds manually (Handbook B2 step 5) and the documents carry a "not yet enforced" marker.
36. Trial and payment before going live: decide whether a trial enabled plan always uses trial checkout, or whether trials are blocked when payment is required before going live; the trial length is the platform's billing rules setting, not the Order Form.
37. Confirm the daily data rights reminder job and the incident controls (Handbook A1.2) are switched on before relying on them.
38. Product fix before automated texts go live: require a recorded consent (or a stated consent basis for leads added by hand or imported) before any automated service text, not only a recorded opt in for marketing; today zella_can_contact blocks only opt outs and do not contact flags for service texts.
39. Name the legal hold control owner who rechecks holds before each erasure and completes held erasure requests after a hold is released (Handbook B2 steps 5 and 9).
40. Product fixes before calls or automated texts go live: enforce a per person frequency limit at sending (the senders do not count earlier messages today); make automatic callbacks check the do not call flag and call opt outs, not only the do not contact flag (zella_claim_callbacks); hold calls to the Business's opening hours and the recipient's time zone as COM 3 requires (today 9 a.m. to 7 p.m. in the Business's time zone); and let the AI Receptionist record a caller's "don't call me".
41. Counsel choice on exports of regulated industry transcripts (Privacy Policy section 11.1 and the cancellation row in section 10).
42. Missed call texts: counsel's decision on the missed call basis (Consent Pack sections 2.4 and 5.2A). If rejected, remove missed call texts from the campaign description, opt in flow and sample messages, and switch the missed call text off for every Customer; if approved, keep them.
43. Automatic payment and the first payment after a trial: the rule in Terms 9.2 and 9.3 (switching automatic payment off takes effect from the next renewal, and the first payment after a trial is charged to the card saved at checkout) matches the emails in the code but the switch itself is not built (launch blocker 34).
44. Email sender (owner decision): a Business's emails to its customers come from its own address, on a verified domain or through a connected Gmail or Outlook mailbox; otherwise they go out in the Business's name from the Zella Voice no reply address, with the reply address set to the Business's email address (Messaging Terms 1.3). Google and Microsoft become Subprocessors when a Business connects a mailbox, listed "where enabled" in Privacy Policy 8.1 and DPA Annex 3. Launch blocker 36.
45. Apple (iCloud Mail and Calendar) is not connected at launch (owner decision); no public document mentions Apple. Add Apple to the subprocessor lists and Terms 15 before it is connected.
46. Billing notices (owner decision, 27 Nov 2026): brand and last 4. Billing emails may show the card brand, last 4 digits and expiry from Stripe; Zella Voice keeps only those, never full card numbers or security codes (blocker 22). Set **[BILLING RECORDS RETENTION PERIOD]**.
47. Service credits (owner decision, 27 Nov 2026): forfeit if they leave. Earned, unapplied credits are paid out in the cases in Terms Schedule 4, 4.7(a), and forfeited when the Customer leaves by its own choice (blocker 40; counsel to confirm enforceability).
48. Microsoft publisher verification and Google OAuth app verification: finish both before businesses outside the test users connect work Microsoft accounts, Gmail or Google Calendar (blockers 41 and 42).
49. Google verification sequence (owner decision, 27 Nov 2026): publish first. The approved documents are published with the Gmail and Google Calendar wording, then Google verification is submitted; until Google approves, Connect Gmail and Connect Google Calendar stay hidden from customers, while Outlook and the business's own domain keep working (blocker 42, with the build item to hide the Google connect options). Blocker 41 (Microsoft) is unchanged.

## 6. Points for counsel

1. **AI voice calls and the TCPA.** Outbound AI calls and texts are off. Before they are switched on, confirm the consent evidence required per lead source (D 04) and the consent wording proposed in the architecture (section 34), which the Messaging Terms quote.
2. **Recording consent.** Whether calls are recorded today is unverified: until a call path change is approved, Vapi's own settings decide, and the owner has not yet confirmed that recording is off at Vapi. Separately, recording must stay off until legal review is complete. Confirm whether the notice ("This call is recorded.") is sufficient or whether an active consent question is needed in all party consent states (the architecture contemplates a consent question when recording is on).
3. **Section 230 and AI drafts.** The Terms do not rely on any platform liability shield for AI generated drafts that a Customer approves. Advise.
4. **Liability.** Cap at the greater of 12 months' Fees or a floor; exclusions of indirect damages; carve outs for indemnities, confidentiality (excluding Customer Data), Customer payment obligations and Customer breach of sections 5 and 7 or the AUP. Consider a separate cap for data protection claims.
5. **Indemnities.** Zella Voice indemnifies for third party IP claims with standard exclusions and modify, replace or refund remedies; Customer indemnifies for Customer Data, Customer Content (including defamation and privacy), communications and breach of law or the AUP. Confirm scope and procedure.
6. **Dispute terms.** The class action and jury waiver block is optional and must be checked against the chosen law and forum. Confirm the time limit for claims.
7. **Automatic renewal and trial conversion.** The Agreement is business to business only, but the renewal and trial conversion terms are conspicuous in case a state automatic renewal law applies.
8. **Data protection scope.** Zella Voice is offered only in the United States today. Decide whether to keep the EEA, UK, Swiss and India sections, and complete the SCC modules and UK IDTA or Addendum if kept.
9. **CCPA.** Confirm the notice at collection categories, whether a toll free request number is needed, and the service provider certification in the DPA.
10. **HIPAA.** The BAA template is optional and must not be offered until BAAs are in place with every vendor that would handle PHI.
11. **Messaging program.** Confirm the Messaging Terms meet current carrier and campaign registry expectations, including the STOP confirmation and HELP content.
12. **DMCA.** Register the designated agent with the US Copyright Office before relying on the safe harbor.
13. **Regulated Industries.** Childcare records hold children's details provided by parents; confirm no further children's privacy obligations attach to Zella Voice as processor.
14. **Retention periods.** All are pending legal review in the product (PRV 4), and some regulated industries may need longer periods. Includes the two conflicts in section 3: 30 or 90 days after cancellation, and 90 or 30 days for recordings.
15. **Limited warranty and ownership of AI Output** in the Terms are drafting choices; confirm.
16. **Vulnerability disclosure safe harbor** wording in the Trust and Security Overview.
17. **Team agreements:** state limits on invention assignment (California Labor Code section 2870 and similar statutes), worker classification for contractors, whistleblower and Defend Trade Secrets Act notices, and whether the founder assignment needs a contribution agreement under the operating agreement.
18. **State breach notification** deadlines and regulator thresholds for the incident response plan.
19. **Platform lead forms** (Google, Meta) as a source of TCPA consent for AI voice calls, and any one to one consent rule in force.
20. **Record of processing activities.** Assess whether the GDPR or UK GDPR applies to Zella Voice (as controller or processor) and, if so, whether Article 30 requires a record or one of its exceptions applies. Removing the EU and UK sections from the documents does not by itself remove any duty.
21. **Employee and applicant notice:** the California CPRA notice at collection for employees and applicants, and other state requirements.
22. **Reseller agreement:** resale structure, anti bribery and marketing compliance, commission tail and non solicitation.
23. **Trademark:** clearance search, filing basis and classes for ZELLA VOICE.
24. **Messaging hours.** The Messaging Terms (section 4.2) state the rulebook COM 3 contact hours (recipient's time zone when known) as an operating control; enforcing them is launch blocker 7. Confirm the hour ranges, whether marketing needs a narrower window, and whether reminders need quiet hours.
25. **Missed call text basis** for 10DLC registration (Consent Pack section 5.2).
26. **Spoken card numbers in transcripts.** Callers may speak card numbers, which may be stored in transcripts until redaction exists. Advise on PCI DSS scope and on the wording now used in the Privacy Policy, Terms 9.5 and DPA Annex 1.
27. **Retention after cancellation for businesses already canceled** (section 3.2.1), and the retention basis for consent and opt out history after cancellation (DPA 12.5).

## 7. Owner actions that are not documents

1. Sign or accept data processing agreements with every provider in DPA Annex 3, and confirm no training and retention settings.
2. Sign business associate agreements with every vendor that would handle PHI before offering the HIPAA option (D 49).
3. Register the DMCA designated agent with the US Copyright Office, and renew it every 3 years.
4. Buy insurance: cyber, technology errors and omissions, general liability and optionally media liability.
5. File the ZELLA VOICE trademark after counsel's clearance search.
6. Complete company basics: EIN, registered agent, operating agreement IP clause, bank account, founder IP assignments, and company ownership of domains and provider accounts.
7. Get tax advice on sales tax for software (D 50).
8. Engage counsel to review the set, starting with this memo.
9. Clear every launch blocker in section 4 before the public documents are published, and turn on the measures the documents describe only with the owner's explicit approval for each specific action (NN 3), and confirm point in time recovery, leaked password protection and encryption at rest.
10. Complete 10DLC registration for each Customer that will text. Publish security.txt and each public page, and make every later update to them, only with the owner's explicit approval for that specific publication or change (NN 3); no document in this set is published by drafting or merging it.

The details for each action are in the separate Owner Action Pack, in the second PDF, Zella_Voice_Owner_Actions_DRAFT_combined.pdf. Nothing in it has been filed, searched, bought or signed.

## 8. Judgment calls made in drafting

1. "Order Form" includes the plan summary the Owner accepts in onboarding, so that every Customer has one.
2. "Regulated Industry" lists the industries the product marks regulated: childcare, dental, healthcare, legal, financial services and insurance.
3. The AI Receptionist is described as using an Anthropic model, the default and the only provider checked against Vapi; the platform setting also accepts other providers.
4. Speech providers ElevenLabs, Cartesia and Deepgram are listed "where enabled"; Cartesia is built, not applied.
5. Stripe, Google Fonts and the identity provider appear in DPA Annex 3, Part A3.3 ("Other providers"), because they do not process Customer Personal Data. The email inbox provider is listed in Part A3.2 as a Subprocessor, because Zella Voice's support and data subject request inboxes can receive Customer Personal Data.
6. Google Fonts is listed although it is not in the architecture's subprocessor table, because the web application loads the Inter typeface from it.
7. Push notifications and WhatsApp and Messenger are omitted: push is only planned (D 40) and those Meta channels are undecided (D 39).
8. Encryption at rest is stated in the public documents as a control; the source documents do not state it, so it is launch blocker 16 until confirmed with the hosting provider.
9. The Messaging Terms state the rulebook COM 3 contact hours (recipient's time zone when known) in section 4.2 as an operating control; the sender today checks only marketing texts, 8 a.m. to 9 p.m., in the Business's time zone, so this is launch blocker 7.
10. START restores service texts only, as the code does; marketing consent must be given again.
11. Terms Schedule 3 (Content and Defamation Complaints Policy) says Zella Voice cannot remove content from third party sites such as Google, only stop further sending or publishing.
12. Terms Schedule 4 (Service Level and Support Policy) adds standard exclusions (Customer causes, suspension, Beta and switched off features, force majeure, announced maintenance) to the documented service credit.
13. The DPA adds standard terms not in the source documents: objection with refund, audits once a year, deletion certification, India transfer restriction.
14. The Terms give Zella Voice termination for convenience with a pro rata refund, and a 30 day cure period for material breach.
15. The Privacy Policy's California notice treats Owner identity documents and sign in credentials as sensitive personal information.
16. Backups with point in time recovery are stated as a control in the Privacy Policy, DPA Annex 2 and the Trust overview; the go live checklist still lists turning them on (launch blocker 17).
17. The Trust overview describes controls without status labels, as the owner instructed; every control there that is not yet in production is a launch blocker in section 4.
18. The Consent Pack quotes message templates exactly, including one British spelling that the product should fix.
19. The Messaging Terms keep the architecture's proposed consent wording; the Consent Pack's recommended wording adds message frequency and HELP, for counsel to choose.
20. Requirement and decision identifiers from the source documents are written with spaces (for example D 49, PRV 4) to keep the no dashes rule.
21. The Terms separate the Trial Period from the Subscription Term, which starts on the First Billing Date (the day the trial ends or, without a trial, the day the Owner completes checkout, which is what the checkout code stores; aligning the architecture's REQ BIL 17 is launch blocker 23). The Trial Period now starts when the Owner starts checkout during onboarding, after identity verification, matching the payment design (the Checkout Session sets the trial end 5 days after it is created). Nothing is charged during the trial: the setup fee goes on the first paid invoice, and packs, automatic reload and pay as you go are not available until the Subscription Term (a placeholder for the owner to confirm). Terms 9.2 and 9.7, the Order Form and the DPA duration ("any Trial Period") match. The Order Form records only the contractual trial terms: whether a trial is included (yes or no), the fixed 5 day length with 20 AI minutes, 5 texts and 5 emails, and that the trial starts when checkout starts.
22. Checkout support for trials (separate from the contract text): the checkout code (sql/zella_stripe_checkout.sql) sets the trial end from the platform's trial_days billing setting and takes no per business trial, so a different trial length cannot be offered without a product change (owner decision 30).
23. Order Form special terms prevail only where they expressly override a named provision (Terms section 26 and Order Form section 7 use the same rule).
24. Service credits for yearly Plans use the monthly equivalent: the yearly Fee divided by 12, then by 30, per affected day; the cap is the yearly Fee divided by 12.
25. No payment card details may be entered anywhere in the Services; payment details go only on Stripe's hosted page (Terms 5.10 and Schedule 1).
26. Consent evidence per source in the Consent Pack follows the architecture's proposed design; confirming the product stores it is launch blocker 26.

## 9. Consistency check

9.1 Checked across all ten files (nine documents and this memo) after the restructure:

- **Defined terms:** one definition list (Terms section 2), adopted by every document. "AUP" is now defined in Terms section 1.5 as Schedule 1, and "Policies" as Schedules 1 to 4 plus the Messaging Terms. The Messaging Terms Part A uses "Business" for recipients and defines it.
- **Document names and cross references:** no reference to a removed document remains. Every reference to a Schedule, Annex or section was checked against the headings: Terms sections 1.5, 2, 5.4, 5.5, 5.9, 7.4, 11, 16, 17, 20, 22, 22.3, 22.4, 26 and 28.3; Schedules 1 to 4; DPA sections 4, 8, 9.2, 11, 12 and 14, Annexes 1 to 3 and Schedule 1 (sections S1.1 to S1.8); Privacy Policy sections 10 and 15. One stale reference was fixed (the Privacy Policy pointed to a non existent "Annex A" of the DPA; it is Annex 2).
- **Retention:** 90 days (recordings and transcripts, subject to the decision in section 3.3; identity documents), 2 years (message contents), 7 years (audit logs), the cancellation period placeholder (after cancellation), 30 days (account deletion, number release, replaced identity copies) and 90 days (backups after cancellation) are identical in the Terms, Privacy Policy, DPA, Terms Schedule 2, the Trust overview and the Handbook.
- **Contacts:** one placeholder each for privacy, support, legal notices, content complaints, security, legal requests and the DMCA agent. The Subprocessor List location is one placeholder, used in the Privacy Policy, the DPA and the Trust overview.
- **Subprocessors:** the Privacy Policy summary table and DPA Annex 3 list the same providers.
- **Claims:** the public documents carry no build status wording or status placeholders; every promise the product does not yet keep is a launch blocker in section 4 (34 items).
- **Style:** no dashes or hyphens in text, except the security.txt field names "Preferred-Languages" and "/.well-known/", which are fixed technical identifiers. "Zella Voice" is always in full. American spelling, except one exact quotation of a product template, which is flagged. No model IDs.

## 10. Every placeholder, by document

<!-- ALL PLACEHOLDERS START -->

### This memo

- **[MEMO DATE]**
- **[CANCELLATION RETENTION PERIOD]**
- **[PUBLIC PRIVACY POLICY URL]**
- **[PUBLIC TERMS URL]**
- **[OWNER DECISION: HOW THE TRIAL TERMS AND THE BILLING SETTINGS ARE KEPT IN AGREEMENT]**
- **[BILLING RECORDS RETENTION PERIOD]**

### Zella Voice Terms of Service

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[LEGAL ENTITY NAME]**
- **[REGISTERED ADDRESS]**
- **[LEGAL DOCUMENTS LOCATION]**
- **[SUPPORT CONTACT EMAIL]**
- **[NOTE FOR COUNSEL: whether a platform liability shield, such as Section 230 of the Communications Decency Act in the United States, applies to AI generated drafts that a Customer approves is uncertain. This Agreement does not rely on it. Counsel to advise.]**
- **[CONFIRM ANY FOUNDING CUSTOMER PRICE TERMS]**
- **[CONFIRM TAX TREATMENT WITH AN ACCOUNTANT]**
- **[OWNER TO CONFIRM THE ONBOARDING MILESTONE THAT ENDS SETUP FEE REFUND ELIGIBILITY]**
- **[CANCELLATION RETENTION PERIOD]**
- **[NOTICE PERIOD FOR TERMINATION FOR CONVENIENCE]**
- **[COUNSEL TO CONFIRM THE LIMITED WARRANTY AND REMEDY]**
- **[FLOOR AMOUNT]**
- **[COUNSEL TO CONFIRM THE LIABILITY CAP, THE FLOOR AMOUNT, THE CARVE OUTS AND WHETHER A SEPARATE CAP FOR DATA PROTECTION CLAIMS IS NEEDED]**
- **[GOVERNING LAW AND COURTS]**
- **[DISPUTE RESOLUTION METHOD, FOR EXAMPLE THE COURTS OF A NAMED STATE OR ARBITRATION]**
- **[INFORMAL RESOLUTION PERIOD]**
- **[TIME LIMIT FOR CLAIMS]**
- **[OPTIONAL CLAUSE: USE ONLY IF COUNSEL APPROVES FOR THE CHOSEN LAW]**
- **[END OF OPTIONAL CLAUSE]**
- **[NOTICE PERIOD FOR CHANGES]**
- **[REFUND PERIOD]**
- **[ADVERSE CHANGE CANCELLATION WINDOW]**
- **[COUNSEL TO CONFIRM THE CANCELLATION WINDOW AND REFUND MECHANISM FOR ADVERSE CHANGES THAT TAKE EFFECT SOONER]**
- **[LEGAL NOTICES EMAIL OR ADDRESS]**
- **[ORDER OF PRECEDENCE: AS COUNSEL PREFERS]**
- **[CONTENT COMPLAINTS CONTACT]**
- **[MAXIMUM CALL LENGTH]**
- **[COMPLAINT ACKNOWLEDGMENT PERIOD]**
- **[DMCA DESIGNATED AGENT NAME, ADDRESS, PHONE AND EMAIL]**
- **[REGISTER THE DESIGNATED AGENT WITH THE US COPYRIGHT OFFICE]**
- **[SUPPORT HOURS AND TIME ZONE]**
- **[SUPPORT HOLIDAYS]**
- **[PLACEHOLDER FOR OWNER DECISION: WHETHER TO PUBLISH AN UPTIME TARGET, AND IF SO WHICH]**
- **[CONFIRM THE CALENDAR DAY TIME ZONE AND HOW UNAVAILABILITY IS MEASURED]**
- **[CONFIRM WHETHER THE CAP APPLIES PER BILLING PERIOD]**
- **[CHRONIC UNAVAILABILITY THRESHOLD: NUMBER OF AFFECTED DAYS IN A MONTH]**
- **[COUNSEL TO CONFIRM THE CHRONIC UNAVAILABILITY THRESHOLD]**
- **[CREDIT PAYOUT PERIOD]**
- **[COUNSEL TO CONFIRM WHETHER FORFEITURE OF EARNED CREDITS IS ENFORCEABLE IN EACH LAUNCH JURISDICTION]**

### Zella Voice Privacy Policy

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[LEGAL ENTITY NAME]**
- **[REGISTERED ADDRESS]**
- **[SUBPROCESSOR LIST LOCATION]**
- **[MONITORING PROVIDER NAME]**
- **[IDENTITY PROVIDER NAME, IF ONE IS CONNECTED]**
- **[EMAIL INBOX PROVIDER]**
- **[DATA HOSTING REGION]**
- **[TRANSFER MECHANISM, FOR EXAMPLE THE EU STANDARD CONTRACTUAL CLAUSES AND THE UK INTERNATIONAL DATA TRANSFER AGREEMENT OR ADDENDUM]**
- **[COUNSEL TO CONFIRM THE PRECEDENCE WHERE A CALL IS UNDER BOTH A LEGAL HOLD AND A RETURN REQUEST]**
- **[CONFIRM THE RATE LIMIT RECORD RETENTION]**
- **[BILLING RECORDS RETENTION PERIOD]**
- **[CANCELLATION RETENTION PERIOD]**
- **[COUNSEL CHOICE: (A) EXCLUDE TRANSCRIPTS OF CUSTOMERS IN REGULATED INDUSTRIES FROM EVERY EXPORT, INCLUDING AFTER CANCELLATION (CURRENT TEXT); OR (B) LET THE OWNER EXPORT THEM WITH SAFEGUARDS, AND UPDATE SECTIONS 10 AND 11.1, DPA 9.1 AND 12.2 AND TERMS 12.6 TO MATCH]**
- **[PRIVACY CONTACT EMAIL]**
- **[COUNSEL TO CONFIRM THE MATCHING STANDARD AND THE METHOD FOR REQUESTERS WITH NO EMAIL ON RECORD]**
- **[EU REPRESENTATIVE, IF REQUIRED]**
- **[UK REPRESENTATIVE, IF REQUIRED]**
- **[GRIEVANCE OFFICER NAME AND CONTACT]**
- **[CONFIRM WHETHER THE HOSTING PROVIDER SETS ANY COOKIES]**
- **[CONFIRM WHETHER A COOKIE BANNER OR CONSENT MECHANISM IS REQUIRED]**
- **[DPO OR PRIVACY CONTACT]**
- **[PRIVACY REQUEST PHONE NUMBER, IF REQUIRED]**

### Zella Voice Data Processing Addendum

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[LEGAL ENTITY NAME]**
- **[REGISTERED ADDRESS]**
- **[SUBPROCESSOR LIST LOCATION]**
- **[SUBPROCESSOR CHANGE NOTICE PERIOD]**
- **[URGENT REPLACEMENT OBJECTION PERIOD]**
- **[BAA RETURN PERIOD]**
- **[BREACH NOTIFICATION HOURS]**
- **[CANCELLATION RETENTION PERIOD]**
- **[COUNSEL TO CONFIRM THE RETENTION BASIS FOR CONSENT AND OPT OUT HISTORY AFTER CANCELLATION]**
- **[AUDIT NOTICE PERIOD]**
- **[DATA HOSTING REGION]**
- **[SCC MODULE TWO (CONTROLLER TO PROCESSOR) AND, WHERE APPLICABLE, MODULE THREE; OPTIONAL CLAUSES; GOVERNING LAW; COMPETENT SUPERVISORY AUTHORITY; SWISS ADJUSTMENTS]**
- **[UK INTERNATIONAL DATA TRANSFER AGREEMENT OR UK ADDENDUM TO THE EU STANDARD CONTRACTUAL CLAUSES, WITH TABLES COMPLETED]**
- **[COUNSEL TO CONFIRM THE LEGAL BASIS UNDER THE DPDP ACT FOR KEEPING CONSENT AND OPT OUT HISTORY AFTER ERASURE]**
- **[PRIVACY CONTACT EMAIL]**
- **[DPO OR PRIVACY CONTACT]**
- **[MONITORING PROVIDER NAME]**
- **[EMAIL INBOX PROVIDER]**
- **[IDENTITY PROVIDER NAME, IF ONE IS CONNECTED]**
- **[OPTIONAL SCHEDULE: USE ONLY FOR APPROVED HEALTHCARE CUSTOMERS AND ONLY IF COUNSEL APPROVES]**
- **[BAA EFFECTIVE DATE]**
- **[CUSTOMER LEGAL NAME]**
- **[BAA BREACH NOTICE DAYS]**
- **[BAA RESPONSE DAYS]**
- **[OPTIONAL: DATA AGGREGATION SERVICES RELATING TO THE HEALTH CARE OPERATIONS OF COVERED ENTITY, IF COUNSEL APPROVES]**
- **[BAA RETURN DELIVERY PERIOD]**
- **[BAA RETURN REMINDER PERIOD]**
- **[COUNSEL TO CONFIRM THE RETURN PROCESS AND WHETHER AN EXCEPTION IS NEEDED WHERE RETURN IS DELAYED FOR REASONS OUTSIDE COVERED ENTITY'S CONTROL]**
- **[COUNSEL TO CONFIRM THE HIPAA RETENTION BASIS FOR CONSENT AND OPT OUT RECORDS CONTAINING PHI]**
- **[COUNSEL CHOICE: CONFIRM THAT THE LEGAL HOLD PREVAILS FOR THE HELD ITEMS ONLY, OR SET ANOTHER PRECEDENCE]**
- **[COUNSEL TO DECIDE WHETHER THE LIMITATION OF LIABILITY IN SECTION 20 OF THE ZELLA VOICE TERMS OF SERVICE APPLIES TO THIS BAA, OR A SEPARATE CAP]**
- **[SIGNATORY NAME]**
- **[SIGNATORY TITLE]**
- **[SIGNATURE DATE]**

### Zella Voice Messaging Terms

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[COUNSEL DECISION ON THE MISSED CALL BASIS: APPROVED OR REJECTED; IF REJECTED, DELETE THIS ITEM AND THE MISSED CALL TEXT IN SECTION 4.2]**
- **[PROGRAM NAME, PER BUSINESS CAMPAIGN]**
- **[COUNSEL TO APPROVE THE CONSENT WORDING]**
- **[OWNER AND COUNSEL: CONFIRM THE HOUR RANGES, INCLUDING WHETHER MARKETING NEEDS A NARROWER WINDOW AND WHETHER REMINDERS NEED QUIET HOURS]**
- **[SUPPORT CONTACT EMAIL]**
- **[LEGAL DOCUMENTS LOCATION]**
- **[COUNSEL TO CONFIRM THIS DISCLOSURE AGAINST THE GOOGLE AND META LEAD FORM FLOWS AND CARRIER REQUIREMENTS]**

### Zella Voice Order Form (Template)

- **[ORDER FORM NUMBER]**
- **[ORDER DATE]**
- **[LEGAL ENTITY NAME]**
- **[LEGAL DOCUMENTS LOCATION]**
- **[CUSTOMER LEGAL NAME]**
- **[CUSTOMER ADDRESS]**
- **[CUSTOMER INDUSTRY]**
- **[OWNER NAME AND EMAIL]**
- **[BILLING CONTACT]**
- **[FALLBACK NUMBER]**
- **[BASE OR PRO]**
- **[MONTHLY OR YEARLY]**
- **[PLAN FEE]**
- **[SETUP FEE OR NONE]**
- **[MINUTES]**
- **[TEXTS]**
- **[EMAILS]**
- **[SEATS]**
- **[NUMBERS]**
- **[LOCATIONS]**
- **[ENGLISH, SPANISH OR BOTH]**
- **[PER MINUTE RATE OR NOT OFFERED]**
- **[MONTHLY SPENDING LIMIT]**
- **[YES OR NO]**
- **[SPECIAL TERMS OR NONE]**
- **[ORDER OF PRECEDENCE: AS COUNSEL PREFERS]**
- **[SIGNATORY NAME]**
- **[SIGNATORY TITLE]**
- **[SIGNATURE DATE]**

### Zella Voice Trust and Security Overview

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[CANCELLATION RETENTION PERIOD]**
- **[SUBPROCESSOR LIST LOCATION]**
- **[SECURITY CONTACT]**
- **[SECURITY KEY LOCATION, IF ANY]**
- **[IN SCOPE DOMAINS AND APPLICATIONS]**
- **[ACKNOWLEDGMENT PERIOD]**
- **[COUNSEL TO CONFIRM THE SAFE HARBOR WORDING]**
- **[OWNER DECISION: WHETHER TO OFFER REWARDS]**
- **[SECURITY.TXT EXPIRY DATE]**
- **[ADDRESS OF THIS PAGE]**
- **[ADDRESS OF THE SECURITY.TXT FILE]**
- **[KNOWN ACCESSIBILITY LIMITATIONS, AFTER AN AUDIT]**
- **[ACCESSIBILITY CONTACT]**
- **[ACCESSIBILITY RESPONSE TIME]**
- **[ACCESSIBILITY STATEMENT REVIEW FREQUENCY]**
- **[LAST REVIEWED DATE]**

### Zella Voice Team and Partner Agreements (Templates)

- **[TEMPLATE DATE]**
- **[LEGAL ENTITY NAME]**
- **[REGISTERED ADDRESS]**
- **[COUNTERPARTY LEGAL NAME]**
- **[COUNTERPARTY ADDRESS]**
- **[PURPOSE OF DISCLOSURE]**
- **[NDA EFFECTIVE DATE, OR IF LEFT BLANK, THE DATE OF THE LAST SIGNATURE BELOW]**
- **[NDA TERM]**
- **[CONFIDENTIALITY PERIOD]**
- **[GOVERNING LAW AND COURTS]**
- **[SIGNATORY NAME]**
- **[SIGNATORY TITLE]**
- **[SIGNATURE DATE]**
- **[CONTRACTOR LEGAL NAME]**
- **[CONTRACTOR ADDRESS]**
- **[FIRST STATEMENT OF WORK REFERENCE]**
- **[COUNSEL TO CONFIRM CLASSIFICATION FOR THE CONTRACTOR'S LOCATION]**
- **[PAYMENT TERMS]**
- **[CONTRACTOR CONFIDENTIALITY PERIOD]**
- **[ATTACH DATA PROCESSING TERMS IF CONTRACTOR WILL ACCESS PERSONAL DATA]**
- **[TERMINATION NOTICE PERIOD]**
- **[LIST OF PRIOR INVENTIONS OR "NONE"]**
- **[COUNSEL NOTE: several states limit invention assignment for employees, for example California Labor Code section 2870, and similar statutes in other states such as Delaware, Illinois, Minnesota, North Carolina and Washington. Some states also limit non competition and non solicitation covenants. This template contains no non compete. Counsel must adapt it to the employee's state before use.]**
- **[EMPLOYEE NAME]**
- **[COUNSEL TO ATTACH THE APPLICABLE STATUTORY TEXT AS EXHIBIT C2]**
- **[COUNSEL TO CONFIRM FOR THE EMPLOYEE'S STATE]**
- **[EMPLOYEE GOVERNING LAW]**
- **[STATE STATUTORY NOTICE TEXT]**
- **[SIGNATURE]**
- **[FOUNDER NAME]**
- **[FOUNDER NAMES]**
- **[CONSIDERATION, FOR EXAMPLE MEMBERSHIP INTERESTS ISSUED OR ONE DOLLAR AND OTHER GOOD AND VALUABLE CONSIDERATION]**
- **[FOUNDER CONFIDENTIALITY PERIOD]**
- **[COUNSEL TO CONFIRM WHETHER A CONTRIBUTION AGREEMENT UNDER THE OPERATING AGREEMENT IS ALSO NEEDED]**
- **[LIST OF ASSETS, FOR EXAMPLE CODE REPOSITORIES, DOMAINS AND ACCOUNTS]**
- **[EXCEPTIONS OR "NONE"]**
- **[PARTNER LEGAL NAME]**
- **[PARTNER ADDRESS]**
- **[REFERRAL OR RESALE]**
- **[COUNSEL TO CONFIRM THE RESALE STRUCTURE, INCLUDING WHO BILLS AND WHO SUPPORTS THE END CUSTOMER]**
- **[REFERRAL WINDOW]**
- **[COMMISSION RATE OR AMOUNT]**
- **[COMMISSION PERIOD]**
- **[COMMISSION PAYMENT TIMING]**
- **[RESALE PRICE OR DISCOUNT]**
- **[PARTNER AGREEMENT TERM]**
- **[NON RENEWAL NOTICE PERIOD]**
- **[UNLESS COUNSEL AGREES A TAIL PERIOD]**
- **[COUNSEL TO CONFIRM TRANSITION OF RESALE CUSTOMERS]**
- **[PARTNER CONFIDENTIALITY PERIOD]**
- **[COUNSEL TO CONFIRM LIABILITY TERMS]**
- **[OPTIONAL CLAUSE: USE ONLY IF COUNSEL APPROVES]**
- **[NON SOLICITATION PERIOD]**
- **[END OF OPTIONAL CLAUSE]**

### Zella Voice Privacy and Security Operations Handbook

- **[HANDBOOK OWNER ROLE]**
- **[LAST REVIEWED DATE]**
- **[CONFIRM WHICH INCIDENT CONTROLS ARE AVAILABLE TODAY]**
- **[INCIDENT LEAD ROLE]**
- **[TECHNICAL LEAD ROLE]**
- **[COMMUNICATIONS LEAD ROLE]**
- **[LEGAL COUNSEL CONTACT]**
- **[POST INCIDENT REVIEW PERIOD]**
- **[BREACH NOTIFICATION HOURS]**
- **[BAA BREACH NOTICE DAYS]**
- **[COUNSEL TO MAP STATE BREACH NOTIFICATION DEADLINES AND REGULATOR THRESHOLDS]**
- **[COUNSEL TO CONFIRM]**
- **[VENDOR CONTRACT NOTICE TERMS]**
- **[INCIDENT LOG RETENTION PERIOD]**
- **[INCIDENT LOG LOCATION]**
- **[CONFIRM THE DAILY REMINDER JOB IS SWITCHED ON]**
- **[SECURE DELIVERY CHANNEL FOR DATA SUBJECT REQUESTS]**
- **[COUNSEL TO CONFIRM THE RESPONSE OWED FOR ITEMS THAT CANNOT BE PROVIDED]**
- **[NOT YET ENFORCED BY THE PRODUCT: ERASURE DOES NOT CHECK LEGAL HOLDS TODAY; STAFF MUST CHECK MANUALLY BEFORE ERASING]**
- **[LEGAL HOLD CONTROL OWNER]**
- **[CONFIRM HOW A HOLD IS RECORDED AGAINST AN OPEN REQUEST: THE REQUEST NOTE CAN ONLY BE SET WHEN THE REQUEST IS LOGGED OR CLOSED]**
- **[BAA RETURN PERIOD]**
- **[COUNSEL TO CONFIRM THAT ONLY THE NAMED ITEM IS KEPT AND THE REST OF THE ERASURE PROCEEDS ON TIME]**
- **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]**
- **[ACCOUNT DATA REQUEST LOG LOCATION]**
- **[COUNSEL TO CONFIRM THE MATCHING STANDARD]**
- **[COUNSEL TO SET THE VERIFICATION METHOD FOR REQUESTERS WITH NO EMAIL ADDRESS ON RECORD]**
- **[COUNSEL TO CONFIRM THE AGENT VERIFICATION STANDARD]**
- **[LEGAL REQUESTS CONTACT]**
- **[EMERGENCY DECISION OWNER]**
- **[COUNSEL TO CONFIRM THE LEGAL BASIS FOR EMERGENCY DISCLOSURE, INCLUDING 18 U.S.C. 2702 AND ANY STATE LAW]**
- **[OWNER DECISION: WHETHER TO PUBLISH A TRANSPARENCY REPORT]**
- **[COUNSEL TO ASSESS WHETHER THE GDPR OR UK GDPR APPLIES TO ZELLA VOICE, AND IF SO WHETHER ARTICLE 30 REQUIRES THIS RECORD OR ONE OF ITS EXCEPTIONS APPLIES; KEEPING OR REMOVING THE EU AND UK SECTIONS DOES NOT DECIDE THIS]**
- **[LEGAL ENTITY NAME]**
- **[REGISTERED ADDRESS]**
- **[PRIVACY CONTACT EMAIL]**
- **[EU REPRESENTATIVE, IF REQUIRED]**
- **[TRANSFER MECHANISM, FOR EXAMPLE THE EU STANDARD CONTRACTUAL CLAUSES AND THE UK INTERNATIONAL DATA TRANSFER AGREEMENT OR ADDENDUM]**
- **[COUNSEL ITEM: confirm the California CPRA notice at collection for employees and applicants (categories, purposes, whether information is sold or shared, retention for each category, and sensitive personal information), and any other state or country requirements, before use.]**
- **[HR PROVIDERS]**
- **[APPLICANT RECORD RETENTION PERIOD]**
- **[EMPLOYEE RECORD RETENTION PERIOD]**
- **[PAYROLL RECORD RETENTION PERIOD]**
- **[HR PRIVACY CONTACT]**

### Zella Voice Consent and Carrier Registration Pack

- **[LAST UPDATED DATE]**
- **[LINKS TO THE CUSTOMER'S PRIVACY POLICY AND THE MESSAGING TERMS]**
- **[COUNSEL TO CONFIRM EACH CHECKBOX MEETS PRIOR EXPRESS WRITTEN CONSENT UNDER THE TCPA, INCLUDING ANY ONE TO ONE CONSENT REQUIREMENT IN FORCE, AND WHETHER MARKETING EMAILS NEED THEIR OWN CHECKBOX]**
- **[COUNSEL TO CONFIRM WHETHER PLATFORM LEAD FORMS CAN CARRY TCPA CONSENT FOR AI VOICE CALLS]**
- **[COUNSEL TO CONFIRM WHETHER EACH PLATFORM'S LEAD FORM MUST SHOW AN UNTICKED CONSENT CHECKBOX]**
- **[COUNSEL DECISION ON THE MISSED CALL BASIS: APPROVED OR REJECTED]**
- **[COUNSEL TO SELECT THE RECORDING DISCLOSURE OPTION]**
- **[CUSTOMER LEGAL NAME]**
- **[CUSTOMER EIN]**
- **[CUSTOMER WEBSITE]**
- **[CUSTOMER INDUSTRY VERTICAL]**
- **[ADD A SCREENSHOT OR PUBLIC URL OF THE OPT IN FORM]**
- **[CONFIRM LINK DOMAIN]**
- **[YES OR NO]**
- **[ADD A SCREENSHOT OR PUBLIC URL OF THE MARKETING OPT IN]**
- **[SAMPLE TEXT FOR THE RELATED SERVICE SUGGESTION]**
- **[SAMPLE OFFER TEXT FROM THE CUSTOMER, IF OFFERS ARE SENT BY TEXT]**

<!-- ALL PLACEHOLDERS END -->
