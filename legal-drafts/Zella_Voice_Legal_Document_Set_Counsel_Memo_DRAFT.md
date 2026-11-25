# Zella Voice legal document set: drafting notes for counsel

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Internal memo for the owner and counsel. Not for publication.

Date: **[MEMO DATE]**

## 1. Purpose

1.1 This memo accompanies version 0.2 drafts of the Zella Voice legal document set: nine documents plus this memo. Each document was drafted from the project's own source documents (the architecture, product, rulebook, project memory and database schema documents, and the version 0.1 privacy policy and terms held in the database migration for legal documents). Nothing in the set describes a feature, certification or guarantee that those sources do not support. Unknown company facts are bold bracketed placeholders.

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
| 6 | Zella Voice Trust and Security Overview | Public | Security measures marked Live or Built, going live; vulnerability disclosure policy; security.txt; accessibility statement (section 10) |
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

2.3.3 **Order of precedence** (Terms section 26, repeated in the Order Form and the DPA): a BAA for PHI only; then Order Form special terms; then the DPA for Customer Personal Data; then the Terms; then the Policies (Schedules 1 to 4 and the Messaging Terms). Transfer clauses prevail over the DPA. Marked "as counsel prefers".

2.3.4 **Changes.** Zella Voice may update the Terms and the Policies on notice under Terms section 22; section 22.3 confirms this for Schedules 1 and 4.

2.3.5 **Acceptance.** The owner onboarding journey records acceptance on the server; the Terms' clickwrap clause relies on it. That step is built but not applied (section 4).

## 3. Retention: one conflict to resolve

3.1 The architecture (section 20, REQ BIL 49) and the rulebook (PRV 4) say a canceled Customer's data is deleted 30 days after cancellation, after a final export offer. The version 0.1 privacy policy said 90 days. The product document notes that the database falls back to 90 days when no value is set, and the admin page labels it "Pending legal review".

3.2 **Every document in this set uses 30 days**, because the rulebook prevails. Decide, and set the database value to match before publishing.

3.3 Other periods used consistently across the set: recordings and transcripts 90 days; message contents 2 years; audit and security logs 7 years; Owner identity documents 90 days after the check (replaced copies 30 days); backups cleared within 90 days after cancellation; account deletion 30 days after confirmation; numbers released 30 days after cancellation; legal holds override. All periods are marked pending legal review in the product (PRV 4).

## 4. Claims that must not be published until the feature is on

| Claim in the documents | Status in the source documents |
|---|---|
| Recordings and transcripts deleted automatically after 90 days | Built, not applied; purge switch off; periods pending legal review |
| Copies at Vapi deleted | Built, not applied; Vapi deletion switch off |
| Deletion 30 days after cancellation; account deletion after 30 days | Built, not deployed; purge runs need two approvals; account deletion migration not applied |
| AI disclosure cannot be removed and is added in the caller's language | Built, not applied (call disclosure migration) |
| Recording off by default | Policy built, not deployed; until a call path change is approved, the voice provider's own settings decide whether a call is recorded. Confirm recording is off at Vapi |
| Caller verification with confirmation codes | Built, not applied |
| Silence timeout and the limit of 10 concurrent calls | Built, not applied |
| Maximum call length | Policy 20 minutes; the live setting is 10 minutes today; left as a placeholder |
| Usage alerts at 80% and 100%, and actions at 100% | Built; enforcement switches off |
| Trial charge, renewals, renewal notices, refunds, packs, automatic reload, failed payment handling | Payments off; pay as you go charging not built |
| Texts, emails, outbound AI calls, callbacks, calendar sync, review replies, Meta, AI drafting, call classification | Each built and off behind its live switch |
| Two step sign in for administrators and Owners; identity verification; plan and legal acceptance in onboarding | Built, not applied or deployed |
| Masked contact details in admin tools; whole business export | Built, need deploy approval |
| Status page wording ("everything is working" only when checked) | Built, not applied |
| Support replies in the app | Built, not applied |
| Trust overview "Built, going live" items | Must be relabelled Live only once in production |
| HIPAA BAA available | Offered only after BAAs with every vendor (D 49); not in place |

## 5. Open decisions for the owner

1. Retention after cancellation: 30 days (used) or 90 days (section 3).
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

## 6. Points for counsel

1. **AI voice calls and the TCPA.** Outbound AI calls and texts are off. Before they are switched on, confirm the consent evidence required per lead source (D 04) and the consent wording proposed in the architecture (section 34), which the Messaging Terms quote.
2. **Recording consent.** Recording is off until review. Confirm the notice ("This call is recorded.") is sufficient or whether an active consent question is needed in all party consent states (the architecture contemplates a consent question when recording is on).
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
14. **Retention periods.** All are pending legal review in the product (PRV 4), and some regulated industries may need longer periods.
15. **Limited warranty and ownership of AI Output** in the Terms are drafting choices; confirm.
16. **Vulnerability disclosure safe harbor** wording in the Trust and Security Overview.
17. **Team agreements:** state limits on invention assignment (California Labor Code section 2870 and similar statutes), worker classification for contractors, whistleblower and Defend Trade Secrets Act notices, and whether the founder assignment needs a contribution agreement under the operating agreement.
18. **State breach notification** deadlines and regulator thresholds for the incident response plan.
19. **Platform lead forms** (Google, Meta) as a source of TCPA consent for AI voice calls, and any one to one consent rule in force.
20. **Record of processing activities** is needed only if the EU and UK sections are kept.
21. **Employee and applicant notice:** the California CPRA notice at collection for employees and applicants, and other state requirements.
22. **Reseller agreement:** resale structure, anti bribery and marketing compliance, commission tail and non solicitation.
23. **Trademark:** clearance search, filing basis and classes for ZELLA VOICE.

## 7. Owner actions that are not documents

1. Sign or accept data processing agreements with every provider in DPA Annex 3, and confirm no training and retention settings.
2. Sign business associate agreements with every vendor that would handle PHI before offering the HIPAA option (D 49).
3. Register the DMCA designated agent with the US Copyright Office, and renew it every 3 years.
4. Buy insurance: cyber, technology errors and omissions, general liability and optionally media liability.
5. File the ZELLA VOICE trademark after counsel's clearance search.
6. Complete company basics: EIN, registered agent, operating agreement IP clause, bank account, founder IP assignments, and company ownership of domains and provider accounts.
7. Get tax advice on sales tax for software (D 50).
8. Engage counsel to review the set, starting with this memo.
9. Turn on the measures the documents describe only after approval, and confirm point in time recovery, leaked password protection and encryption at rest.
10. Complete 10DLC registration for each Customer that will text, and publish security.txt and the public pages.

The details for each action are in the separate Owner Action Pack, in the second PDF, Zella_Voice_Owner_Actions_DRAFT_combined.pdf. Nothing in it has been filed, searched, bought or signed.

## 8. Judgment calls made in drafting

1. "Order Form" includes the plan summary the Owner accepts in onboarding, so that every Customer has one.
2. "Regulated Industry" lists the industries the product marks regulated: childcare, dental, healthcare, legal, financial services and insurance.
3. The AI Receptionist is described as using an Anthropic model, the default and the only provider checked against Vapi; the platform setting also accepts other providers.
4. Speech providers ElevenLabs, Cartesia and Deepgram are listed "where enabled"; Cartesia is built, not applied.
5. Stripe, Google Fonts, the identity provider and the email inbox provider appear in DPA Annex 3, Part A3.3 ("Other providers"), because they do not process Customer Personal Data.
6. Google Fonts is listed although it is not in the architecture's subprocessor table, because the web application loads the Inter typeface from it.
7. Push notifications and WhatsApp and Messenger are omitted: push is only planned (D 40) and those Meta channels are undecided (D 39).
8. Encryption at rest is a placeholder; the source documents do not state it.
9. The messaging contact hours follow the product document (reminders 7 a.m. to 9 p.m.; other messages 9 a.m. to 7 p.m.). An older messaging policy document says reminders have no quiet window (its decision D3); the product document is more recent.
10. START restores service texts only, as the code does; marketing consent must be given again.
11. Terms Schedule 3 (Content and Defamation Complaints Policy) says Zella Voice cannot remove content from third party sites such as Google, only stop further sending or publishing.
12. Terms Schedule 4 (Service Level and Support Policy) adds standard exclusions (Customer causes, suspension, Beta and switched off features, force majeure, announced maintenance) to the documented service credit.
13. The DPA adds standard terms not in the source documents: objection with refund, audits once a year, deletion certification, India transfer restriction.
14. The Terms give Zella Voice termination for convenience with a pro rata refund, and a 30 day cure period for material breach.
15. The Privacy Policy's California notice treats Owner identity documents and sign in credentials as sensitive personal information.
16. Backups with point in time recovery are behind a placeholder in the Privacy Policy, DPA Annex 2 and the Trust overview, because the go live checklist still lists turning them on.
17. The Trust overview labels each measure Live or Built, going live from the product status table; nothing is claimed as live that the product document marks as not applied or not deployed.
18. The Consent Pack quotes message templates exactly, including one British spelling that the product should fix.
19. The Messaging Terms keep the architecture's proposed consent wording; the Consent Pack's recommended wording adds message frequency and HELP, for counsel to choose.
20. Requirement and decision identifiers from the source documents are written with spaces (for example D 49, PRV 4) to keep the no dashes rule.

## 9. Consistency check

9.1 Checked across all ten files (nine documents and this memo) after the restructure:

- **Defined terms:** one definition list (Terms section 2), adopted by every document. "AUP" is now defined in Terms section 1.5 as Schedule 1, and "Policies" as Schedules 1 to 4 plus the Messaging Terms. The Messaging Terms Part A uses "Business" for recipients and defines it.
- **Document names and cross references:** no reference to a removed document remains. Every reference to a Schedule, Annex or section was checked against the headings: Terms sections 1.5, 2, 5.4, 5.5, 5.9, 7.4, 11, 16, 17, 20, 22, 22.3, 26 and 28.3; Schedules 1 to 4; DPA sections 4, 8, 9.2, 11, 12 and 14, Annexes 1 to 3 and Schedule 1 (sections S1.1 to S1.8); Privacy Policy sections 10 and 15. One stale reference was fixed (the Privacy Policy pointed to a non existent "Annex A" of the DPA; it is Annex 2).
- **Retention:** 90 days (recordings, transcripts, identity documents), 2 years (message contents), 7 years (audit logs), 30 days (after cancellation, account deletion, number release, replaced identity copies) and 90 days (backups after cancellation) are identical in the Terms, Privacy Policy, DPA, Terms Schedule 2, the Trust overview and the Handbook.
- **Contacts:** one placeholder each for privacy, support, legal notices, content complaints, security, legal requests and the DMCA agent. The Subprocessor List location is one placeholder, used in the Privacy Policy, the DPA and the Trust overview.
- **Subprocessors:** the Privacy Policy summary table and DPA Annex 3 list the same providers.
- **Claims:** backups with point in time recovery were stated as fact in the Privacy Policy and DPA; they are now behind a placeholder, because the go live checklist still lists turning them on.
- **Style:** no dashes or hyphens in text, except the security.txt field names "Preferred-Languages" and "/.well-known/", which are fixed technical identifiers. "Zella Voice" is always in full. American spelling, except one exact quotation of a product template, which is flagged. No model IDs.

## 10. Every placeholder, by document

<!-- ALL PLACEHOLDERS START -->

### This memo

- **[MEMO DATE]**

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
- **[PRIVACY CONTACT EMAIL]**
- **[EU REPRESENTATIVE, IF REQUIRED]**
- **[UK REPRESENTATIVE, IF REQUIRED]**
- **[GRIEVANCE OFFICER NAME AND CONTACT]**
- **[CONFIRM ENCRYPTION AT REST WITH THE HOSTING PROVIDER]**
- **[CONFIRM POINT IN TIME RECOVERY IS ENABLED]**
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
- **[BREACH NOTIFICATION HOURS]**
- **[AUDIT NOTICE PERIOD]**
- **[DATA HOSTING REGION]**
- **[SCC MODULE TWO (CONTROLLER TO PROCESSOR) AND, WHERE APPLICABLE, MODULE THREE; OPTIONAL CLAUSES; GOVERNING LAW; COMPETENT SUPERVISORY AUTHORITY; SWISS ADJUSTMENTS]**
- **[UK INTERNATIONAL DATA TRANSFER AGREEMENT OR UK ADDENDUM TO THE EU STANDARD CONTRACTUAL CLAUSES, WITH TABLES COMPLETED]**
- **[PRIVACY CONTACT EMAIL]**
- **[DPO OR PRIVACY CONTACT]**
- **[CONFIRM ENCRYPTION AT REST WITH THE HOSTING PROVIDER]**
- **[CONFIRM POINT IN TIME RECOVERY IS ENABLED]**
- **[MONITORING PROVIDER NAME]**
- **[IDENTITY PROVIDER NAME, IF ONE IS CONNECTED]**
- **[EMAIL INBOX PROVIDER]**
- **[OPTIONAL SCHEDULE: USE ONLY FOR APPROVED HEALTHCARE CUSTOMERS AND ONLY IF COUNSEL APPROVES]**
- **[BAA EFFECTIVE DATE]**
- **[CUSTOMER LEGAL NAME]**
- **[BAA BREACH NOTICE DAYS]**
- **[BAA RESPONSE DAYS]**
- **[OPTIONAL: DATA AGGREGATION SERVICES RELATING TO THE HEALTH CARE OPERATIONS OF COVERED ENTITY, IF COUNSEL APPROVES]**
- **[COUNSEL TO DECIDE WHETHER THE LIMITATION OF LIABILITY IN SECTION 20 OF THE ZELLA VOICE TERMS OF SERVICE APPLIES TO THIS BAA, OR A SEPARATE CAP]**
- **[SIGNATORY NAME]**
- **[SIGNATORY TITLE]**
- **[SIGNATURE DATE]**

### Zella Voice Messaging Terms

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[PROGRAM NAME, PER BUSINESS CAMPAIGN]**
- **[COUNSEL TO APPROVE THE CONSENT WORDING]**
- **[CONFIRM WHETHER A ONE TIME STOP CONFIRMATION TEXT IS SENT]**
- **[SUPPORT CONTACT EMAIL]**
- **[CONFIRM THE HELP REPLY INCLUDES THE BUSINESS NAME AND A CONTACT METHOD]**
- **[LEGAL DOCUMENTS LOCATION]**

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
- **[TRIAL VARIATION OR NONE]**
- **[START DATE OR "THE FIRST BILLING DATE UNDER SECTION 9.3 OF THE TERMS"]**
- **[CONFIRM PACK PRICES BEFORE USE; THEY ARE IN THE DATABASE DESIGN BUT NOT YET APPLIED]**
- **[SPECIAL TERMS OR NONE]**
- **[ORDER OF PRECEDENCE: AS COUNSEL PREFERS]**
- **[SIGNATORY NAME]**
- **[SIGNATORY TITLE]**
- **[SIGNATURE DATE]**

### Zella Voice Trust and Security Overview

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[CONFIRM WHETHER LEAKED PASSWORD PROTECTION IS ON]**
- **[CONFIRM ENCRYPTION AT REST WITH THE HOSTING PROVIDER]**
- **[CONFIRM POINT IN TIME RECOVERY IS ENABLED]**
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
- **[COUNSEL TO CONFIRM LIABILITY TERMS]**
- **[OPTIONAL CLAUSE: USE ONLY IF COUNSEL APPROVES]**
- **[NON SOLICITATION PERIOD]**
- **[END OF OPTIONAL CLAUSE]**

### Zella Voice Privacy and Security Operations Handbook

- **[HANDBOOK OWNER ROLE]**
- **[LAST REVIEWED DATE]**
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
- **[ACCOUNT DATA REQUEST LOG LOCATION]**
- **[LEGAL REQUESTS CONTACT]**
- **[OWNER DECISION: WHETHER TO PUBLISH A TRANSPARENCY REPORT]**
- **[NEEDED ONLY IF THE EU AND UK SECTIONS ARE KEPT. COUNSEL TO CONFIRM]**
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
- **[COUNSEL TO CONFIRM THIS MEETS PRIOR EXPRESS WRITTEN CONSENT UNDER THE TCPA, INCLUDING ANY ONE TO ONE CONSENT REQUIREMENT IN FORCE]**
- **[COUNSEL TO CONFIRM WHETHER PLATFORM LEAD FORMS CAN CARRY TCPA CONSENT FOR AI VOICE CALLS]**
- **[CONFIRM AGAINST THE RECEPTIONIST'S CURRENT SCRIPT]**
- **[COUNSEL TO SELECT THE RECORDING DISCLOSURE OPTION]**
- **[CUSTOMER LEGAL NAME]**
- **[CUSTOMER EIN]**
- **[CUSTOMER WEBSITE]**
- **[CUSTOMER INDUSTRY VERTICAL]**
- **[ADD A SCREENSHOT OR PUBLIC URL OF THE OPT IN FORM]**
- **[CONFIRM LINK DOMAIN]**
- **[YES OR NO]**
- **[MISMATCH: ADD A ONE TIME STOP CONFIRMATION BEFORE REGISTRATION, OR CONFIRM WITH COUNSEL AND THE CARRIER THAT IT IS NOT NEEDED]**
- **[MISMATCH: THE CURRENT HELP REPLY HAS NO CONTACT METHOD AND IS NOT SENT TO UNKNOWN NUMBERS]**
- **[CONFIRM WHETHER A START CONFIRMATION IS SENT]**
- **[REMOVE THE C AND R WORDING OR RESTORE THE KEYWORDS]**
- **[CONFIRM CURRENT BEHAVIOR]**
- **[UPDATE THE TEMPLATE SPELLING]**

<!-- ALL PLACEHOLDERS END -->
