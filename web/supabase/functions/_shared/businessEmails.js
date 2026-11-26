// Every email Zella Voice sends to a business (its owner, billing contacts and team), in one place: the catalogue,
// the wording and one shared layout. Plain JavaScript with no browser or React parts, so the admin preview and the
// server sender render exactly the same email.
//
// Writing rules (docs/DESIGN_SYSTEM.md): creative but professional, plain words, the facts first, no dashes or
// hyphens, no emoji, no customer (caller) data, card numbers only as the last 4 digits.
// Billing emails follow docs/BILLING_EMAILS.md (codes A1 to I2); the other groups are listed in docs/BUSINESS_EMAILS.md.
// Nothing here sends anything: sending goes through the platform outbox (sql/zella_platform_emails.sql).

// Colours copied from web/src/styles/tokens.css (email clients can't read CSS variables). tests/businessEmails.test.mjs
// checks they still match the tokens.
export const EMAIL_COLORS = {
  bg: "#F7F4EF", card: "#FFFFFF", subtle: "#F3EEE7", primary: "#70452F", primarySoft: "#F1E7DE", text: "#252321",
  text2: "#4A4540", faint: "#6C6660", border: "#E9E2D9", success: "#1F7A45", successBg: "#DDF4E5", info: "#2F5F96",
  infoBg: "#E3EEFA", warning: "#8A5A00", warningBg: "#FFF0D5", danger: "#B3362B", dangerBg: "#FCE6E3",
};
const TONES = { good: ["success", "successBg"], info: ["info", "infoBg"], brand: ["primary", "primarySoft"], heads: ["warning", "warningBg"], urgent: ["danger", "dangerBg"] };

export const GROUPS = [
  ["notices", "Notifications"], ["setup", "Account and setup"], ["security", "Sign in and access"], ["summaries", "Summaries"], ["alerts", "Alerts"],
  ["usage", "Texts and emails used"], ["service", "Service and privacy"],
  ["billing_a", "Billing: sign up and trial"], ["billing_b", "Billing: before each renewal"], ["billing_c", "Billing: invoices and payments"],
  ["billing_d", "Billing: failed payments"], ["billing_e", "Billing: plan changes and cancelling"], ["billing_f", "Billing: minutes, packs and auto reload"],
  ["billing_g", "Billing: refunds, credits and disputes"], ["billing_h", "Billing: settings changed"], ["billing_i", "Billing: statements"],
];

// Sample values for the preview. Made up: no real business, person or card.
export const SAMPLE = {
  appUrl: "https://app.example.com", supportEmail: "support@example.com",
  business: "Maple Street Dental", owner: "Jordan", person: "Sam Lee", role: "owner", industryPeople: "patients",
  plan: "Pro", period: "1 Nov to 30 Nov 2026", amount: "$149.00", total: "$163.40", setupFee: "$599.00", card: "4242",
  date: "1 Dec 2026", dueDate: "4 Dec 2026", renewDate: "1 Dec 2026", trialEnd: "19 Nov 2026", pauseDate: "6 Dec 2026",
  invoice: "ZV 2026 0142", minutesUsed: 800, minutesIncluded: 1000, daysLeft: 9, rate: "$0.35", limit: "$300.00", limitLeft: "$211.00",
  packMinutes: 250, packPrice: "$89.00", texts: "1,000", emails: "10,000", reason: "Your bank declined the payment.",
  attempt: 2, oldValue: "$200.00", newValue: "$300.00", changedBy: "Jordan", device: "Chrome on Windows, near Austin, Texas", time: "14 Nov 2026 at 09:12",
  phone: "(555) 010 2040", fallbackPhone: "(555) 010 3000", calls: 87, booked: 23, newLeads: 12, missed: 3, answeredRate: "97%",
  incident: "Some calls took longer to connect", started: "14 Nov 2026 at 10:05", resolved: "14 Nov 2026 at 10:40", refund: "$49.00", credit: "$12.60",
  deletionDate: "21 Dec 2026", dataDays: 30, linkExpires: "4 Dec 2026", ownerInvited: false, linkPath: "/app/settings/messages/business-email#mailbox_link=sample", questions: 4, onCallFrom: "Saturday 18:00",
  title: "Gaps in this weekend's on call cover", body: "Nobody is on call from Saturday 18:00. Calls that need a person will go to voicemail then.",
  severity: "warning", pagePath: "/on-call",
  newRole: "Manager", busiestDay: "Tuesday", connection: "Website forms", spamCalls: 14, spamMessages: 6,
  maintenanceDay: "21 Nov", maintenanceWindow: "02:00 and 02:30", termsDate: "15 Dec 2026", answerBy: "14 Dec 2026",
  priceDate: "1 Jan 2027", newTotal: "$150.80", retryDate: "3 Dec", proratedToday: "$42.10", newPlan: "Base", newPlanMinutes: 500,
  newInterval: "Yearly", intervalAmount: "$1,490.00", unusedCredit: "$74.50", nextRenewal: "1 Dec 2027",
  paygMinutes: 41, paygAmount: "$14.35", packLeft: 120, rolledOver: 120, correctedCalls: 3, year: 2026, month: "November",
  invoiced: "$163.40", paid: "$163.40", credits: "$0.00", balance: "$0.00",
  // two way events: which way it went
  mfaOn: true, billingAccessGranted: true, autoPayOn: false, accountPaused: true, disputeWon: true,
  lines: [["Pro plan, 1 Nov to 30 Nov", "$149.00"], ["Pay as you go minutes (41 at $0.35)", "$14.35"], ["Credit for corrected calls", "$0.00"], ["Tax", "$0.05"]],
};

const M = true, O = false;
const e = (code, group, name, when, mandatory, build) => ({ code, group, name, when, mandatory, build });
const L = (d, path) => `${d.appUrl}${path}`;

export const EMAILS = [
  // ---- notifications: the bell's own words, emailed (daily summary, weekly review, warnings and urgent alerts).
  // Sent by platform-emails for the notifications a person gets by email (zella_claim_notification_emails).
  e("N1", "notices", "Notification", "a notification someone gets by email (summaries, warnings, urgent alerts)", O, (d) => ({
    tone: d.severity === "urgent" ? "urgent" : d.severity === "warning" ? "heads" : "info",
    subject: d.title, heading: d.title, intro: d.body ? [d.body] : [],
    button: /^https:\/\//.test(String(d.appUrl ?? "")) ? ["Open Zella Voice", L(d, d.pagePath || "/")] : null })),

  // ---- account and setup
  e("S1", "setup", "Welcome to Zella Voice", "the business account is created", M, (d) => ({
    tone: "brand", subject: `Welcome to Zella Voice, ${d.business}`, heading: `Welcome aboard, ${d.owner}`,
    intro: [`Your Zella Voice account for ${d.business} is ready. Set your password to sign in, then we will finish setting up your AI receptionist together.`],
    button: ["Set your password", L(d, "/welcome")] })),
  e("S2", "setup", "Team invitation", "someone is invited to join a business", M, (d) => ({
    tone: "brand", subject: `${d.owner} invited you to ${d.business} on Zella Voice`, heading: "You're invited",
    intro: [`${d.owner} added you to ${d.business} on Zella Voice, where calls, bookings and messages come together.`, "This invitation works for 7 days and only for this email address."],
    button: ["Accept the invitation", L(d, "/invite")] })),
  e("S3", "setup", "Finish setting up", "setup is unfinished 3 days after the account was created", O, (d) => ({
    tone: "info", subject: "A few steps left before your AI receptionist goes live", heading: "You're nearly there",
    intro: ["A few setup steps are still open. Most take less than five minutes, and you can pick up exactly where you left off."],
    facts: [["Still to do", "Opening hours, services, call forwarding"]], button: ["Continue setup", L(d, "/setup")] })),
  e("S4", "setup", "Documents needed", "verification documents are missing or were not accepted", M, (d) => ({
    tone: "heads", subject: "We need one more document to verify your business", heading: "One more document, please",
    intro: [`To verify ${d.business}, we still need a document that shows the business name and address, such as a utility bill or a business licence.`, "Documents are stored privately and seen only by our verification team."],
    button: ["Upload the document", L(d, "/settings/business")] })),
  e("S5", "setup", "Business verified", "verification is approved", M, (d) => ({
    tone: "good", subject: `${d.business} is verified`, heading: "You're verified",
    intro: ["Thanks for your patience. Your business is verified, so phone numbers and texting can be switched on."], button: ["Open Zella Voice", L(d, "/")] })),
  e("S6", "setup", "Your AI receptionist is live", "the receptionist starts answering real calls", M, (d) => ({
    tone: "good", subject: "Your AI receptionist is now answering calls", heading: "You're live",
    intro: [`From now on, calls to ${d.phone} are answered by your AI receptionist, day and night.`, "Calls that need a person go to your team, just as you set them up."],
    facts: [["Your number", d.phone], ["If something goes wrong, calls go to", d.fallbackPhone]], button: ["See today's calls", L(d, "/calls")] })),
  e("S7", "setup", "Phone number connected", "a phone number is connected or moved", M, (d) => ({
    tone: "info", subject: `${d.phone} is connected`, heading: "Your number is connected",
    intro: [`${d.phone} now rings through to Zella Voice. Make a test call to hear your receptionist.`], button: ["Phone settings", L(d, "/settings/phone")] })),
  // A Zella Voice admin sends the owner a one time link during Create Business (owner, 27 Nov 2026; ARCHITECTURE §14.4).
  // Sent by the business-email function (action mailbox_link_send). linkPath carries the one time token (in the address
  // fragment); the link works once, for 7 days, only for the owner signed in to Zella Voice.
  e("S8", "setup", "Connect your mailbox", "a Zella Voice admin sends the owner a link to connect Gmail or Outlook", M, (d) => ({
    tone: "brand", subject: `Send ${d.business}'s customer emails from your own address`, heading: "Connect your mailbox",
    intro: ["Reminders and confirmations to your customers can come from your own Gmail or Outlook address.",
      d.ownerInvited ? "First accept your invitation to Zella Voice, which came in its own email. Then open this link, sign in, and choose Gmail or Outlook. You sign in with Google or Microsoft on their own page and allow sending."
        : "Open this link and sign in to Zella Voice, then choose Gmail or Outlook. You sign in with Google or Microsoft on their own page and allow sending.",
      "Zella Voice never sees your password and never reads your mailbox. It only sends your reminders, confirmations and other emails to your customers."],
    facts: [["Link works until", d.linkExpires], ["Works for", "You only, once"]],
    outro: ["If you'd rather not, there is nothing to do. Customer emails keep coming from Zella Voice's address with your business name, and you can connect your mailbox later in Settings."],
    button: ["Connect your mailbox", L(d, d.linkPath)] })),

  // ---- sign in and access
  e("K1", "security", "New sign in", "someone signs in from a new device", M, (d) => ({
    tone: "info", subject: "New sign in to your Zella Voice account", heading: "Was this you?",
    intro: ["Your account was just used to sign in on a device we haven't seen before."], facts: [["When", d.time], ["Device", d.device]],
    outro: ["If this was you, there is nothing to do. If not, change your password now and tell your account owner."], button: ["Review your security", L(d, "/settings/security")] })),
  e("K2", "security", "Two step sign in changed", "two step sign in is turned on or off", M, (d) => ({
    tone: d.mfaOn ? "info" : "heads", subject: d.mfaOn ? "Two step sign in was turned on" : "Two step sign in was turned off", heading: "Your sign in settings changed",
    intro: [d.mfaOn ? "Two step sign in was turned on for your account." : "Two step sign in was turned off for your account. If you didn't expect this, turn it back on and tell your account owner."], facts: [["When", d.time], ["Changed by", d.changedBy]], button: ["Review your security", L(d, "/settings/security")] })),
  e("K3", "security", "Password changed", "the password is changed or reset", M, (d) => ({
    tone: "info", subject: "Your Zella Voice password was changed", heading: "Password changed",
    intro: ["Your password was just changed. If you didn't do this, reset it now and contact us."], facts: [["When", d.time]], button: ["Reset your password", L(d, "/reset")] })),
  e("K4", "security", "Your access changed", "a person's role in the business changes or is removed", M, (d) => ({
    tone: "info", subject: `Your access to ${d.business} changed`, heading: "Your access changed",
    intro: [`${d.changedBy} changed your role in ${d.business}. What you can see and do in Zella Voice now follows the new role.`], facts: [["New role", d.newRole]], button: ["Open Zella Voice", L(d, "/")] })),

  // ---- summaries
  e("R1", "summaries", "Daily summary", "8:00 each morning, when there is something to report", O, (d) => ({
    tone: "info", subject: `Yesterday at ${d.business}: ${d.calls} calls, ${d.booked} booked`, heading: "Here's yesterday at a glance",
    facts: [["Calls answered", `${d.calls} (${d.answeredRate})`], ["Booked by your receptionist", d.booked], ["New leads", d.newLeads], ["Need a call back", d.missed]],
    button: ["Open today", L(d, "/")] })),
  e("R2", "summaries", "Weekly review", "Monday morning", O, (d) => ({
    tone: "brand", subject: `Your week at ${d.business}`, heading: "Your week, wrapped up",
    intro: [`Your receptionist answered ${d.calls} calls and booked ${d.booked} appointments this week. Here is what stood out.`],
    facts: [["Busiest day", d.busiestDay], ["New leads", d.newLeads], ["Questions it couldn't answer", d.questions]], button: ["See the full review", L(d, "/reports")] })),
  e("R3", "summaries", "Monthly report", "the first of each month", O, (d) => ({
    tone: "brand", subject: `${d.business}: your month with Zella Voice`, heading: "Your month in numbers",
    facts: [["Calls answered", d.calls], ["Booked", d.booked], ["Minutes used", `${d.minutesUsed} of ${d.minutesIncluded}`]], button: ["Open reports", L(d, "/reports")] })),

  // ---- alerts
  e("L1", "alerts", "Urgent: a person is needed", "an emergency or urgent call needs someone now", M, (d) => ({
    tone: "urgent", subject: "Urgent: a caller needs a person now", heading: "A caller needs a person now",
    intro: ["Your receptionist marked a call as urgent and could not reach anyone on your team. Please call back as soon as you can."],
    button: ["Open the call", L(d, "/calls")] })),
  e("L2", "alerts", "Callbacks waiting", "callbacks are overdue", O, (d) => ({
    tone: "heads", subject: `${d.missed} callers are still waiting to hear from you`, heading: "Callbacks are waiting",
    intro: [`${d.missed} callers asked for a call back and haven't heard from anyone yet.`], button: ["See callbacks", L(d, "/callbacks")] })),
  e("L3", "alerts", "Calendar disconnected", "the connected calendar stops syncing", M, (d) => ({
    tone: "heads", subject: "Your calendar stopped syncing", heading: "Let's reconnect your calendar",
    intro: ["Your receptionist can't see your calendar right now, so it is offering only times it is sure about. Reconnecting takes a minute."], button: ["Reconnect", L(d, "/settings/calendar")] })),
  e("L4", "alerts", "A connection stopped working", "an integration fails repeatedly", M, (d) => ({
    tone: "heads", subject: "A connection to Zella Voice stopped working", heading: "A connection needs you",
    intro: ["One of your connected apps stopped answering. Nothing is lost; new items will catch up once it is reconnected."], facts: [["Connection", d.connection]], button: ["Open integrations", L(d, "/settings/integrations")] })),
  e("L5", "alerts", "Google reviews disconnected", "review syncing stops", O, (d) => ({
    tone: "heads", subject: "Google reviews stopped syncing", heading: "Reconnect your reviews",
    intro: ["New Google reviews aren't coming into Zella Voice. Reconnect to keep seeing them and drafting replies."], button: ["Reconnect", L(d, "/reviews")] })),
  e("L6", "alerts", "Weekend on call cover", "Thursday or Friday, when part of the weekend has nobody on call", O, (d) => ({
    tone: "heads", subject: "Gaps in this weekend's on call cover", heading: "Who's on call this weekend?",
    intro: [`Nobody is on call from ${d.onCallFrom}. Calls that need a person will go to voicemail then.`], button: ["Open the rota", L(d, "/on-call")] })),
  e("L7", "alerts", "Weekly spam report", "Monday, when spam was stopped", O, (d) => ({
    tone: "info", subject: "Spam your receptionist stopped this week", heading: "Spam kept out of your day",
    facts: [["Spam calls stopped", d.spamCalls], ["Spam messages stopped", d.spamMessages]], button: ["Spam protection", L(d, "/spam")] })),
  e("L8", "alerts", "Texts not delivered", "several texts to customers fail", O, (d) => ({
    tone: "heads", subject: "Some texts weren't delivered", heading: "Some texts didn't arrive",
    intro: ["A few texts to your customers were not delivered. Usually the number is wrong or can't receive texts."], button: ["See which ones", L(d, "/messages")] })),
  e("L9", "alerts", "Questions your receptionist couldn't answer", "weekly, when callers asked something it didn't know", O, (d) => ({
    tone: "info", subject: `${d.questions} questions your receptionist couldn't answer`, heading: "Teach your receptionist something new",
    intro: [`Callers asked ${d.questions} questions this week that your receptionist didn't have an answer for. Add the answers and it will know next time.`], button: ["Add answers", L(d, "/knowledge")] })),

  // ---- texts and emails used
  e("U1", "usage", "80% of texts used", "texts reach 80% of the plan", O, (d) => ({
    tone: "heads", subject: "You've used 80% of this month's texts", heading: "Your texts are running low",
    intro: ["Appointment reminders always go out from your reserve. Optional texts pause at 100% until your plan renews or you add a pack."], facts: [["Renews", d.renewDate]], button: ["Add a texts pack", L(d, "/settings/billing")] })),
  e("U2", "usage", "Texts used up", "texts reach 100% of the plan", M, (d) => ({
    tone: "heads", subject: "This month's texts are used up", heading: "Optional texts are paused",
    intro: ["Appointment confirmations and reminders still go out from your reserve. Offers and follow ups wait until your plan renews or you add a pack."], facts: [["Renews", d.renewDate]], button: ["Add a texts pack", L(d, "/settings/billing")] })),
  e("U3", "usage", "80% of emails used", "emails reach 80% of the plan", O, (d) => ({
    tone: "heads", subject: "You've used 80% of this month's emails", heading: "Your emails are running low",
    intro: ["Booking emails always go out. Optional emails pause at 100% until your plan renews or you add a pack."], facts: [["Renews", d.renewDate]], button: ["Add an emails pack", L(d, "/settings/billing")] })),
  e("U4", "usage", "Emails used up", "emails reach 100% of the plan", M, (d) => ({
    tone: "heads", subject: "This month's emails are used up", heading: "Optional emails are paused",
    intro: ["Booking confirmations and reminders still go out. Newsletters and offers wait until your plan renews or you add a pack."], facts: [["Renews", d.renewDate]], button: ["Add an emails pack", L(d, "/settings/billing")] })),

  // ---- service and privacy
  e("V1", "service", "Service incident", "a problem affects calls or messages", M, (d) => ({
    tone: "heads", subject: `We're working on it: ${d.incident.toLowerCase()}`, heading: "We're on it",
    intro: [`${d.incident} since ${d.started}. Our team is working on it and calls are still being answered.`], button: ["Status page", L(d, "/status")] })),
  e("V2", "service", "Incident resolved", "the incident is fixed", M, (d) => ({
    tone: "good", subject: "Resolved: everything is running normally", heading: "All fixed",
    intro: [`The problem is fixed (${d.resolved}). Thank you for your patience.`] })),
  e("V3", "service", "Scheduled maintenance", "7 days before planned maintenance", M, (d) => ({
    tone: "info", subject: `Planned maintenance on ${d.maintenanceDay}`, heading: "A short planned update",
    intro: [`On ${d.maintenanceDay} between ${d.maintenanceWindow} your time, the CRM may be slow. Your receptionist keeps answering calls throughout.`] })),
  e("V4", "service", "Terms updated", "30 days before the terms or privacy policy change", M, (d) => ({
    tone: "info", subject: "We're updating our terms", heading: "Our terms are changing",
    intro: [`Our terms of service change on ${d.termsDate}. Here is what is different, in plain words.`], button: ["Read the changes", L(d, "/legal")] })),
  e("V5", "service", "Privacy request received", "a customer asks to see or delete their data", M, (d) => ({
    tone: "heads", subject: "A privacy request needs an answer", heading: "A privacy request came in",
    intro: ["Someone asked to see or delete the information you hold about them. The law gives you a deadline to answer, and Zella Voice tracks it for you."], facts: [["Answer by", d.answerBy]], button: ["Open the request", L(d, "/settings/privacy")] })),
  e("V6", "service", "Data export ready", "an export the owner asked for is ready", M, (d) => ({
    tone: "good", subject: "Your data export is ready", heading: "Your export is ready",
    intro: ["The export you asked for is ready to download. The link works for 7 days."], button: ["Download", L(d, "/settings/data")] })),

  // ---- billing (docs/BILLING_EMAILS.md)
  e("A1", "billing_a", "Welcome, payment received", "the first invoice is paid", M, (d) => ({
    tone: "good", subject: `Welcome to Zella Voice: payment of ${d.amount} received`, heading: "Payment received. Welcome aboard",
    intro: ["Thank you. Your plan is active and your receipt is attached."], facts: [["Plan", d.plan], ["Amount", d.amount], ["Period", d.period]], button: ["View receipt", L(d, "/settings/billing")] })),
  e("A2", "billing_a", "Trial started", "a card is saved and the trial begins", M, (d) => ({
    tone: "brand", subject: "Your 5 day trial has started", heading: "Your trial has started",
    intro: [`Nothing is charged today. Unless you cancel, we will charge card ending ${d.card} ${d.amount} on ${d.trialEnd}.`], facts: [["Trial ends", d.trialEnd], ["First charge", d.amount]], button: ["Billing settings", L(d, "/settings/billing")] })),
  e("A3", "billing_a", "Trial ending soon", "3 days before the trial ends", M, (d) => ({
    tone: "info", subject: `Your trial ends on ${d.trialEnd}`, heading: "Your trial ends soon",
    intro: [`On ${d.trialEnd} we will charge card ending ${d.card} ${d.amount} and your plan continues. Nothing to do.`], button: ["Billing settings", L(d, "/settings/billing")] })),
  e("A4", "billing_a", "Trial converted, paid", "the first charge after the trial succeeds", M, (d) => ({
    tone: "good", subject: `Payment received: ${d.amount}`, heading: "Your plan is active",
    intro: ["Your trial is over and your first payment went through. Thank you."], facts: [["Amount", d.amount], ["Card", `ending ${d.card}`]], button: ["View receipt", L(d, "/settings/billing")] })),
  e("A5", "billing_a", "Trial ended without payment", "the trial ends with no working card", M, (d) => ({
    tone: "urgent", subject: "Your trial ended: add a card to continue", heading: "Your receptionist is paused",
    intro: [`Your trial ended and there is no working card, so calls now go to ${d.fallbackPhone}. Add a card and your receptionist answers again within a minute.`], button: ["Add a card", L(d, "/settings/billing")] })),
  e("A6", "billing_a", "Setup fee charged", "the setup fee is paid", M, (d) => ({
    tone: "good", subject: `Setup fee received: ${d.setupFee}`, heading: "Setup fee received",
    intro: ["This covers building and tuning your AI receptionist with you."], facts: [["Amount", d.setupFee], ["Card", `ending ${d.card}`]], button: ["View receipt", L(d, "/settings/billing")] })),

  e("B1", "billing_b", "Your plan renews soon", "3 days before each renewal (yearly plans also 7 days before)", M, (d) => ({
    tone: "info", subject: `Your plan renews on ${d.renewDate}`, heading: "Your plan renews soon",
    intro: [`On ${d.renewDate} we will charge card ending ${d.card} about ${d.amount} plus any pay as you go minutes. Nothing to do.`], facts: [["Plan", d.plan], ["Estimated amount", d.amount]], button: ["Billing settings", L(d, "/settings/billing")] })),
  e("B2", "billing_b", "Card expiring soon", "30 days before the saved card expires", M, (d) => ({
    tone: "heads", subject: "Your card expires before your next renewal", heading: "Time for a new card",
    intro: [`The card ending ${d.card} expires before your renewal on ${d.renewDate}. Update it so your receptionist keeps answering.`], button: ["Update card", L(d, "/settings/billing")] })),
  e("B3", "billing_b", "No card on file", "automatic payment is on but the card was removed or can't be used", M, (d) => ({
    tone: "heads", subject: "Add a card before your next renewal", heading: "There's no card to charge",
    intro: [`Add a card before ${d.renewDate} so your plan renews without a break.`], button: ["Add a card", L(d, "/settings/billing")] })),
  e("B4", "billing_b", "Price change notice", "30 days before the plan's price changes", M, (d) => ({
    tone: "info", subject: "Your plan's price is changing", heading: "A change to your price",
    intro: [`From your renewal on ${d.priceDate}, your plan's price changes. You can change plan or cancel at any time before then.`], facts: [["Now", d.oldValue], [`From ${d.priceDate}`, d.newValue]], button: ["Billing settings", L(d, "/settings/billing")] })),
  e("B5", "billing_b", "Discount ending", "7 days before a discount ends", M, (d) => ({
    tone: "info", subject: "Your discount ends soon", heading: "Your discount ends soon",
    intro: [`Your discount ends after this period. From ${d.renewDate} your plan renews at ${d.amount}.`], button: ["Billing settings", L(d, "/settings/billing")] })),

  e("C1", "billing_c", "Your invoice", "an invoice is issued", M, (d) => ({
    tone: "info", subject: `Invoice ${d.invoice}: ${d.total}`, heading: "Your invoice is ready",
    intro: [`We will charge card ending ${d.card} on ${d.date}.`], facts: [["Invoice", d.invoice], ["Period", d.period]], lines: d.lines, total: d.total,
    button: ["View invoice", L(d, "/settings/billing")], secondary: [["Download PDF", L(d, "/settings/billing")]] })),
  e("C2", "billing_c", "Receipt", "a pay as you go or pack charge succeeds without a Stripe invoice", M, (d) => ({
    tone: "good", subject: `Receipt: ${d.packPrice}`, heading: "Here's your receipt",
    facts: [["For", `${d.packMinutes} minutes pack`], ["Amount", d.packPrice], ["Card", `ending ${d.card}`], ["Date", d.date]], button: ["View receipt", L(d, "/settings/billing")] })),
  e("C3", "billing_c", "Paid", "every successful payment", M, (d) => ({
    tone: "good", subject: `Payment received: ${d.total}`, heading: "Thank you, payment received",
    facts: [["Invoice", d.invoice], ["Amount", d.total], ["Card", `ending ${d.card}`], ["Date", d.date]], button: ["Download receipt", L(d, "/settings/billing")] })),
  e("C4", "billing_c", "Invoice cancelled", "an invoice already emailed is cancelled", M, (d) => ({
    tone: "info", subject: `Invoice ${d.invoice} was cancelled`, heading: "No need to pay this invoice",
    intro: [`Invoice ${d.invoice} was cancelled, so it no longer needs paying.`], button: ["Billing history", L(d, "/settings/billing")] })),
  e("C5", "billing_c", "Invoice due tomorrow", "1 day before the due date, if unpaid and automatic payment is off", M, (d) => ({
    tone: "heads", subject: `Invoice ${d.invoice} is due tomorrow`, heading: "Your invoice is due tomorrow",
    facts: [["Amount", d.total], ["Due", d.dueDate]], button: ["Pay now", L(d, "/pay")], note: "Or pay in the app, under Settings, Billing." })),
  e("C6", "billing_c", "Replacement invoice", "usage is billed again after an invoice was cancelled", M, (d) => ({
    tone: "info", subject: `Replacement invoice ${d.invoice}`, heading: "A corrected invoice",
    intro: ["This invoice replaces one we cancelled. The only change is the corrected pay as you go minutes."], lines: d.lines, total: d.total, button: ["View invoice", L(d, "/settings/billing")] })),
  e("C7", "billing_c", "Credit note", "an issued invoice is reduced", M, (d) => ({
    tone: "good", subject: `Credit note for invoice ${d.invoice}`, heading: "Your invoice was reduced",
    facts: [["Invoice", d.invoice], ["Reduced by", d.credit], ["New total", d.newTotal]], button: ["Download PDF", L(d, "/settings/billing")] })),

  e("D1", "billing_d", "Payment failed", "the first charge fails, or the due date passes unpaid", M, (d) => ({
    tone: "urgent", subject: `Payment of ${d.total} didn't go through`, heading: "Your payment didn't go through",
    intro: [`${d.reason} We will try again on ${d.retryDate}. Pay now or update your card to keep your receptionist answering.`], facts: [["Amount", d.total], ["Card", `ending ${d.card}`]],
    button: ["Pay now", L(d, "/pay")], secondary: [["Update card", L(d, "/settings/billing")]] })),
  e("D2", "billing_d", "Confirm your payment", "the bank asks for confirmation (3D Secure)", M, (d) => ({
    tone: "heads", subject: "Your bank needs you to confirm a payment", heading: "Please confirm your payment",
    intro: [`Your bank asked you to confirm the payment of ${d.total}. It takes a moment on Stripe's secure page.`], button: ["Confirm the payment", L(d, "/pay")] })),
  e("D3", "billing_d", "Retry failed", "each failed retry", M, (d) => ({
    tone: "urgent", subject: `Payment attempt ${d.attempt} failed`, heading: "We still couldn't take the payment",
    intro: [`${d.reason} Your receptionist pauses on ${d.pauseDate} unless the invoice is paid.`], button: ["Pay now", L(d, "/pay")], secondary: [["Update card", L(d, "/settings/billing")]] })),
  e("D4", "billing_d", "Final notice", "the day before the pause", M, (d) => ({
    tone: "urgent", subject: "Final notice: your service pauses tomorrow", heading: "Your service pauses tomorrow",
    intro: [`Unless ${d.total} is paid today, calls go to ${d.fallbackPhone} from tomorrow and your receptionist stops answering.`], button: ["Pay now", L(d, "/pay")] })),
  e("D5", "billing_d", "Service paused", "5 days after the failed payment", M, (d) => ({
    tone: "urgent", subject: "Your service is paused: payment overdue", heading: "Your receptionist is paused",
    intro: [`Calls now go to ${d.fallbackPhone}. Pay now and your receptionist answers again within a minute.`], button: ["Pay now", L(d, "/pay")] })),
  e("D6", "billing_d", "Payment recovered", "the overdue invoice is paid", M, (d) => ({
    tone: "good", subject: "Payment received: everything is back on", heading: "Welcome back",
    intro: ["Thank you. Your receptionist is answering calls again."], facts: [["Amount", d.total], ["Card", `ending ${d.card}`]], button: ["Download receipt", L(d, "/settings/billing")] })),
  e("D7", "billing_d", "Payment reversed by the bank", "a payment is reversed outside a dispute", M, (d) => ({
    tone: "heads", subject: "Your bank reversed a payment", heading: "A payment was reversed",
    intro: [`Your bank reversed ${d.refund} of a payment. Please check with your bank, or pay the amount again so your plan stays active.`], button: ["Billing settings", L(d, "/settings/billing")] })),

  e("E1", "billing_e", "Plan upgraded", "an upgrade is applied", M, (d) => ({
    tone: "good", subject: "Your plan is upgraded", heading: "Upgraded and ready",
    facts: [["New plan", d.plan], ["Charged today", `${d.proratedToday} for the rest of this period`], ["Next renewal", `${d.amount} on ${d.renewDate}`]], button: ["Billing settings", L(d, "/settings/billing")] })),
  e("E2", "billing_e", "Downgrade scheduled", "a downgrade is chosen", M, (d) => ({
    tone: "info", subject: `Your plan changes on ${d.renewDate}`, heading: "Your plan change is booked",
    intro: [`Your current plan continues until ${d.renewDate}. After that you move to the ${d.newPlan} plan with ${d.newPlanMinutes} included minutes.`], button: ["Billing settings", L(d, "/settings/billing")] })),
  e("E3", "billing_e", "Cancellation confirmed", "the owner cancels", M, (d) => ({
    tone: "info", subject: "Your cancellation is confirmed", heading: "We're sorry to see you go",
    intro: [`Your receptionist keeps answering until ${d.renewDate}. A final invoice for any pay as you go minutes follows. Changed your mind? You can continue with one click.`], button: ["Keep my plan", L(d, "/settings/billing")] })),
  e("E4", "billing_e", "Cancellation withdrawn", "the owner continues before the end", M, (d) => ({
    tone: "good", subject: "Glad you're staying", heading: "Your plan continues",
    facts: [["Next renewal", `${d.amount} on ${d.renewDate}`]] })),
  e("E5", "billing_e", "Subscription ended", "the period ends after a cancellation", M, (d) => ({
    tone: "info", subject: "Your Zella Voice plan has ended", heading: "Your plan has ended",
    intro: [`Your receptionist no longer answers calls. Your data is kept for ${d.dataDays} days in case you come back, and the final invoice follows.`], button: ["Reactivate", L(d, "/settings/billing")] })),
  e("E6", "billing_e", "Billing period changed", "the plan switches between monthly and yearly", M, (d) => ({
    tone: "info", subject: `You're now billed ${d.newInterval.toLowerCase()}`, heading: "Your billing period changed",
    facts: [["New period", d.newInterval], ["Amount", d.intervalAmount], ["Credit for unused time", d.unusedCredit], ["Next renewal", d.nextRenewal]] })),
  e("E7", "billing_e", "Plan reactivated", "an ended business subscribes again", M, (d) => ({
    tone: "good", subject: "Welcome back to Zella Voice", heading: "Welcome back",
    facts: [["Plan", d.plan], ["Amount", d.amount], ["Next renewal", d.renewDate]], button: ["Open Zella Voice", L(d, "/")] })),
  e("E8", "billing_e", "Data deletion warning", "7 days before an ended business's data is deleted", M, (d) => ({
    tone: "urgent", subject: `Your data will be deleted on ${d.deletionDate}`, heading: "Your data will be deleted soon",
    intro: [`On ${d.deletionDate} we permanently delete ${d.business}'s calls, customers and settings. Export them or reactivate before then.`], button: ["Export or reactivate", L(d, "/settings/data")] })),
  e("E9", "billing_e", "Account paused or restored", "an admin pauses or restores the account for billing reasons", M, (d) => ({
    tone: d.accountPaused ? "heads" : "good", subject: d.accountPaused ? "Your account was paused" : "Your account is restored",
    heading: d.accountPaused ? "Your account is paused" : "Welcome back",
    intro: [d.accountPaused ? `Your account was paused because an invoice is unpaid. Calls go to ${d.fallbackPhone} until it is settled.` : "Your account is active again and your receptionist is answering calls."],
    button: d.accountPaused ? ["Pay now", L(d, "/pay")] : ["Open Zella Voice", L(d, "/")] })),

  e("F1", "billing_f", "80% of minutes used", "minutes reach 80% of the plan", O, (d) => ({
    tone: "heads", subject: "You've used 80% of this month's minutes", heading: "Your receptionist has been busy",
    intro: [`${d.minutesUsed} of ${d.minutesIncluded} minutes are used with ${d.daysLeft} days to go. Every call is still answered.`],
    facts: [["Options", "A minutes pack, auto reload or an upgrade"]], button: ["Add minutes", L(d, "/settings/billing")] })),
  e("F2", "billing_f", "Minutes used up", "minutes reach 100% of the plan", M, (d) => ({
    tone: "heads", subject: "This month's minutes are used up", heading: "Every call is still being answered",
    intro: [`New minutes are charged at ${d.rate} a minute, up to your monthly limit of ${d.limit}. Calls in progress are never cut off.`], button: ["Add minutes", L(d, "/settings/billing")] })),
  e("F3", "billing_f", "Pack purchased", "a pack is paid", M, (d) => ({
    tone: "good", subject: `${d.packMinutes} minutes added`, heading: "Minutes added",
    facts: [["Pack", `${d.packMinutes} minutes`], ["Amount", d.packPrice], ["Card", `ending ${d.card}`]], button: ["View receipt", L(d, "/settings/billing")] })),
  e("F4", "billing_f", "Auto reload charged", "auto reload succeeds", M, (d) => ({
    tone: "good", subject: `Topped up: ${d.packMinutes} minutes added`, heading: "Topped up automatically",
    intro: [`Every caller got an answer. ${d.packPrice} charged; ${d.limitLeft} left of your ${d.limit} monthly limit.`], button: ["View receipt", L(d, "/settings/billing")] })),
  e("F5", "billing_f", "Auto reload failed", "the auto reload charge fails", M, (d) => ({
    tone: "urgent", subject: "Auto reload didn't go through", heading: "We couldn't top up your minutes",
    intro: [`${d.reason} Once your minutes run out, new calls go to ${d.fallbackPhone}.`], button: ["Update card", L(d, "/settings/billing")] })),
  e("F6", "billing_f", "Spending limit reached", "the monthly limit stops new pay as you go minutes", M, (d) => ({
    tone: "heads", subject: "Your monthly spending limit is reached", heading: "Your spending limit is reached",
    intro: [`You've reached your ${d.limit} monthly limit, so new calls go to ${d.fallbackPhone} until your plan renews. You can raise the limit at any time.`], button: ["Raise the limit", L(d, "/settings/billing")] })),
  e("F7", "billing_f", "Pay as you go statement", "at each period's close, if pay as you go minutes were used", O, (d) => ({
    tone: "info", subject: "Your pay as you go minutes this month", heading: "Pay as you go, this month",
    facts: [["Minutes", d.paygMinutes], ["Rate", d.rate], ["Amount", d.paygAmount], ["On invoice", d.invoice]] })),
  e("F8", "billing_f", "Pack expiring", "7 days before unused pack minutes expire", O, (d) => ({
    tone: "info", subject: "Pack minutes expire soon", heading: "Use them before they go",
    facts: [["Minutes left", d.packLeft], ["Expire", d.renewDate]] })),
  e("F9", "billing_f", "Allowance renewed", "at each renewal", O, (d) => ({
    tone: "good", subject: "Fresh minutes, texts and emails", heading: "Your allowance is renewed",
    facts: [["Minutes", `${d.minutesIncluded} plus ${d.rolledOver} rolled over`], ["Texts", d.texts], ["Emails", d.emails]] })),

  e("G1", "billing_g", "Refund requested", "the owner asks for a refund", M, (d) => ({
    tone: "info", subject: "We received your refund request", heading: "Refund request received",
    intro: [`You asked for a refund of ${d.refund}. We will reply within 2 business days.`] })),
  e("G2", "billing_g", "Refund issued", "the refund succeeds", M, (d) => ({
    tone: "good", subject: `Refund of ${d.refund} issued`, heading: "Your refund is on its way",
    intro: [`${d.refund} was refunded to the card ending ${d.card}. It usually appears in 5 to 10 business days.`] })),
  e("G3", "billing_g", "Refund declined", "an admin declines the refund", M, (d) => ({
    tone: "info", subject: "About your refund request", heading: "About your refund request",
    intro: ["We weren't able to approve this refund because the minutes were used for answered calls. Reply to this email if you'd like to talk it through."] })),
  e("G4", "billing_g", "Credit applied", "a correction credit is used on an invoice", O, (d) => ({
    tone: "good", subject: `${d.credit} credit applied`, heading: "We corrected some calls",
    intro: [`We found ${d.correctedCalls} calls that were counted too long, and took ${d.credit} off invoice ${d.invoice}.`] })),
  e("G5", "billing_g", "Dispute opened", "the bank opens a chargeback", M, (d) => ({
    tone: "heads", subject: "Your bank opened a dispute", heading: "A payment is being disputed",
    intro: [`Your bank opened a dispute for ${d.total}. Your service continues while it is reviewed. If this was a mistake, tell your bank and reply to us.`] })),
  e("G6", "billing_g", "Dispute closed", "the dispute is won or lost", M, (d) => ({
    tone: "info", subject: "Your payment dispute is closed", heading: "The dispute is closed",
    intro: [d.disputeWon ? "The bank closed the dispute in our favour, so the original payment stands. Nothing else changes on your account."
      : `The bank closed the dispute in your favour and returned ${d.total} to you. The invoice is unpaid again; please pay it so your plan stays active.`],
    button: d.disputeWon ? null : ["Pay now", L(d, "/pay")] })),
  e("G7", "billing_g", "Usage waived", "an admin waives usage after a cancelled invoice", M, (d) => ({
    tone: "good", subject: "Nothing to pay for these minutes", heading: "We've waived these minutes",
    intro: [`We've waived ${d.paygMinutes} pay as you go minutes (${d.paygAmount}). There is nothing to pay.`] })),
  e("G8", "billing_g", "Refund partly issued", "only part of a refund is approved", M, (d) => ({
    tone: "info", subject: `Refund of ${d.refund} issued`, heading: "Part of your refund is approved",
    intro: [`We refunded ${d.refund} to the card ending ${d.card}. The rest covered calls that were answered.`] })),

  e("H1", "billing_h", "Automatic payment changed", "automatic payment is switched on or off", M, (d) => ({
    tone: "info", subject: d.autoPayOn ? "Automatic payment was switched on" : "Automatic payment was switched off", heading: d.autoPayOn ? "Automatic payment is on" : "Automatic payment is off",
    intro: [d.autoPayOn ? `From your next renewal, we will charge the card ending ${d.card} automatically.` : `From your next renewal, we will email the invoice and you pay it by ${d.dueDate}.`], facts: [["Changed by", d.changedBy], ["When", d.time]] })),
  e("H2", "billing_h", "Card updated", "the saved card is added, replaced or removed", M, (d) => ({
    tone: "info", subject: "Your card was updated", heading: "Card updated",
    facts: [["New card", `ending ${d.card}`], ["Changed by", d.changedBy], ["When", d.time]] })),
  e("H3", "billing_h", "Billing email changed", "the billing email or copy list changes (sent to the old and new address)", M, (d) => ({
    tone: "info", subject: "Your billing email was changed", heading: "Billing email changed",
    intro: ["Invoices and receipts now go to the new address. If you didn't expect this, contact us right away."], facts: [["Changed by", d.changedBy], ["When", d.time]] })),
  e("H4", "billing_h", "Spending limit or auto reload changed", "the limit or auto reload settings change", M, (d) => ({
    tone: "info", subject: "Your spending limit was changed", heading: "Spending limit changed",
    facts: [["Was", d.oldValue], ["Now", d.newValue], ["Changed by", d.changedBy]] })),
  e("H5", "billing_h", "Billing details changed", "the name, address or tax ID on invoices changes", M, (d) => ({
    tone: "info", subject: "Your billing details were changed", heading: "Billing details changed",
    intro: ["Your next invoice will use the new details."], facts: [["Changed by", d.changedBy], ["When", d.time]] })),
  e("H6", "billing_h", "Billing access changed", "someone gains or loses billing access", M, (d) => ({
    tone: "info", subject: "Billing access was changed", heading: "Billing access changed",
    intro: [d.billingAccessGranted ? `${d.person} can now see and manage billing for ${d.business}.` : `${d.person} can no longer see or manage billing for ${d.business}.`], facts: [["Changed by", d.changedBy]] })),

  e("I1", "billing_i", "Yearly billing summary", "each January", O, (d) => ({
    tone: "info", subject: `Your ${d.year} billing summary`, heading: "Your year in invoices",
    intro: ["Every invoice and refund from last year in one PDF, ready for your accountant."], button: ["Download the summary", L(d, "/settings/billing")] })),
  e("I2", "billing_i", "Monthly statement", "the first of each month", O, (d) => ({
    tone: "info", subject: `Your ${d.month} statement`, heading: `Your statement for ${d.month}`,
    facts: [["Invoiced", d.invoiced], ["Paid", d.paid], ["Credits", d.credits], ["Balance", d.balance]] })),
];

export const emailByCode = (code) => EMAILS.find((x) => x.code === code);

const esc = (v) => String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const safeUrl = (u) => (/^https:\/\//.test(String(u)) ? String(u) : "#");

// One email, rendered: subject, preheader, HTML (tables and inline styles for email clients) and a plain text copy.
// The preview fills gaps with SAMPLE values. The sender passes { strict: true }: then a fact the email needs and the
// data doesn't have stops the email (MISSING_FIELD) instead of sending a made up value.
export function renderEmail(code, data = SAMPLE, { strict = false } = {}) {
  const def = emailByCode(code);
  if (!def) throw new Error(`UNKNOWN_EMAIL:${code}`);
  const OPTIONAL = new Set(["supportEmail", "appUrl", "pagePath", "body", "severity", "role", "mandatory"]);
  const d = strict
    ? new Proxy({ ...data }, { get: (t, k) => {
        if (typeof k !== "string" || k in t || OPTIONAL.has(k)) return t[k];
        throw new Error(`MISSING_FIELD:${code}:${k}`);
      } })
    : { ...SAMPLE, ...data };
  const c = def.build(d);
  const C = EMAIL_COLORS;
  const [fg, bg] = TONES[c.tone] ?? TONES.info;
  const preheader = c.intro?.[0] ?? c.heading;
  const mandatory = typeof d.mandatory === "boolean" ? d.mandatory : def.mandatory;
  const why = mandatory
    ? "This email is always sent because it is about your account, your service or money."
    : "You can turn this email off in Settings, Notifications.";
  const p = (t) => `<p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:${C.text2}">${esc(t)}</p>`;
  const facts = (c.facts ?? []).map(([k, v]) => `<tr><td style="padding:8px 0;color:${C.faint};font-size:14px;border-top:1px solid ${C.border}">${esc(k)}</td><td style="padding:8px 0;color:${C.text};font-size:14px;font-weight:600;text-align:right;border-top:1px solid ${C.border}">${esc(v)}</td></tr>`).join("");
  const lines = (c.lines ?? []).map(([k, v]) => `<tr><td style="padding:6px 0;color:${C.text2};font-size:14px">${esc(k)}</td><td style="padding:6px 0;color:${C.text};font-size:14px;text-align:right">${esc(v)}</td></tr>`).join("")
    + (c.total ? `<tr><td style="padding:10px 0 0;color:${C.text};font-size:15px;font-weight:700;border-top:1px solid ${C.border}">Total</td><td style="padding:10px 0 0;color:${C.text};font-size:15px;font-weight:700;text-align:right;border-top:1px solid ${C.border}">${esc(c.total)}</td></tr>` : "");
  const button = c.button ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:22px 0 8px"><tr><td style="background:${C.primary};border-radius:10px"><a href="${esc(safeUrl(c.button[1]))}" style="display:inline-block;padding:12px 22px;color:#FFFFFF;font-size:15px;font-weight:600;text-decoration:none">${esc(c.button[0])}</a></td></tr></table>` : "";
  const secondary = (c.secondary ?? []).map(([t, u]) => `<a href="${esc(safeUrl(u))}" style="color:${C.primary};font-size:14px;margin-right:16px">${esc(t)}</a>`).join("");
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(c.subject)}</title></head>
<body style="margin:0;padding:0;background:${C.bg};font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif">
<span style="display:none;max-height:0;overflow:hidden;opacity:0">${esc(preheader)}</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C.bg}"><tr><td align="center" style="padding:28px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px">
<tr><td style="padding:0 4px 14px;font-size:16px;font-weight:700;color:${C.primary}">Zella Voice<span style="font-weight:400;color:${C.faint}"> &middot; ${esc(d.business)}</span></td></tr>
<tr><td style="background:${C.card};border:1px solid ${C.border};border-radius:16px;padding:28px">
<div style="display:inline-block;padding:4px 10px;border-radius:999px;background:${C[bg]};color:${C[fg]};font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase">${esc(GROUPS.find(([k]) => k === def.group)?.[1].replace(/^Billing: .*/, "Billing") ?? "")}</div>
<h1 style="margin:14px 0 12px;font-size:22px;line-height:1.3;color:${C.text}">${esc(c.heading)}</h1>
${(c.intro ?? []).map(p).join("")}
${facts ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:6px 0 4px">${facts}</table>` : ""}
${lines ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:14px 0 4px;padding:14px 16px;background:${C.subtle};border-radius:12px">${lines}</table>` : ""}
${(c.outro ?? []).map(p).join("")}
${button}${secondary ? `<p style="margin:10px 0 0">${secondary}</p>` : ""}${c.note ? `<p style="margin:10px 0 0;font-size:13px;color:${C.faint}">${esc(c.note)}</p>` : ""}
</td></tr>
<tr><td style="padding:16px 8px;font-size:12px;line-height:1.5;color:${C.faint}">You're receiving this as ${d.role === "owner" ? "the owner" : d.role === "admin" ? "an admin" : "a member of the team"} of ${esc(d.business)} on Zella Voice. ${esc(why)} ${d.supportEmail ? `Questions? Reply to this email or write to ${esc(d.supportEmail)}.` : "Questions? Reply to this email."}</td></tr>
</table></td></tr></table></body></html>`;
  const text = [
    `Zella Voice, ${d.business}`, "", c.heading, "", ...(c.intro ?? []).flatMap((t) => [t, ""]),
    ...(c.facts ?? []).map(([k, v]) => `${k}: ${v}`), ...(c.lines ?? []).map(([k, v]) => `${k}: ${v}`), ...(c.total ? [`Total: ${c.total}`] : []),
    ...(c.outro ?? []).flatMap((t) => ["", t]),
    ...(c.button ? ["", `${c.button[0]}: ${safeUrl(c.button[1])}`] : []), ...(c.secondary ?? []).map(([t, u]) => `${t}: ${safeUrl(u)}`), ...(c.note ? [c.note] : []),
    "", `You're receiving this as ${d.role === "owner" ? "the owner" : d.role === "admin" ? "an admin" : "a member of the team"} of ${d.business} on Zella Voice. ${why} ${d.supportEmail ? `Questions? Reply to this email or write to ${d.supportEmail}.` : "Questions? Reply to this email."}`,
  ].join("\n").replace(/\n{3,}/g, "\n\n");
  return { code, name: def.name, mandatory, subject: c.subject, preheader, html, text };
}
