# Zella Voice Privacy and Security Operations Handbook

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Internal; not for publication. Part A Incident Response Plan; Part B Data Subject Request Procedure; Part C Law Enforcement and Legal Request Policy; Part D Record of Processing Activities; Part E Employee and Applicant Privacy Notice (to be given to staff and applicants).

Handbook owner: **[HANDBOOK OWNER ROLE]**
Last reviewed: **[LAST REVIEWED DATE]**

## Part A. Incident Response Plan

### A1. Scope

A1.1 This plan covers any event that may compromise the confidentiality, integrity or availability of Customer Data, Account Data or the Services, including a Personal Data Breach as defined in the Zella Voice Data Processing Addendum ("DPA"). Capitalized terms have the meanings given in the Zella Voice Terms of Service and the DPA.

A1.2 It works alongside the product's own runbooks and live switches: every feature that reaches the outside world can be switched off, and the platform raises admin alerts for failures.

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
3. **Contain.** Use the narrowest control that stops harm: switch off the affected live feature, pause automations for a business, suspend a business, revoke sessions, or rotate the exposed secret immediately and record the rotation.
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

1. **Log it.** Record the request in the CRM's data rights requests: the kind (access, export or erasure), the requester and a note. It is due 30 days after it is recorded, and a reminder is sent before it is due.
2. **Verify identity.** The Customer confirms the requester's identity using information it already holds. A request is not acted on until the identity is verified.
3. **Access or export.** The Owner exports the customer's records, or the customers and call history, as CSV. A whole business export can be requested from Zella Voice. **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]**
4. **Correct.** Staff correct the record in the CRM.
5. **Check for a legal hold.** Before any erasure, check whether a legal hold applies to the customer or the business. Data under a hold is excluded from erasure and from deletion at Vapi or any other provider until the hold is released. If a hold applies, ask Zella Voice before continuing.
6. **Erase.** The Owner erases the customer, except data under a hold. A second person must approve. Details, messages and calls, including transcripts, recordings and summaries, are removed, and deletion of the call at Vapi is queued; calls under a hold are not queued until the hold is released. Consent and opt out history is kept so that opt outs keep working. **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]**
7. **Opt out.** Opt outs by STOP, unsubscribe link or "don't call me" take effect immediately for that business and need no request.
8. **Report what was kept.** Tell the requester what was kept and why, including data under a legal hold (kept until the hold is released and then deleted on schedule), where the law allows.
9. **Close.** Mark the request done. Every step is recorded in the audit log.

### B3. How Zella Voice handles an Account Data request

1. Record it in the request log at **[ACCOUNT DATA REQUEST LOG LOCATION]**.
2. Verify the requester before acting:
   - **Authorized Users with an account:** through the account's sign in and, where needed, a fresh two step code.
   - **Requesters without an account** (visitors to public pages, former Authorized Users, and billing contacts): send a one time verification link or code to the email address on record, or the email address the requester gave when the data was collected, and ask for matching details that Zella Voice already holds (for example the business name, the approximate dates of contact or the last digits of an invoice number). Ask for no more information than is needed, and never for new sensitive data. For a request to delete or to see specific pieces of information, require a higher degree of matching. **[COUNSEL TO CONFIRM THE MATCHING STANDARD]**
   - **Authorized agents:** verify the agent's own identity by a reasonable method that does not depend on the principal's email (for example a one time code to the agent's own email or telephone, plus matching details of the agent), require a signed authorization from the principal or a valid power of attorney, and, where the law allows, confirm the request directly with the person the data is about. **[COUNSEL TO CONFIRM THE AGENT VERIFICATION STANDARD]**
   - If identity cannot be verified, tell the requester why and what is needed, and record the outcome.
3. Search Account Data across the account, billing records, identity verification records and support records.
4. Respond within 30 days, using the tools above where they apply. Keep only what the law requires.
5. For California, also honor authorized agent requests with proof of authority.

## Part C. Law Enforcement and Legal Request Policy

### C1. Principles

C1.1 Zella Voice discloses Customer Data or Account Data to a government authority or other third party only where valid and binding legal process requires it, such as a subpoena, court order or search warrant, or where the law permits disclosure to prevent imminent death or serious physical harm.

C1.2 Zella Voice redirects requests for Customer Data to the Customer wherever possible.

### C2. Steps

1. **Receive.** Requests go to **[LEGAL REQUESTS CONTACT]** and are forwarded to counsel.
2. **Validate.** Counsel confirms the process is valid, properly served, issued by an authority with jurisdiction, and specific.
3. **Narrow.** Zella Voice challenges or seeks to narrow requests that are overbroad, unclear or not legally binding, and discloses only the minimum data required.
4. **Notify the Customer.** Zella Voice notifies the affected Customer before disclosing, unless the law or a court order prohibits notice, or notice would create a risk of death or serious harm. If notice is delayed, Zella Voice notifies the Customer when the restriction ends.
5. **Disclose securely.** Data is produced through a secure channel, and the production is recorded.
6. **Log.** Each request is recorded with: the requesting authority; the type of process; the date received; the data requested; the data disclosed; whether the Customer was notified and when; and counsel's sign off.

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
- **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]**
- **[ACCOUNT DATA REQUEST LOG LOCATION]**
- **[COUNSEL TO CONFIRM THE MATCHING STANDARD]**
- **[COUNSEL TO CONFIRM THE AGENT VERIFICATION STANDARD]**
- **[LEGAL REQUESTS CONTACT]**
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
