# Zella Voice Consent and Carrier Registration Pack

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Wording for consent capture, caller disclosures and texting registration. For Customers and for Zella Voice's registration work. It is not in effect.

Last updated: **[LAST UPDATED DATE]**

## 1. How to use this pack

1.1 This pack gives ready wording for the places where the Services collect consent or make disclosures, and the text needed to register a Customer's brand and campaign for application to person texting (10DLC). Capitalized terms have the meanings given in section 2 of the Zella Voice Terms of Service ("Terms"). The Zella Voice Messaging Terms are the program terms that this pack points to.

1.2 Every message template quoted here is taken from the Services' own templates. Placeholders in curly braces, such as {business} and {first_name}, are filled in by the Services. Bold bracketed placeholders are for the owner or counsel.

1.3 Texts to a Customer's End Users start only after the Customer's registration is approved (Terms, section 5.5). Texts and emails are Live Features and are off until switched on.

## 2. Web form and lead capture consent

### 2.1 Service messages (required for automated calls and texts about an enquiry)

Unticked checkbox, shown next to the telephone number field:

"I agree that {business} may contact me by phone call, including calls using an automated or AI voice, and by text message at the number I provided, about my enquiry. Consent is not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply STOP to opt out, HELP for help. See our Messaging Terms and Privacy Policy." **[LINKS TO THE CUSTOMER'S PRIVACY POLICY AND THE MESSAGING TERMS]**

### 2.2 Marketing messages (separate, optional)

A second unticked checkbox, never combined with the first:

"I also agree to receive marketing calls and text messages, including offers, from {business} at the number I provided, which may use an automated or AI voice or an automatic system. Consent is not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply STOP to opt out." **[COUNSEL TO CONFIRM THIS MEETS PRIOR EXPRESS WRITTEN CONSENT UNDER THE TCPA, INCLUDING ANY ONE TO ONE CONSENT REQUIREMENT IN FORCE]**

### 2.3 What the Services record for every consent

Every consent or opt out is stored in an append only consent history for the Customer that collected it, with: the telephone number or email address; the channel (call, text or email); the purpose (service or marketing); the status (for example opted in or opted out); the source; the keyword used, for a texted keyword; who recorded it, for a staff entry; the time it was recorded; and an evidence record. Consent is never shared between Customers.

### 2.4 Evidence kept for each source

The evidence for each source below is what the architecture specifies (its consent capture design, proposed for counsel review). **[CONFIRM THAT THE PRODUCT STORES THIS EVIDENCE FOR EACH SOURCE BEFORE RELYING ON IT]**

| Source | Consent basis | Evidence kept |
|---|---|---|
| Website forms and chat widget | The unticked checkbox in section 2.1 (and section 2.2 for marketing) | Form version, exact text shown, time, network address and checkbox state |
| Google Ads lead forms and Meta lead ads (where enabled) | The same consent text configured as the lead form's custom disclosure; leads without it are not called automatically. **[COUNSEL TO CONFIRM WHETHER PLATFORM LEAD FORMS CAN CARRY TCPA CONSENT FOR AI VOICE CALLS]** | The form identifier and the disclosure version from the source |
| Inbound callers (verbal) | The caller asks to be called or texted back, or agrees when the AI Receptionist asks before any confirmation text is sent | The call identifier, the time and the caller's answer. No form, text version or checkbox applies |
| Missed calls | The caller called the business; one missed call text and the callback respond to that call. **[COUNSEL TO CONFIRM]** | The call identifier |
| Leads added by hand or imported | Staff choose the consent basis and source for each channel; with none chosen, the person is stored but never called or texted automatically | The staff member, the time and the basis chosen |
| Marketing (any source) | A separate, explicit opt in for each channel | As for the source through which it was given |

## 3. In call AI disclosure

3.1 **Default greeting:** "Thank you for calling {business}. I'm the AI receptionist. How can I help you today?"

3.2 **Rule:** a Customer may change the greeting, but the AI disclosure cannot be removed; where a custom greeting leaves it out, the disclosure is added in the caller's language. (Built, going live.)

3.3 **If asked whether it is a person:** the AI Receptionist says it is an AI assistant.

3.4 **Consent for confirmation texts during a call (suggested line):** "Would you like me to text you a confirmation at this number? Message and data rates may apply, and you can reply STOP at any time." **[CONFIRM AGAINST THE RECEPTIONIST'S CURRENT SCRIPT]**

## 4. Recording disclosure options

Call recording is off until legal review. If it is turned on, choose one option per Customer, with counsel's approval:

| Option | Wording | Notes |
|---|---|---|
| A. Notice (current product line) | "This call is recorded." | Notice only. May not be enough in states that require the consent of all parties |
| B. Notice with implied consent | "This call is recorded. By staying on the line, you agree to the recording." | Counsel to confirm for each state where callers are located |
| C. Active consent | "This call may be recorded. Is that okay with you?" If the caller says no, the call continues without recording | Strongest; needs a product change so that a "no" turns recording off |

**[COUNSEL TO SELECT THE RECORDING DISCLOSURE OPTION]**

Inbound voicemail prompt (designed in the architecture; the voicemail feature is not yet available): "Please leave your message after the tone. It will be recorded and passed to the team." A voicemail is the caller's own recorded message and is separate from call recording.

## 5. 10DLC brand and campaign registration text

### 5.1 Brand

| Field | Entry |
|---|---|
| Legal company name | **[CUSTOMER LEGAL NAME]** (each Customer registers its own brand) |
| Tax identification number | **[CUSTOMER EIN]** |
| Website | **[CUSTOMER WEBSITE]** |
| Vertical | **[CUSTOMER INDUSTRY VERTICAL]** |

### 5.2 Campaign

| Field | Entry |
|---|---|
| Use case | Mixed: customer care and account notifications (appointment confirmations and reminders, booking changes, missed call follow up, replies to enquiries). Add marketing only if the Customer collects marketing consent under section 2.2 |
| Description | {business} uses the Zella Voice platform to send appointment confirmations and reminders, booking change confirmations, waitlist openings, replies and follow ups about a customer's own enquiry, and one text after a missed call. Messages go to people who gave their number to {business} and agreed to receive texts, and, for the single missed call text, to a caller whose call {business} missed, in response to that call. Message frequency varies. **[COUNSEL TO CONFIRM THE MISSED CALL BASIS BEFORE REGISTRATION; IF NOT CONFIRMED, REMOVE THE MISSED CALL TEXT FROM THIS CAMPAIGN]** |
| Opt in flow | Customers opt in by ticking an unticked consent box on {business}'s website or lead form (wording in section 2.1), by agreeing during a call with {business}'s AI receptionist before any confirmation text is sent, or by texting {business} first. Separately, a caller whose call to {business} was missed may receive one text in response to that call, which identifies {business} and says how to opt out; this basis relies on the caller's own call and is subject to counsel's confirmation (section 2.4). Consent is recorded with the time, the source and the evidence in section 2.4. **[ADD A SCREENSHOT OR PUBLIC URL OF THE OPT IN FORM]** |
| Opt out | STOP, STOPALL, UNSUBSCRIBE, CANCEL, END and QUIT stop all texts from {business} immediately |
| Help | HELP returns the help reply in section 5.4 |
| Embedded links | Yes: private reschedule and waitlist offer links on the business's own domain **[CONFIRM LINK DOMAIN]** |
| Embedded phone numbers | **[YES OR NO]** |
| Age gated or lending content | No |

### 5.3 Sample messages (from the Services' templates)

1. Booking confirmation: "Hi {first_name}, your {appointment} with {business} is booked for {date} at {time}. Reply STOP to opt out."
2. Reminder: "Hi {first_name}, a reminder of your {appointment} with {business} on {date} at {time}.{reschedule_line} Reply STOP to opt out."
3. Missed call: "Hi, this is {business}. Sorry we missed your call. We can help you shortly. How can we assist? Reply STOP to opt out."
4. Lead acknowledgment: "Hi {first_name}, thanks for getting in touch with {business}. We will be in contact shortly. Reply STOP to opt out."
5. Waitlist opening: "Hi {first_name}, good news from {business}: a spot opened up on {date} at {time}.{offer_line} It goes to the first person who takes it. Reply STOP to opt out."
6. Cancellation: "Hi {first_name}, your appointment with {business} has been cancelled. Reply here if you would like to book a new time. Reply STOP to opt out."

### 5.4 Keyword replies

| Keyword | Current behavior | Recommended registration text |
|---|---|---|
| STOP (and STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT) | Opt out is recorded immediately for both service and marketing texts. **No confirmation text is sent today.** | "{business}: You are unsubscribed and will receive no further messages. Reply START to resubscribe." **[MISMATCH: ADD A ONE TIME STOP CONFIRMATION BEFORE REGISTRATION, OR CONFIRM WITH COUNSEL AND THE CARRIER THAT IT IS NOT NEEDED]** |
| HELP | Reply: "{business}: for help please contact us directly. Reply STOP to opt out." Sent only when the number matches a known customer. | "{business}: For help, call {business_number} or visit {business_website}. Msg frequency varies. Msg and data rates may apply. Reply STOP to opt out." **[MISMATCH: THE CURRENT HELP REPLY HAS NO CONTACT METHOD AND IS NOT SENT TO UNKNOWN NUMBERS]** |
| START (and UNSTOP, YES) | Restores service texts after an opt out | "{business}: You are resubscribed to messages. Msg frequency varies. Msg and data rates may apply. Reply STOP to opt out, HELP for help." **[CONFIRM WHETHER A START CONFIRMATION IS SENT]** |

### 5.5 Other mismatches to resolve

- One reminder template still says "Reply C to confirm or R to reschedule", but C and R are no longer treated as keywords; customers change a time with the reschedule link. **[REMOVE THE C AND R WORDING OR RESTORE THE KEYWORDS]**
- Contact hours: the rulebook (COM 3) and Messaging Terms 4.2 require the recipient's local time zone when known, otherwise the Business's, with windows of 7 a.m. to 9 p.m. for reminders and 9 a.m. to 7 p.m. for other service and marketing messages. Today the text sender checks only marketing texts, only before 8 a.m. and from 9 p.m., and only in the Business's time zone; follow ups are scheduled in the Business's time zone. **[OWNER: THE SENDER MUST USE THE RECIPIENT'S TIME ZONE PER COM 3 BEFORE MARKETING OR AUTOMATED TEXTS ARE SWITCHED ON]** Registration samples and opt in text must not promise hours the sender does not enforce.

- The cancellation template uses British spelling ("cancelled"), quoted exactly above; the rulebook asks for American English. **[UPDATE THE TEMPLATE SPELLING]**

## 6. Before publishing

This section is for the owner and counsel. Remove it before use.

Placeholders in this document:

<!-- PLACEHOLDERS START -->

- **[LAST UPDATED DATE]**
- **[LINKS TO THE CUSTOMER'S PRIVACY POLICY AND THE MESSAGING TERMS]**
- **[COUNSEL TO CONFIRM THIS MEETS PRIOR EXPRESS WRITTEN CONSENT UNDER THE TCPA, INCLUDING ANY ONE TO ONE CONSENT REQUIREMENT IN FORCE]**
- **[CONFIRM THAT THE PRODUCT STORES THIS EVIDENCE FOR EACH SOURCE BEFORE RELYING ON IT]**
- **[COUNSEL TO CONFIRM WHETHER PLATFORM LEAD FORMS CAN CARRY TCPA CONSENT FOR AI VOICE CALLS]**
- **[COUNSEL TO CONFIRM]**
- **[CONFIRM AGAINST THE RECEPTIONIST'S CURRENT SCRIPT]**
- **[COUNSEL TO SELECT THE RECORDING DISCLOSURE OPTION]**
- **[CUSTOMER LEGAL NAME]**
- **[CUSTOMER EIN]**
- **[CUSTOMER WEBSITE]**
- **[CUSTOMER INDUSTRY VERTICAL]**
- **[COUNSEL TO CONFIRM THE MISSED CALL BASIS BEFORE REGISTRATION; IF NOT CONFIRMED, REMOVE THE MISSED CALL TEXT FROM THIS CAMPAIGN]**
- **[ADD A SCREENSHOT OR PUBLIC URL OF THE OPT IN FORM]**
- **[CONFIRM LINK DOMAIN]**
- **[YES OR NO]**
- **[MISMATCH: ADD A ONE TIME STOP CONFIRMATION BEFORE REGISTRATION, OR CONFIRM WITH COUNSEL AND THE CARRIER THAT IT IS NOT NEEDED]**
- **[MISMATCH: THE CURRENT HELP REPLY HAS NO CONTACT METHOD AND IS NOT SENT TO UNKNOWN NUMBERS]**
- **[CONFIRM WHETHER A START CONFIRMATION IS SENT]**
- **[REMOVE THE C AND R WORDING OR RESTORE THE KEYWORDS]**
- **[OWNER: THE SENDER MUST USE THE RECIPIENT'S TIME ZONE PER COM 3 BEFORE MARKETING OR AUTOMATED TEXTS ARE SWITCHED ON]**
- **[UPDATE THE TEMPLATE SPELLING]**

<!-- PLACEHOLDERS END -->
