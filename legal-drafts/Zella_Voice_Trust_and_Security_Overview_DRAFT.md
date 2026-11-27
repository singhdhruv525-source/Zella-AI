# Zella Voice Trust and Security Overview

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Public page: security overview, vulnerability disclosure policy and accessibility statement. It is not in effect.

Effective date: **[EFFECTIVE DATE]**
Last updated: **[LAST UPDATED DATE]**

## 1. About this page

1.1 This page describes how Zella Voice protects Customer Data and how security researchers can report vulnerabilities. Capitalized terms have the meanings given in section 2 of the Zella Voice Terms of Service. The contractual security commitments are in Annex 2 of the Zella Voice Data Processing Addendum ("DPA"); if this page and the DPA differ, the DPA prevails.

1.2 Zella Voice holds no security certification and makes no compliance claim.

## 2. Separation between businesses

- Access is separated between businesses by database policies on every table, and every business function checks the person's membership and role before reading or writing.
- Public link pages (reschedule, waitlist offer, unsubscribe, continue plan) open one item only, by a private hashed code.
- Files are stored privately under each business's own path and checked after upload; refused files are deleted.

## 3. Access control

- Roles of owner, admin, manager, staff and viewer are enforced by the database.
- Call transcripts are limited to managers and above, to staff only if the Owner allows it, and never to staff in Regulated Industries.
- Private fields, such as access codes, member numbers and children's details, are kept apart and never read aloud.
- Every Zella Voice administrator must use two step sign in and cannot remove their last authenticator. Owners set up two step sign in during onboarding.
- Changes by one administrator to another need a fresh authenticator code.
- Contact details are masked in Zella Voice's administration tools and shown only with a recorded reason.
- Sign in rejects passwords known to have leaked.

## 4. Audit and oversight

- An append only audit log records every privileged action, with sensitive data and secrets redacted.
- Erasing a customer needs a second owner's or admin's approval where the business has two or more owners or admins.
- A whole business export needs the approval of a second Zella Voice owner.
- Each business has a security log showing who did what.

## 5. Data protection

- Information is encrypted in transit, including connections from the web application to the database service and voice provider webhooks, which use HTTPS, and encrypted at rest.
- Secrets are held only in the database vault and function secrets, never in code, logs or tables.
- Logs hold no full telephone numbers, email addresses, message contents or transcripts.
- Customer Data is never used to train AI models.
- Payment cards are held by Stripe. Zella Voice never receives or stores the full card number or security code entered on Stripe's pages; for billing notices it keeps only the card brand and last 4 digits, provided by Stripe.
- The AI Receptionist never asks for, reads back or records card or bank details, and stops a caller who starts to give them. Card details that a caller speaks on a call anyway, such as a card number, security code or expiry date, are masked in call transcripts and summaries before they are stored and are not kept in call recordings.
- Each business can export its customers and call history and erase a customer's records; a whole business export is available on request.
- Subject to legal holds, recordings and transcripts are deleted automatically 90 days after the call, or earlier when they are erased, at the end of the export window after cancellation, or on account deletion, and the copies held by the voice provider are deleted where technically possible. Data under a legal hold is kept until the hold is released and then deleted on schedule. Where a healthcare business has asked, under its business associate agreement, for a transcript or recording to be returned, that item, including the voice provider's copy, is kept until it is returned, even past the 90 day date or the end of the export window, and for no longer than the limited period in section 12.1 of the Data Processing Addendum, and is then deleted. Where an item is both under a legal hold and named in a return request, section S1.6.3(e) of Schedule 1 to the Data Processing Addendum decides which rule applies.
- After cancellation, data is deleted after **[CANCELLATION RETENTION PERIOD]**, and an account deletion request takes effect after a 30 day grace period, in each case except consent and opt out history, audit and security logs, data under a legal hold, a transcript or recording named in a pending return request under a business associate agreement (kept only for the limited period in sections 12.1 to 12.3 of the Data Processing Addendum), and data the law requires to be kept.
- Backups allow point in time recovery.

## 6. Application and AI security

- Public entry points check size, rate and authentication before anything else.
- Voice provider requests are refused unless authenticated; unsigned or replayed requests are refused.
- Callers, messages and web pages are treated as untrusted input; the AI acts only through server checked tools.
- Calls, texts, emails and form posts are screened for spam and abuse.
- Callers must give a booking's confirmation code before canceling or moving it.
- The web application sends security headers that block framing and require strict transport security, with a content security policy.

## 7. Availability

7.1 The status page at /status shows each part of the Services and public incidents. When the AI Receptionist is paused or unavailable, calls go to the Customer's Fallback Number. Every feature that reaches the outside world has its own switch so that it can be turned off quickly.

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

### 10.2 What we do

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

This section is for the owner and counsel. Remove it before publishing. Do not publish this document until every launch blocker in section 4 of the counsel memo that concerns it has been cleared.

Placeholders in this document:

<!-- PLACEHOLDERS START -->

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

<!-- PLACEHOLDERS END -->
