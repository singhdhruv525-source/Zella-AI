# Zella Voice Privacy and Security Operations Handbook

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Internal; not for publication. Part A Incident Response Plan; Part B Data Subject Request Procedure; Part C Law Enforcement and Legal Request Policy; Part D Record of Processing Activities; Part E Employee and Applicant Privacy Notice (to be given to staff and applicants).

These procedures take effect at launch. Zella Voice has not launched yet; until then, use them to rehearse and test, and treat any step that depends on a control listed as a launch blocker in section 4 of the counsel memo as manual.

Handbook owner: **[HANDBOOK OWNER ROLE]**
Last reviewed: **[LAST REVIEWED DATE]**

## Part A. Incident Response Plan

### A1. Scope

A1.1 This plan covers any event that may compromise the confidentiality, integrity or availability of Customer Data, Account Data or the Services, including a Personal Data Breach as defined in the Zella Voice Data Processing Addendum ("DPA"). Capitalized terms have the meanings given in the Zella Voice Terms of Service and the DPA.

A1.2 It works alongside the product's own runbooks and controls. Several incident controls are built but not yet live: per feature live switches for everything that reaches the outside world (all off in production today), pausing all automations for one business, signing an administrator out of every device, and admin alerts for failures. Until each is confirmed live, use only the controls the owner confirms are available today, which are expected to include the provider dashboards and the secret stores for rotating keys. **[CONFIRM WHICH INCIDENT CONTROLS ARE AVAILABLE TODAY]**

### A2. Roles

| Role | Responsibility | Assigned to |
|---|---|---|
| Incident lead | Runs the response, decides severity, keeps the log | **[INCIDENT LEAD ROLE]** |
| Technical lead | Contains, investigates and fixes | **[TECHNICAL LEAD ROLE]** |
| Communications lead | Customer, provider and public messages | **[COMMUNICATIONS LEAD ROLE]** |
| Legal counsel | Notification duties, legal hold, regulators | **[LEGAL COUNSEL CONTACT]** |
| Owner approval | Approves every production change, live switch and external notice, as the rulebook requires | The Zella Voice owner |

### A3. Severity levels

| Level | Meaning | Examples |
|---|---|---|
| Severity 1 | Confirmed or likely access to Personal Data by an unauthorized person, or one business able to see another's data, or the AI Receptionist down for every Customer | A secret exposed, a cross business data leak, a provider breach affecting Customer Data |
| Severity 2 | Possible exposure under investigation, or a major feature down for many Customers | Suspicious admin activity, messages sent wrongly, a payment or messaging provider outage |
| Severity 3 | Limited impact, no Personal Data exposure | A single Customer's integration failing, a contained bug |

### A4. Steps

1. **Detect and record.** Open an incident log entry (section A6) as soon as an incident is suspected.
2. **Assess.** Assign a severity and the roles above. For Severity 1 or 2, inform the owner and counsel at once.
3. **Contain.** Use the narrowest control that stops harm: switch off the affected live feature, pause automations for a business, suspend a business, revoke sessions, or rotate the exposed secret immediately and record the rotation. Switching features off, suspending a business or changing production follows the owner's explicit approval for that action (NN 3, NN 4); for Severity 1, obtain it at once, by the fastest channel, and record it. Rotating an exposed secret is done immediately, as the rulebook requires (SEC 3), and recorded.
4. **Preserve evidence.** Keep audit logs and provider records. Place a legal hold where counsel asks, so that scheduled deletion does not remove evidence.
5. **Investigate.** Establish what happened, which Customers, data subjects and records are affected, and when.
6. **Notify.** Follow section A5.
7. **Recover.** Fix the cause through the normal reviewed change process, with the owner's approval for production changes, and confirm with evidence.
8. **Review.** Within **[POST INCIDENT REVIEW PERIOD]**, write a blameless review with actions and update the documentation and this plan.

### A5. Notification timelines

| Who | When | Basis |
|---|---|---|
| Affected Customers | Without undue delay and within **[BREACH NOTIFICATION HOURS]** hours of becoming aware of a Personal Data Breach | DPA section 11 |
| Healthcare Customers under a signed BAA | Within **[BAA BREACH NOTICE DAYS]** calendar days of discovery | DPA Schedule 1, section S1.3.3 |
| Individuals and state regulators, for Account Data where Zella Voice is controller | As required by applicable state breach notification laws | **[COUNSEL TO MAP STATE BREACH NOTIFICATION DEADLINES AND REGULATOR THRESHOLDS]** |
| EU and UK supervisory authorities, if those sections are kept | Within 72 hours where Zella Voice is controller and notification is required | **[COUNSEL TO CONFIRM]** |
| Data Protection Board of India, if applicable | As the DPDP Act and its rules require | **[COUNSEL TO CONFIRM]** |
| Providers and carriers | As their agreements require | **[VENDOR CONTRACT NOTICE TERMS]** |

Customers decide whether to notify their own End Users and regulators for Customer Personal Data; Zella Voice helps them.

### A6. Incident log

Each incident is recorded with: an identifier; the time detected and by whom; the severity; a description; the systems, Customers and data affected; containment steps and times; notifications given (who, when, how); the root cause; actions and owners; and the time closed. The log is kept for **[INCIDENT LOG RETENTION PERIOD]** at **[INCIDENT LOG LOCATION]**. Secrets and customer data are never copied into it.

## Part B. Data Subject Request Procedure

### B1. Two kinds of request

B1.1 **End Users (Customer Personal Data).** The Customer is the controller. Zella Voice forwards the request to the Customer promptly and does not answer it except to direct the person to the Customer, unless the Customer instructs Zella Voice in writing to respond, or the law requires Zella Voice to respond (DPA section 9.2). Any such response is recorded in the request log.

B1.2 **Authorized Users and visitors (Account Data).** Zella Voice is the controller and answers the request itself, within 30 days or sooner if the law requires.

### B2. How a Customer handles an End User request in the Services

1. **Log it.** Record the request in the CRM's data rights requests: the kind (access, export or erasure), the requester and a note. It is due 30 days after it is recorded, and a daily job is designed to remind the Owner before it is due **[CONFIRM THE DAILY REMINDER JOB IS SWITCHED ON]**.
2. **Verify identity.** The Customer confirms the requester's identity using information it already holds. A request is not acted on until the identity is verified.
3. **Access or export.** Fulfill the request item by item; an export alone does not complete it.
   - **One End User's records (the file for the request):** an owner or admin opens the logged request in the CRM (on the person's customer record, or in Settings under the list of customer data requests) and carries it out. This produces a file of that person's records only: their customer record, appointments, texts, emails, calls with summaries and transcripts, callbacks, consent history and requests. Before sending it, for a Customer in a Regulated Industry, remove every call transcript from the file (the product does not yet leave them out: launch blocker 35 in the counsel memo); then, check that it holds only the requester's records. **Never use the CSV exports of all customers or call history, or the whole business export, for an End User's access or export request**: those files hold other people's data.
   - **Call transcripts and summaries:** these are in the request file above. Where a single call must also be shown, the person with access opens it in the CRM (Calls, call details): in a business outside the Regulated Industries, owners, admins and managers can open transcripts, and staff can too where the Owner has allowed staff to read call content in Settings, Call recording and privacy (the database checks this); viewers and other staff ask a manager. Deliver the file to the verified requester through **[SECURE DELIVERY CHANNEL FOR DATA SUBJECT REQUESTS]**, never by ordinary email attachment.
   - **Transcripts of Customers in Regulated Industries:** the public documents say every export leaves them out, including the request file (Privacy Policy 11.1, DPA 9.1). Until launch blocker 35 is cleared, the request file still contains them, so remove them before sending as above. In the CRM, owners, admins and managers can open them and staff never can, even if the Owner has allowed staff access; the whole business export leaves them out. Where the law gives the requester a right to see a regulated transcript, ask counsel how to provide it (counsel memo, owner decision 41) instead of sending it in the file.
   - **Recordings:** where recording was on for the Customer, an owner, admin or manager plays the recording from the call details and, if it can be saved, delivers it as above; otherwise the Owner asks Zella Voice to retrieve it from the voice provider. Recording links themselves are never exported.
   - **Items that cannot be delivered:** if no route can deliver an item (for example a recording already deleted under the 90 day schedule, or an item held only by the voice provider that cannot be retrieved), record the exception and the reason in the request's closing note, tell the requester within the 30 day deadline which items were not provided and why, and how to raise a concern with the Customer. **[COUNSEL TO CONFIRM THE RESPONSE OWED FOR ITEMS THAT CANNOT BE PROVIDED]**
4. **Correct.** Staff correct the record in the CRM.
5. **Check for a legal hold (manual).** Before any erasure, staff must check with Zella Voice whether a legal hold applies to the customer or the business. **[NOT YET ENFORCED BY THE PRODUCT: ERASURE DOES NOT CHECK LEGAL HOLDS TODAY; STAFF MUST CHECK MANUALLY BEFORE ERASING]** Data under a hold must be excluded from erasure and from deletion at Vapi or any other provider until the hold is released; until the product enforces this, do not run the erasure while a hold applies. This check is point in time: a hold placed after the check and before the erasure runs is not protected by it. Interim control until the product enforces holds: the person who will run the erasure rechecks with **[LEGAL HOLD CONTROL OWNER]** immediately before running it, and records both checks (time and result) with the hold record kept by **[LEGAL HOLD CONTROL OWNER]**; **[LEGAL HOLD CONTROL OWNER]** tells every pending erasure owner at once when a new hold is placed. Some residual risk remains between the final check and the erasure, so erasures run promptly after it. If a hold applies, record it against the request: in Zella Voice's legal hold record and, if the hold was known when the request was logged, in the request's note (hold reference and date). **[CONFIRM HOW A HOLD IS RECORDED AGAINST AN OPEN REQUEST: THE REQUEST NOTE CAN ONLY BE SET WHEN THE REQUEST IS LOGGED OR CLOSED]** Also check for a pending return request (manual): for a Customer with a business associate agreement, check whether a return request under DPA Schedule 1, section S1.6.3 names any of the person's transcripts or recordings. The product does not track return requests (counsel memo, launch blocker 37), so this check is manual. Only the named item is kept: it must not be erased, and its deletion at Vapi must not be queued, until it is returned or **[BAA RETURN PERIOD]** days have passed since the return request (DPA 12.1), whichever comes first; the rest of the erasure goes ahead on time. Record the return request against the erasure request as for a hold. **[COUNSEL TO CONFIRM THAT ONLY THE NAMED ITEM IS KEPT AND THE REST OF THE ERASURE PROCEEDS ON TIME]**
6. **Erase.** The Owner erases the customer, only after step 5 confirms that no hold applies. A pending return request does not delay the erasure: it keeps only the named transcript or recording and its copy at Vapi. The product's erasure cannot yet leave out a single item (launch blocker 37), so until it can, Zella Voice runs the erasure with the named items left out as a production action approved for that erasure, on time; if that cannot be done in time, the delay is limited to what is needed and recorded with the reason. The erasure needs the approval of a second owner or admin when the Customer has two or more active owners or admins; a Customer with only one owner or admin has no second approver, and the erasure is still recorded in the audit log. Details, messages and calls, including transcripts, recordings and summaries, are removed, and deletion of the call at Vapi is queued; because erasure does not check holds today, the manual check in step 5 is what keeps held calls from being erased or queued (the Vapi deletion sender is designed to hold back calls of a business on hold, but it is not yet live). Consent and opt out history is kept so that opt outs keep working. **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]**
7. **Opt out.** Opt outs by STOP, unsubscribe link or "don't call me" take effect immediately for that business and need no request.
8. **Report what was kept (erasure requests).** For an erasure request, tell the requester what was kept and why, including consent and opt out history (kept so the opt out keeps working) data under a legal hold (kept until the hold is released and then deleted on schedule), and any transcript or recording named in a pending return request (only that item and its copy at Vapi, kept until it is returned, and for no longer than the DPA 12.1 period, then deleted; everything else was erased on time), where the law allows.
9. **Close.** For an erasure request, keep the request open while the deletion at Vapi is pending, track the result, and mark it done only after the deletion succeeds or an exception (for example "not found at the provider") is recorded. If any data was kept under a legal hold, keep the request in its open status (the request log supports only open, done and rejected) until the hold is released, with the hold recorded as step 5 requires (reference and date); do the same for an item kept for a pending return request (the rest of the erasure having gone ahead), and erase that item and queue its deletion at Vapi once it is returned or the DPA 12.1 period ends; when the request is finally closed, the closing note states the hold and its release date. The daily reminder will keep flagging the request as due or overdue while it is open; note the hold as the reason. When the hold is released, **[LEGAL HOLD CONTROL OWNER]**, triggered by the hold release, asks the Customer's Owner to run the erasure for the held data through the same steps (5 and 6, including the recheck), which also queues the deletion at Vapi, and closes the request only after that deletion succeeds or an exception is recorded. For other requests, mark the request done when answered. Every step is recorded in the audit log.

### B3. How Zella Voice handles an Account Data request

1. Record it in the request log at **[ACCOUNT DATA REQUEST LOG LOCATION]**.
2. Verify the requester before acting:
   - **Authorized Users with an account:** through the account's sign in and, where needed, a fresh two step code.
   - **Requesters without an account** (visitors to public pages, former Authorized Users, and billing contacts): send a one time verification link or code to the email address on record, or the email address the requester gave when the data was collected, and ask for matching details that Zella Voice already holds (for example the business name, the approximate dates of contact or the last digits of an invoice number). Ask for no more information than is needed, and never for new sensitive data. For a request to delete or to see specific pieces of information, require a higher degree of matching. **[COUNSEL TO CONFIRM THE MATCHING STANDARD]** Where no email address is on record and the requester gave none when the data was collected: **[COUNSEL TO SET THE VERIFICATION METHOD FOR REQUESTERS WITH NO EMAIL ADDRESS ON RECORD]**
   - **Authorized agents:** verify the agent's own identity by a reasonable method that does not depend on the principal's email (for example a one time code to the agent's own email or telephone, plus matching details of the agent), require a signed authorization from the principal or a valid power of attorney, and, where the law allows, confirm the request directly with the person the data is about. **[COUNSEL TO CONFIRM THE AGENT VERIFICATION STANDARD]**
   - If identity cannot be verified, tell the requester why and what is needed, and record the outcome.
3. Search all Personal Data held about the requester, as the Privacy Policy describes it (sections 3.1 and 3.3): the account, invitations and acceptance records, billing records, identity verification records, support requests and correspondence, and technical and security data (network address and browser records, security and audit logs, and rate limit records). For a visitor without an account, search the technical and security data and any correspondence by the details the requester provides.
4. Respond within 30 days, using the tools above where they apply. For an access, correction or export request, keep the Account Data needed to provide the Services and correct it where asked. For a deletion request, delete the data and keep only what the law requires or the exceptions allow (consent and opt out history, audit and security logs, and data under a legal hold).
5. For California, also honor authorized agent requests with proof of authority.

## Part C. Law Enforcement and Legal Request Policy

### C1. Principles

C1.1 This policy applies to requests from a government authority, a court, a litigant or another third party for Customer Data or Account Data. In answer to such a request, Zella Voice discloses data only where valid and binding legal process requires it, such as a subpoena, court order or search warrant, or where the law permits disclosure to prevent imminent death or serious physical harm. This policy does not restrict authorized processing for providing the Services, including disclosures to Subprocessors and the other recipients listed in Part D (for example the billing provider), which are governed by the DPA and the Zella Voice Privacy Policy.

C1.2 Zella Voice redirects requests for Customer Data to the Customer wherever possible.

### C2. Steps

1. **Receive.** Requests go to **[LEGAL REQUESTS CONTACT]** and are forwarded to counsel.
2. **Validate.** Counsel confirms the process is valid, properly served, issued by an authority with jurisdiction, and specific. An emergency request without legal process follows section C2A instead of this step.
3. **Narrow.** Zella Voice challenges or seeks to narrow requests that are overbroad, unclear or not legally binding, and discloses only the minimum data required.
4. **Notify the Customer.** Zella Voice notifies the affected Customer before disclosing, unless the law or a court order prohibits notice, or notice would create a risk of death or serious harm. If notice is delayed, Zella Voice notifies the Customer when the restriction ends.
5. **Disclose securely.** Data is produced through a secure channel, and the production is recorded.
6. **Log.** Each request is recorded with: the requesting authority; the type of process; the date received; the data requested; the data disclosed; whether the Customer was notified and when; and counsel's sign off.

### C2A. Emergency requests without legal process

Use this procedure when a requester without legal process, for example law enforcement, says that disclosure is needed to prevent imminent death or serious physical harm. It replaces step 2 (Validate) of section C2; the other steps still apply as stated below.

1. **Escalate at once.** The request goes to **[LEGAL REQUESTS CONTACT]** and to counsel immediately, at any hour.
2. **Verify the requester.** Confirm the requester's identity and authority by calling back through an official number found independently, not one given in the request. Record the emergency as the requester describes it.
3. **Decide.** Counsel, or **[EMERGENCY DECISION OWNER]** if counsel cannot be reached in time, decides in good faith whether the facts show an emergency involving danger of death or serious physical injury that requires disclosure without delay, and whether the law allows disclosure without legal process **[COUNSEL TO CONFIRM THE LEGAL BASIS FOR EMERGENCY DISCLOSURE, INCLUDING 18 U.S.C. 2702 AND ANY STATE LAW]**. Disclose only where both are true and the law allows it; otherwise tell the requester to obtain legal process under section C2.
4. **Disclose the minimum.** Disclose only the data needed to deal with the emergency, through a secure channel.
5. **Notify the Customer** under step 4 of section C2, as soon as notice no longer creates a risk of death or serious harm.
6. **Log and review.** Record the request as step 6 of section C2 requires, and also the emergency described, the verification steps, who decided and the legal basis. Counsel reviews every emergency disclosure afterwards, and Zella Voice asks the requester to follow up with legal process where the law expects it.

### C3. Transparency

**[OWNER DECISION: WHETHER TO PUBLISH A TRANSPARENCY REPORT]**

## Part D. Record of Processing Activities

**[COUNSEL TO ASSESS WHETHER THE GDPR OR UK GDPR APPLIES TO ZELLA VOICE, AND IF SO WHETHER ARTICLE 30 REQUIRES THIS RECORD OR ONE OF ITS EXCEPTIONS APPLIES; KEEPING OR REMOVING THE EU AND UK SECTIONS DOES NOT DECIDE THIS]**

### D1. As controller (Account Data)

| Item | Entry |
|---|---|
| Controller | **[LEGAL ENTITY NAME]**, **[REGISTERED ADDRESS]**; contact **[PRIVACY CONTACT EMAIL]**; representative **[EU REPRESENTATIVE, IF REQUIRED]** |
| Purposes | Accounts and onboarding; Owner identity verification; billing; security and abuse prevention; support; service notices; legal compliance |
| Data subjects | Authorized Users; Customer billing and other contacts; visitors to public pages |
| Data categories | Identity and contact details; sign in and security records; identity documents; billing records; support correspondence; network and browser data |
| Recipients | Providers in Annex 3 of the DPA, including Stripe (where enabled), Google Fonts, the identity verification provider (where enabled) and the email inbox provider |
| Transfers | To the United States and provider locations, under **[TRANSFER MECHANISM, FOR EXAMPLE THE EU STANDARD CONTRACTUAL CLAUSES AND THE UK INTERNATIONAL DATA TRANSFER AGREEMENT OR ADDENDUM]** |
| Retention | As in section 10 of the Zella Voice Privacy Policy |
| Security | As in Annex 2 of the DPA |

### D2. As processor (Customer Personal Data)

| Item | Entry |
|---|---|
| Processor | **[LEGAL ENTITY NAME]**; contact **[PRIVACY CONTACT EMAIL]** |
| Controllers | Each Customer, as listed in the Services' business records |
| Categories of processing | As in Annex 1 of the DPA |
| Subprocessors | Annex 3 of the DPA |
| Transfers | As in section 14 of the DPA |
| Security | Annex 2 of the DPA |

## Part E. Employee and Applicant Privacy Notice

**[COUNSEL ITEM: confirm the California CPRA notice at collection for employees and applicants (categories, purposes, whether information is sold or shared, retention for each category, and sensitive personal information), and any other state or country requirements, before use.]**

### E1. Who this notice is for

This notice explains how **[LEGAL ENTITY NAME]** ("Zella Voice") handles personal information about job applicants, employees, contractors and former staff ("you"). It does not cover Customer Data or Account Data, which the Zella Voice Privacy Policy covers.

### E2. What we collect

| Category | Examples |
|---|---|
| Identifiers and contact details | Name, address, email, telephone, emergency contact |
| Application information | Resume, work history, education, references, interview notes, assessment results |
| Employment information | Role, compensation, benefits, performance, time off, training, signed agreements |
| Government identifiers and right to work | Tax identification number, work authorization documents, as the law requires |
| Financial information | Bank details for payroll and expense reimbursement |
| Systems and security information | Accounts, sign in and two step sign in records, and the audit log of privileged actions in Zella Voice's systems |
| Sensitive personal information | Government identifiers, and health or disability information only where needed for leave, accommodations or law; demographic information only where voluntarily given for equal opportunity reporting |

### E3. Why we use it

To recruit and assess applicants; to hire and onboard; to pay and provide benefits; to manage work, performance and training; to keep systems secure, including audit logs of administrative actions; to comply with employment, tax and other laws; and to establish or defend legal claims. We do not sell or share this information for cross context behavioral advertising, and we use sensitive personal information only for these purposes.

### E4. Who receives it

Payroll, benefits and recruiting providers **[HR PROVIDERS]**, professional advisers, and authorities where the law requires.

### E5. How long we keep it

| Information | Retention |
|---|---|
| Applicants not hired | **[APPLICANT RECORD RETENTION PERIOD]** |
| Employee and contractor records | **[EMPLOYEE RECORD RETENTION PERIOD]** after employment ends |
| Payroll and tax records | **[PAYROLL RECORD RETENTION PERIOD]** |
| Audit and security logs | 7 years, as for all audit logs |

### E6. Your rights and contact

Depending on where you live, you may have rights to know, access, correct and delete your personal information and to limit use of sensitive personal information. Zella Voice will not retaliate against you for using them. Contact **[HR PRIVACY CONTACT]**.

## Before publishing

This handbook is internal and is never published. Counsel and the owner must review it before it is relied on.

Placeholders in this document:

<!-- PLACEHOLDERS START -->

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

<!-- PLACEHOLDERS END -->
