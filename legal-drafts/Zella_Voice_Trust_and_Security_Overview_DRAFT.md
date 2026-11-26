# Zella Voice Trust and Security Overview

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Public page: security overview, vulnerability disclosure policy and accessibility statement. It is not in effect.

Effective date: **[EFFECTIVE DATE]**
Last updated: **[LAST UPDATED DATE]**

## 1. About this page

1.1 This page describes how Zella Voice protects Customer Data and how security researchers can report vulnerabilities. Capitalized terms have the meanings given in section 2 of the Zella Voice Terms of Service. The contractual security commitments are in Annex 2 of the Zella Voice Data Processing Addendum ("DPA"); if this page and the DPA differ, the DPA prevails.

1.2 **Status labels.** Each measure is marked **Live** (in production today) or **Built, going live** (built and tested, but not yet switched on or deployed). Zella Voice updates this page when a measure goes live. Zella Voice holds no security certification and makes no compliance claim.

## 2. Separation between businesses

| Measure | Status |
|---|---|
| Row level security on every database table; every business function checks the person's membership and role before reading or writing | Live |
| Automated tests that try to reach one business's data from another for every table, view, function and endpoint | Live (run before every change) |
| Public link pages (reschedule, waitlist offer, unsubscribe, continue plan) open one item only, by a private hashed code | Live |
| Files stored privately under each business's own path, checked after upload, refused files deleted | Live |

## 3. Access control

| Measure | Status |
|---|---|
| Roles of owner, admin, manager, staff and viewer, enforced by the database | Live |
| Call transcripts limited to managers and above, staff only if the Owner allows, never staff in Regulated Industries | Live |
| Private fields (such as access codes, member numbers and children's details) kept apart and never read aloud | Live |
| Two step sign in required for every Zella Voice administrator, who cannot remove their last authenticator | Built, going live |
| Two step sign in for Owners during onboarding | Built, going live |
| Administrators' changes to other administrators need a fresh authenticator code | Built, going live |
| Contact details masked in Zella Voice's administration tools, shown only with a recorded reason | Built, going live |
| Leaked password protection at sign in | **[CONFIRM WHETHER LEAKED PASSWORD PROTECTION IS ON]** |

## 4. Audit and oversight

| Measure | Status |
|---|---|
| Append only audit log of every privileged action, with sensitive data and secrets redacted | Live |
| Two person approval for risky actions such as exports, erasure and role changes | Live |
| Security log for each business showing who did what | Live |

## 5. Data protection

| Measure | Status |
|---|---|
| Encryption in transit | Live |
| Encryption at rest | **[CONFIRM ENCRYPTION AT REST WITH THE HOSTING PROVIDER]** |
| Secrets held only in the database vault and function secrets, never in code, logs or tables | Live |
| Logs hold no full telephone numbers, email addresses, message contents or transcripts | Live |
| Customer Data is never used to train AI models | Live |
| CSV export of customers and call history, and erasure of a customer's records in Zella Voice | Live |
| Whole business export, and deletion of erased calls at the voice provider | Built, going live **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]** |
| Scheduled automatic deletion of recordings and transcripts 90 days after the call, and deletion of copies at the voice provider **[DRAFT SCHEDULE: AUTOMATIC DELETION IS BUILT BUT NOT YET SWITCHED ON; CONFIRM IT IS ON BEFORE PUBLISHING]** | Built, going live (not yet switched on) |
| Deletion after cancellation, after **[CANCELLATION RETENTION PERIOD: 30 DAYS (PROPOSED) OR 90 DAYS (DATABASE FALLBACK), PENDING RESOLUTION]**, and account deletion after a 30 day grace period | Built, going live |
| Removal of payment card numbers that callers speak on calls from call transcripts | Not built; pending remediation |
| Backups with point in time recovery | **[CONFIRM POINT IN TIME RECOVERY IS ENABLED]** |

## 6. Application and AI security

| Measure | Status |
|---|---|
| Public entry points check size, rate and authentication before anything else | Live |
| Voice provider requests are refused unless authenticated; unsigned or replayed requests are refused | Live |
| Callers, messages and web pages are treated as untrusted input; the AI acts only through server checked tools | Live |
| Spam and abuse screening of calls, texts, emails and form posts | Live |
| Callers must give a booking's confirmation code before canceling or moving it | Built, going live |
| Security headers for the web application (framing blocked, strict transport security, content security policy in report mode) | Built, going live |

## 7. Availability

7.1 The status page at /status shows each part of the Services and public incidents. When the AI Receptionist is paused or unavailable, calls go to the Customer's Fallback Number. Every feature that reaches the outside world has its own switch so that it can be turned off quickly. **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]**

7.2 Support and service credits are described in Schedule 4 of the Zella Voice Terms of Service.

## 8. Providers

Zella Voice's providers and what each receives are listed in Annex 3 of the DPA, also kept at **[SUBPROCESSOR LIST LOCATION]**.

## 9. Vulnerability disclosure policy

### 9.1 Reporting

Report a suspected vulnerability to **[SECURITY CONTACT]**. Please include a description, the steps to reproduce it, the affected address or feature, and your contact details. Encrypt sensitive details if we publish a key at **[SECURITY KEY LOCATION, IF ANY]**.

### 9.2 Scope

In scope: **[IN SCOPE DOMAINS AND APPLICATIONS]**. Out of scope: services operated by Zella Voice's providers (report those to the provider), denial of service, spam, social engineering of staff or customers, physical attacks, and findings that need a compromised device.

### 9.3 Rules

- Use only test accounts you create or are given. Do not access, change or delete data that is not yours; if you reach someone else's data, stop and report it.
- Do not place calls, send texts or emails, or trigger bookings that reach real people.
- Do not run automated scans that degrade the Services.
- Give us reasonable time to fix an issue before disclosing it publicly, and agree the timing with us.

### 9.4 Our commitments

- Acknowledge your report within **[ACKNOWLEDGMENT PERIOD]** and keep you updated.
- Not pursue legal action against you for research that follows this policy in good faith. We consider such research authorized, and we will not bring claims under anti hacking or anti circumvention laws for it. This does not bind third parties. **[COUNSEL TO CONFIRM THE SAFE HARBOR WORDING]**
- Credit you publicly if you wish.

### 9.5 Rewards

Zella Voice does not run a paid bug bounty. **[OWNER DECISION: WHETHER TO OFFER REWARDS]**

### 9.6 security.txt

Suggested file for /.well-known/security.txt on each in scope domain:

| Field | Value |
|---|---|
| Contact | **[SECURITY CONTACT]** |
| Expires | **[SECURITY.TXT EXPIRY DATE]** |
| Policy | **[ADDRESS OF THIS PAGE]** |
| Preferred-Languages | en |
| Canonical | **[ADDRESS OF THE SECURITY.TXT FILE]** |

## 10. Accessibility statement

### 10.1 Our commitment

Zella Voice wants everyone to be able to use its web application, including people with disabilities. Our goal is that the Zella Voice web application meets the Web Content Accessibility Guidelines (WCAG) 2.2 at level AA. **This is a goal. Zella Voice does not claim that the web application conforms to WCAG 2.2 AA today.**

### 10.2 What we do today

Our design rules require, and our work so far includes:

- a visible focus ring on controls, and focus that moves to the heading of each new step in onboarding;
- keyboard operation for tabbed views (arrow keys, Home and End, one tab stop), radio style choices and toggle buttons, with accessible names and states on controls;
- motion that stops for people who have asked their device to reduce motion;
- text colors chosen for a contrast of at least 4.5 to 1 on our standard backgrounds;
- status labels that always include a word, not color alone;
- layouts that work on phones as well as computers.

These are design requirements we build to. They have not been independently audited.

### 10.3 Known limitations

**[KNOWN ACCESSIBILITY LIMITATIONS, AFTER AN AUDIT]**

The AI Receptionist is a voice service. Callers who cannot use voice calls can contact the business by its other channels, such as text or email, where the business offers them.

### 10.4 Report a barrier

If you find a barrier, contact **[ACCESSIBILITY CONTACT]** with the page, what you were trying to do and the assistive technology you use. We will respond within **[ACCESSIBILITY RESPONSE TIME]** and, where we can, offer another way to get what you need while we fix it.

### 10.5 Review

We review this statement **[ACCESSIBILITY STATEMENT REVIEW FREQUENCY]**. Last reviewed: **[LAST REVIEWED DATE]**.

## 11. Before publishing

This section is for the owner and counsel. Remove it before publishing. Change each "Built, going live" label to "Live" only once that measure is in production.

Placeholders in this document:

<!-- PLACEHOLDERS START -->

- **[EFFECTIVE DATE]**
- **[LAST UPDATED DATE]**
- **[CONFIRM WHETHER LEAKED PASSWORD PROTECTION IS ON]**
- **[CONFIRM ENCRYPTION AT REST WITH THE HOSTING PROVIDER]**
- **[BUILT, NOT YET LIVE: CONFIRM BEFORE PUBLISHING]**
- **[DRAFT SCHEDULE: AUTOMATIC DELETION IS BUILT BUT NOT YET SWITCHED ON; CONFIRM IT IS ON BEFORE PUBLISHING]**
- **[CANCELLATION RETENTION PERIOD: 30 DAYS (PROPOSED) OR 90 DAYS (DATABASE FALLBACK), PENDING RESOLUTION]**
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

<!-- PLACEHOLDERS END -->
