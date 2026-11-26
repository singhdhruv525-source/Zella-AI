# Zella Voice Consent and Carrier Registration Pack

> **Draft for legal review. Not legal advice. Have a qualified lawyer review before publishing.**
> Version 0.2 (draft). Wording for consent capture, caller disclosures and texting registration. For Customers and for Zella Voice's registration work. It is not in effect.

Last updated: **[LAST UPDATED DATE]**

## 1. How to use this pack

1.1 This pack gives ready wording for the places where the Services collect consent or make disclosures, and the text needed to register a Customer's brand and campaign for application to person texting (10DLC). Capitalized terms have the meanings given in section 2 of the Zella Voice Terms of Service ("Terms"). The Zella Voice Messaging Terms are the program terms that this pack points to.

1.2 Message templates quoted here are the Services' own templates. Placeholders in curly braces, such as {business} and {first_name}, are filled in by the Services. Bold bracketed placeholders are for the Customer, the owner or counsel to complete.

1.3 Texts to a Customer's End Users start only after the Customer's registration is approved (Terms, section 5.5).

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

The Services keep this evidence for each source:

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

3.2 **Rule:** a Customer may change the greeting, but the AI disclosure cannot be removed; where a custom greeting leaves it out, the disclosure is added in the caller's language.

3.3 **If asked whether it is a person:** the AI Receptionist says it is an AI assistant.

3.4 **Consent for confirmation texts during a call:** "Would you like me to text you a confirmation at this number? Message and data rates may apply, and you can reply STOP at any time."

## 4. Recording disclosure options

Call recording is off by default. If a Customer turns it on, choose one option for that Customer, with counsel's approval:

| Option | Wording | Notes |
|---|---|---|
| A. Notice | "This call is recorded." | Notice only. May not be enough in states that require the consent of all parties |
| B. Notice with implied consent | "This call is recorded. By staying on the line, you agree to the recording." | Counsel to confirm for each state where callers are located |
| C. Notice followed by an active consent question | "This call is recorded." (the required notice, which cannot be removed under Terms Schedule 2, section 4.2, and Terms section 5.3), followed by: "Is that okay with you? If not, I can continue without recording." If the caller says no, the call continues without recording | Strongest; needs a product change so that a "no" turns recording off |

**[COUNSEL TO SELECT THE RECORDING DISCLOSURE OPTION]**

Voicemail prompt: "Please leave your message after the tone. It will be recorded and passed to the team." A voicemail is the caller's own recorded message and is separate from call recording.

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
3. Missed call: "Hi, this is {business}. We missed your call. Reply here and we will get back to you. Reply STOP to opt out."
4. Lead acknowledgment: "Hi {first_name}, thanks for getting in touch with {business}. We will be in contact shortly. Reply STOP to opt out."
5. Waitlist opening: "Hi {first_name}, good news from {business}: a spot opened up on {date} at {time}.{offer_line} It goes to the first person who takes it. Reply STOP to opt out."
6. Cancellation: "Hi {first_name}, your appointment with {business} has been canceled. Reply here if you would like to book a new time. Reply STOP to opt out."

### 5.3A Marketing campaign (only if the Customer runs marketing)

Register a separate marketing campaign, or add marketing to the use case, only if the Customer collects prior express written consent for marketing under section 2.2 and keeps marketing consent separate from service consent. Marketing texts are sent only within the contact hours in section 4.2 of the Zella Voice Messaging Terms, and only once marketing sending is switched on for the Customer.

| Field | Entry |
|---|---|
| Use case | Marketing |
| Description | {business} uses the Zella Voice platform to send occasional marketing texts, such as checking in with past customers who have not been in touch and suggesting a related service after a visit, only to people who separately agreed in writing to receive marketing texts from {business}. Consent is not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply STOP to opt out. |
| Opt in flow | A separate, unticked marketing checkbox on {business}'s website or lead form, with the wording in section 2.2, recorded with the evidence in section 2.4. **[ADD A SCREENSHOT OR PUBLIC URL OF THE MARKETING OPT IN]** |

Sample marketing messages:

1. Reactivation (from the Services' template): "Hi {first_name}, it has been a while since we heard from you. Reply here if {business} can help. Reply STOP to opt out."
2. Related service suggestion: **[SAMPLE TEXT FOR THE RELATED SERVICE SUGGESTION]**
3. Offer: **[SAMPLE OFFER TEXT FROM THE CUSTOMER, IF OFFERS ARE SENT BY TEXT]**

### 5.4 Keyword replies

| Keyword | Reply |
|---|---|
| STOP (and STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT) | "{business}: You are unsubscribed and will receive no further messages. Reply START to resubscribe." The opt out applies to service and marketing texts and takes effect immediately |
| HELP | "{business}: For help, call {business_number} or visit {business_website}. Msg frequency varies. Msg and data rates may apply. Reply STOP to opt out." Sent to every number that texts HELP |
| START (and UNSTOP, YES) | "{business}: You will receive service messages again, such as appointment reminders. You remain unsubscribed from marketing messages. Msg frequency varies. Msg and data rates may apply. Reply STOP to opt out, HELP for help." Restores service texts only |

## 6. Before publishing

This section is for the owner and counsel. Remove it before use. Do not publish this document until every launch blocker in section 4 of the counsel memo that concerns it has been cleared.

Placeholders in this document:

<!-- PLACEHOLDERS START -->

- **[LAST UPDATED DATE]**
- **[LINKS TO THE CUSTOMER'S PRIVACY POLICY AND THE MESSAGING TERMS]**
- **[COUNSEL TO CONFIRM THIS MEETS PRIOR EXPRESS WRITTEN CONSENT UNDER THE TCPA, INCLUDING ANY ONE TO ONE CONSENT REQUIREMENT IN FORCE]**
- **[COUNSEL TO CONFIRM WHETHER PLATFORM LEAD FORMS CAN CARRY TCPA CONSENT FOR AI VOICE CALLS]**
- **[COUNSEL TO CONFIRM]**
- **[COUNSEL TO SELECT THE RECORDING DISCLOSURE OPTION]**
- **[CUSTOMER LEGAL NAME]**
- **[CUSTOMER EIN]**
- **[CUSTOMER WEBSITE]**
- **[CUSTOMER INDUSTRY VERTICAL]**
- **[COUNSEL TO CONFIRM THE MISSED CALL BASIS BEFORE REGISTRATION; IF NOT CONFIRMED, REMOVE THE MISSED CALL TEXT FROM THIS CAMPAIGN]**
- **[ADD A SCREENSHOT OR PUBLIC URL OF THE OPT IN FORM]**
- **[CONFIRM LINK DOMAIN]**
- **[YES OR NO]**
- **[ADD A SCREENSHOT OR PUBLIC URL OF THE MARKETING OPT IN]**
- **[SAMPLE TEXT FOR THE RELATED SERVICE SUGGESTION]**
- **[SAMPLE OFFER TEXT FROM THE CUSTOMER, IF OFFERS ARE SENT BY TEXT]**

<!-- PLACEHOLDERS END -->
